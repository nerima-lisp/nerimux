(in-package #:nerimux)

;;;; Multi-client server: a single select(2)-multiplexed event loop that serves
;;;; MANY attached clients at once, instead of the one-client-at-a-time model in
;;;; server.lisp (accept → serve-one-until-detach → accept-next).
;;;;
;;;; The loop owns a registry of connected clients (*clients*).  Each iteration:
;;;;   1. renders and sends a client-specific frame when *dirty*;
;;;;   2. select()s on the listener fd + every client fd together;
;;;;   3. accepts a new connection when the listener is readable;
;;;;   4. dispatches a message from each readable client (keys/resize/detach/cmd).
;;;;
;;;; The session, PTYs, and per-pane reader threads are unchanged — the reader
;;;; threads still set *dirty* when pane output arrives.  The shared session
;;;; layout continues to use %effective-client-size for PTY compatibility, but
;;;; the presentation frame is rendered independently for each client.
;;;;
;;;; Reuses the shared pieces from server.lisp / protocol / transport:
;;;;   process-client-keys, decode-size, decode-command-payload, render-…,
;;;;   send-frame/read-frame, msg-frame/msg-bye, socket-fd/-stream/close-socket.

;;; ── Client connection registry ──────────────────────────────────────────────

(defvar *clients* nil
  "List of CLIENT-CONN structs currently attached to the multi-client server.
   Mutated only by the single server event loop, so it needs no locking.")

(defvar *main-thread-callback-lock*
  (cl-concurrent-kit:make-lock :name "nerimux-main-thread-callbacks"))

(defvar *main-thread-callbacks* nil
  "Callbacks queued for execution by the multi-client event loop.")

(defun %enqueue-main-thread-callback (thunk)
  "Queue THUNK for execution by the multi-client event loop.

VCS workers use this boundary before touching client or catalog state owned by
the event loop.  The queue is the only cross-thread state in this layer; the
callbacks themselves run serially in the loop."
  (check-type thunk function)
  (cl-concurrent-kit:with-lock-held (*main-thread-callback-lock*)
    (push thunk *main-thread-callbacks*))
  nil)

(defun %drain-main-thread-callbacks ()
  "Run callbacks queued by worker threads, keeping one failure local."
  (let ((callbacks
          (cl-concurrent-kit:with-lock-held (*main-thread-callback-lock*)
            (prog1 (nreverse *main-thread-callbacks*)
              (setf *main-thread-callbacks* nil)))))
    (dolist (callback callbacks)
      (handler-case
          (funcall callback)
        (error (condition)
          (format *error-output*
                  "~&nerimux main-thread callback failed: ~A~%"
                  condition)
          (finish-output *error-output*)))))
  nil)

(defvar *workspace-catalog-refresh-started-p* nil
  "Whether the initial asynchronous ghq/worktree catalog refresh was started.")

;;; ── Workspace tree UI state (R6.2/R6.3) ─────────────────────────────────────
;;;
;;; Global, not per-CLIENT-CONN: R6.3 requires collapse state, and R6.2 the
;;; refreshing/stale markers, to survive detach/attach for as long as the
;;; server is alive, and %ADD-CLIENT below builds a brand-new CLIENT-CONN on
;;; every attach -- anything stored on that struct would silently reset on
;;; reconnect, which is exactly the requirement this state must not violate.
;;; None of it is persisted to disk (R6.3: "永続化はしない").
;;;
;;; Ownership split: this file defines and mutates the tables; the render
;;; call in %RENDER-CLIENT-FRAME below reads them into the R6 renderer
;;; entry points (nerimux/renderer:render-workspace-overview-to-tui-string).
;;; The mutators are for the multi-dispatch key handlers to call
;;; (Enter on an org/repo row, a VCS fetch/refresh starting and settling, a
;;; pane gaining focus within a worktree) -- see the R6 report for exactly
;;; which handler calls which function.

(defvar *workspace-expanded-node-ids* (make-hash-table :test #'equal)
  "Set of expanded organization/repository tree-node keys (R6.3), keyed the
   same way as NERIMUX/RENDERER:%WORKSPACE-TREE-NODE-KEY returns (a
   (:ORGANIZATION ID) or (:REPOSITORY ID) list). Presence (any non-NIL
   value) means expanded; absence means collapsed, the tree's default state.
   Worktree/window/pane rows are never keys here -- only these two levels
   toggle independently (R6.3).")

(defun %workspace-expanded-nodes ()
  "The expanded-row set, for callers that load before its DEFVAR.

   the multi-dispatch files are compiled before this file, so naming the
   variable there would compile as an undeclared free reference. A function is
   only a forward reference, which resolves at call time."
  *workspace-expanded-node-ids*)

(defun %toggle-workspace-node-expanded (kind id)
  "Flip the KIND (:ORGANIZATION or :REPOSITORY) / ID row's collapse state
   (R6.3's Enter-toggles-collapse behaviour)."
  (let ((key (list kind id)))
    (if (gethash key *workspace-expanded-node-ids*)
        (remhash key *workspace-expanded-node-ids*)
        (setf (gethash key *workspace-expanded-node-ids*) t))))

(defvar *workspace-refreshing-ids* (make-hash-table :test #'equal)
  "Set of organization/repository/worktree tree-node keys a VCS operation is
   currently refreshing (R6.2). Populate with %MARK-WORKSPACE-REFRESHING /
   %CLEAR-WORKSPACE-REFRESHING around the async call that refreshes it.")

(defvar *workspace-stale-ids* (make-hash-table :test #'equal)
  "Set of organization/repository/worktree tree-node keys whose last refresh
   failed (R6.2): the value shown is the previous successful one, tagged
   stale instead of presented as current.")

(defun %mark-workspace-refreshing (kind id)
  "Record that the KIND/ID node's data is being refreshed (R6.2), and clear
   any stale mark on it -- a fresh attempt in flight supersedes the last
   failure until this one, too, settles."
  (let ((key (list kind id)))
    (setf (gethash key *workspace-refreshing-ids*) t)
    (remhash key *workspace-stale-ids*)))

(defun %clear-workspace-refreshing (kind id &key stale-p)
  "Settle a refresh started with %MARK-WORKSPACE-REFRESHING: always clears
   the refreshing mark; sets the stale mark when STALE-P (the refresh
   failed), else clears it (the refresh succeeded)."
  (let ((key (list kind id)))
    (remhash key *workspace-refreshing-ids*)
    (if stale-p
        (setf (gethash key *workspace-stale-ids*) t)
        (remhash key *workspace-stale-ids*))))

(defun %set-workspace-catalog-refresh-state (organizations &key stale-p)
  "Settle every visible node in ORGANIZATIONS as fresh or stale.

   Catalog refresh is a batch operation, so its callbacks carry the complete
   tree rather than one node at a time.  Keeping the traversal here makes the
   marker key contract identical to the renderer's tree-node keys."
  (labels ((settle (kind id)
             (if stale-p
                 (%clear-workspace-refreshing kind id :stale-p t)
                 (%clear-workspace-refreshing kind id)))
           (mark (kind id)
             (if stale-p
                 (settle kind id)
                 (%mark-workspace-refreshing kind id))))
    (dolist (organization organizations)
      (mark :organization (nerimux/model:organization-id organization))
      (dolist (repository
                (nerimux/model:organization-repositories organization))
        (mark :repository (nerimux/model:repository-id repository))
        (dolist (worktree (nerimux/model:repository-worktrees repository))
          (mark :worktree (nerimux/model:worktree-id worktree)))))
    nil))

(defvar *workspace-worktree-last-pane* (make-hash-table :test #'equal)
  "WORKTREE-ID -> the pane a client was last focused on within that worktree
   (R6.3: worktree-row Enter returns there, or opens a new pane when there
   is none). Global for the same detach/attach-survival reason as
   *WORKSPACE-EXPANDED-NODE-IDS* above.")

(defun %remember-worktree-pane (worktree pane)
  "Record PANE as the one to return to next time Enter lands on WORKTREE's
   tree row (R6.3). Call this on every focus change within a worktree, not
   only from the worktree-row Enter handler itself -- the requirement is to
   remember the last-focused pane, not just the last one opened via Enter."
  (when (and worktree pane)
    (setf (gethash (worktree-id worktree) *workspace-worktree-last-pane*) pane)))

(defun %worktree-remembered-pane (worktree)
  "The pane %REMEMBER-WORKTREE-PANE last recorded for WORKTREE, or NIL when
   there is none or it has since closed. Self-healing: a pane no longer
   among WORKTREE's own panes is treated as gone and its stale entry is
   dropped here, so a caller never has to remember to clear this table when
   it closes a pane."
  (when worktree
    (let ((pane (gethash (worktree-id worktree) *workspace-worktree-last-pane*)))
      (cond
        ((null pane) nil)
        ((member pane (worktree-panes worktree) :test #'eq) pane)
        (t (remhash (worktree-id worktree) *workspace-worktree-last-pane*)
           nil)))))

(defvar *workspace-catalog-loaded-p* nil
  "T once the initial async ghq/worktree catalog refresh's on-complete
   callback (in %ADD-CLIENT below) has run at least once. Distinguishes
   \"still scanning\" from \"scanned and genuinely found zero repositories\"
   for R6.2's scanning-p -- a plain (null organizations) check cannot tell
   those two apart.")

;;; with-loop-safe-error is defined in server-multi-dispatch.lisp (which loads
;;; first) so it is available at compile time to every user, including here.

(define-multi-msg-dispatch
  ;; EOF: peer closed the connection.
  ((null type) :drop)
  ;; Client requested clean detach.
  ((= type +msg-detach+) :drop)
  ;; Initial attach or resize: update CONN's geometry and re-apply effective size.
  ((or (= type +msg-attach+) (= type +msg-resize+))
   (%handle-multi-attach-or-resize session conn type payload))
  ;; Keystroke: feed to the pane's stdin-target (split-window -I) or run through
  ;; the shared prefix/copy-mode pipeline with CONN's private state.
  ((= type +msg-key+)
   (%handle-multi-key-message session conn payload))
  ;; Command forwarding: run-command from a CLI client or control-mode client.
  ((= type +msg-command+)
   (%handle-multi-command-message session conn payload))
  ;; Unknown message type: treat as disconnect.
  (t :drop))

;;; ── Effective geometry (smallest attached client) ───────────────────────────

(defun %client-size-reduce (fn)
  "Apply FN (e.g. #'min or #'max) across all attached clients' rows and cols,
   returning (values ROWS COLS)."
  (values (reduce fn *clients* :key #'client-conn-rows)
          (reduce fn *clients* :key #'client-conn-cols)))

(defun %effective-client-size ()
  "Return (values ROWS COLS) the session should render at: the smallest
   attached client's geometry, so the shared session layout fits every
   attached client (§1.4 — multiple clients are allowed; the shared size
   follows the smallest one; R8.4).
   Falls back to *term-rows*/*term-cols* when no clients are attached."
  (if (null *clients*)
      (values *term-rows* *term-cols*)
      (%client-size-reduce #'min)))

(defun %apply-effective-size (session)
  "Set *term-rows*/*term-cols* to the effective (smallest-client) geometry,
   relayout SESSION's active window for the new size, and mark the screen dirty."
  (multiple-value-bind (rows cols) (%effective-client-size)
    (setf *term-rows* rows *term-cols* cols)
    (%relayout-active-window session rows cols)
    (%mark-dirty)))

;;; ── Frame broadcast ─────────────────────────────────────────────────────────

(defun %render-client-frame (session conn)
  "Render SESSION for CONN's geometry and cache the encoded frame on CONN.
   Session layout remains governed by the effective shared size; this boundary
   only controls the client-facing surface dimensions."
  (let ((frame
          (msg-frame
           (cond
             ;; A confirmation owns the whole frame while it is up (R6.4): the
             ;; question has to be the only thing on screen, or a y/n answer can
             ;; be given to something the user was not reading.
             ((client-conn-confirm-view conn)
              (render-confirm-view-to-tui-string
               (client-conn-confirm-view conn)
               (client-conn-rows conn)
               (client-conn-cols conn)))
             ((and (eq (client-conn-view conn) :overview)
                   (not (eq (client-conn-mode conn) :picker)))
              (render-workspace-overview-to-tui-string
               (nerimux/vcs:workspace-organizations)
               (client-conn-rows conn)
               (client-conn-cols conn)
               :focus-pane (client-conn-focus conn)
               :selected-tree-object
               (client-conn-selected-tree-object conn)
               :selected-worktree (client-conn-selected-worktree conn)
               :tree-scroll (client-conn-tree-scroll conn)
               :messages (client-conn-message-log conn)
               :mode (client-conn-mode conn)
               :prefix-code (client-conn-workspace-prefix-code conn)
               ;; R6.2/R6.3/R6.12: server-lifetime tree state, defined above
               ;; in this file, and the client's own in-flight `:` buffer.
               :expanded-node-ids *workspace-expanded-node-ids*
               :refreshing-ids *workspace-refreshing-ids*
               :stale-ids *workspace-stale-ids*
               ;; NIL (not scanning) when no refresh was ever kicked off at
               ;; all -- e.g. the VCS adapter is unavailable (%ADD-CLIENT's
               ;; (nerimux/vcs:vcs-package-available-p) guard) -- so that
               ;; case shows the ordinary empty tree/header/footer rather
               ;; than getting stuck on "scanning..." forever.
               :scanning-p (and *workspace-catalog-refresh-started-p*
                                (not *workspace-catalog-loaded-p*))
               :command-buffer (client-conn-command-buffer conn)))
             (t
              (render-session-to-tui-string
               session
               (client-conn-rows conn)
               (client-conn-cols conn)
               :focus-pane (client-conn-focus conn)
               :viewport (client-conn-viewport conn)
               :mode (client-conn-mode conn)
               :command-buffer (client-conn-command-buffer conn)
               :picker-items
               (when (eq (client-conn-mode conn) :picker)
                 (%client-picker-visible-items conn))
               :picker-query (client-conn-picker-query conn)
               :picker-index (client-conn-picker-index conn)
               :picker-regex-p (client-conn-picker-regex-p conn)))))))
    (setf (client-conn-frame conn) frame)
    frame))

(defun %send-client-frame (conn frame)
  "Cache and send FRAME to one client connection."
  (setf (client-conn-frame conn) frame)
  (send-frame (client-conn-stream conn) frame))

(defun %broadcast-frame (session)
  "When *dirty* and at least one client is attached, render one frame per
   client at that client's geometry, send it, and then clear *dirty*."
  (when (and *dirty* *clients*)
    (setf *dirty* nil)
    (dolist (conn (copy-list *clients*))
      (with-loop-safe-error (nil :on-error (%drop-client conn))
        (%send-client-frame conn (%render-client-frame session conn))))))

(defun %client-fds ()
  "The socket fds of every attached client (for the select read-set)."
  (mapcar #'client-conn-fd *clients*))

;;; ── Connection lifecycle ────────────────────────────────────────────────────

(defun %add-client (socket)
  "Register SOCKET as a new client: build its CLIENT-CONN and mark
   the screen dirty so the new client gets an immediate paint.  Returns the conn."
  (let ((conn (%make-client-conn :socket socket
                                 :stream (socket-stream socket)
                                 :fd     (socket-fd socket)
                                 :rows   *term-rows*
                                 :cols   *term-cols*
                                 :mode   :normal
                                 :view   :overview
                                 :viewport 0)))
    (push conn *clients*)
    (when (and (not *workspace-catalog-refresh-started-p*)
               (nerimux/vcs:vcs-package-available-p))
      (setf *workspace-catalog-refresh-started-p* t)
      (%set-workspace-catalog-refresh-state
       (nerimux/vcs:workspace-organizations))
      ;; handler-case rather than ignore-errors: a synchronous failure
      ;; kicking the async refresh off (e.g. thread creation) must still
      ;; flip *workspace-catalog-loaded-p*, or R6.2's scanning-p is stuck
      ;; true forever with no on-error callback ever going to run.
      (let ((refresh-failed-p nil))
        (handler-case
            (nerimux/vcs:refresh-workspace-organizations-async
             :callback-dispatch #'%enqueue-main-thread-callback
             ;; Paint the tree the moment the scan lands: the status refresh
             ;; behind it runs git across every repository and can take seconds
             ;; on a large root, and nothing else marks the screen dirty in the
             ;; meantime — clients would hold the "scanning..." placeholder (or
             ;; a stale empty tree) until every status arrived.
             :on-catalog
             (lambda (organizations)
               (%set-workspace-catalog-refresh-state organizations)
               (%mark-dirty))
             :on-complete
             (lambda (organizations)
               ;; R6.2: flips scanning-p false for every client from here on,
               ;; regardless of whether ORGANIZATIONS turned out empty.
               (setf *workspace-catalog-loaded-p* t)
               (%set-workspace-catalog-refresh-state
                organizations :stale-p refresh-failed-p)
               (dolist (client (remove-duplicates
                                (remove-if-not #'%client-live-p
                                               (copy-list *clients*))
                                :test #'eq))
                 (%rebind-client-selection client organizations)
                 (setf (client-conn-picker-items client)
                       (nerimux/picker:build-global-picker-items organizations))
                 (%picker-clamp-index client
                                      (%client-picker-visible-items client)))
               (%mark-dirty))
             :on-error
             (lambda (condition)
               (declare (ignore condition))
               (setf refresh-failed-p t)
               ;; R6.2: a failed initial scan must still stop showing
               ;; "scanning..." -- otherwise a client attached before the
               ;; error is stuck on the placeholder forever.
               (setf *workspace-catalog-loaded-p* t)
               (%set-workspace-catalog-refresh-state
                (nerimux/vcs:workspace-organizations) :stale-p t)
               (%mark-dirty)))
          (error (condition)
            (declare (ignore condition))
            (setf refresh-failed-p t
                  *workspace-catalog-loaded-p* t)
            (%set-workspace-catalog-refresh-state
             (nerimux/vcs:workspace-organizations) :stale-p t)
            (%mark-dirty)))))
    (%mark-dirty)
    conn))

(defun %drop-client (conn &key bye)
  "Remove CONN: optionally send a bye frame, close its socket, and
   unregister it.  Safe to call more than once."
  (when (member conn *clients*)
    (setf (client-conn-ui-prefix-p conn) nil)
    (when (and bye (streamp (client-conn-stream conn)))
      (handler-case
          (send-frame (client-conn-stream conn) (msg-bye))
        (sb-ext:timeout () nil)
        (sb-bsd-sockets:socket-error () nil)
        (stream-error () nil)))
    (let ((socket (client-conn-socket conn)))
      (when socket
        (close-socket socket)))
    (setf *clients* (remove conn *clients*))))
