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

(defparameter +default-workspace-prefix-key-code+ #x11
  "Control-Q, the workspace UI prefix used by the multi-client overview.")

(defstruct (client-conn (:constructor %make-client-conn))
  "One attached client: its socket, a cached binary STREAM and FD, a private
   keystroke STATE (so each client has independent prefix/copy-mode state), the
   ROWS×COLS geometry it last reported, an optional command-stdin target pane,
   its private UI state, cached frame, and private message log."
  socket
  stream
  fd
  stdin-target
  (message-log nil)
  (rows 24 :type fixnum)
  (cols 80 :type fixnum)
  (focus nil)
  (selected-tree-object nil)
  (selected-worktree nil)
  (tree-scroll 0 :type fixnum)
  (workspace-prefix-code +default-workspace-prefix-key-code+ :type fixnum)
  (ui-prefix-p nil :type boolean)
  (viewport 0 :type fixnum)
  (mode :normal)
  (command-buffer "" :type string)
  (command-return-view nil)
  (view :detail)
  (attach-target nil)
  (attach-cwd nil)
  (picker-items nil)
  (picker-query "" :type string)
  (picker-regex-p nil :type boolean)
  (picker-index 0 :type fixnum)
  (attention-items nil :type list)
  (attention-index 0 :type fixnum)
  ;; Set to the REPOSITORY-ID of the repository a dry-run prune preview was
  ;; just shown for; a confirm (dry-run nil) prune must match it, so
  ;; wt-prune-confirm --confirm cannot skip straight past the preview a user
  ;; is meant to review first. Cleared once a confirmed prune completes.
  (pending-prune-preview-repository-id nil)
  (frame nil))

(defvar *clients* nil
  "List of CLIENT-CONN structs currently attached to the multi-client server.
   Mutated only by the single server event loop, so it needs no locking.")

(defvar *workspace-catalog-refresh-started-p* nil
  "Whether the initial asynchronous ghq/worktree catalog refresh was started.")

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
  "Return (values ROWS COLS) the session should render at, per the `window-size`
   option over the attached clients:
     smallest — min over all clients (default; the safe shared session-layout
                size for every client);
     largest  — max over all clients;
     latest   — the most recently attached/resized client (*clients* is kept
                most-recent-first);
     manual   — keep the current *term-rows*/*term-cols* (no auto-resize).
   Falls back to *term-rows*/*term-cols* when no clients are attached.
   NOTE: largest/latest can exceed a smaller client's terminal — they are honoured
   for parity, but smallest stays the safe default for the shared session-layout
   design."
  (if (null *clients*)
      (values *term-rows* *term-cols*)
      (let ((mode (or (nerimux/options:get-option "window-size") "smallest")))
        (cond
          ((string-equal mode "largest")
           (%client-size-reduce #'max))
          ((string-equal mode "latest")
           (let ((c (first *clients*)))
             (values (client-conn-rows c) (client-conn-cols c))))
          ((string-equal mode "manual")
           (values *term-rows* *term-cols*))
          (t                            ; "smallest" and any unknown value
           (%client-size-reduce #'min))))))

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
               :prefix-code (client-conn-workspace-prefix-code conn)))
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
      (ignore-errors
        (nerimux/vcs:refresh-workspace-organizations-async
         :on-complete
         (lambda (organizations)
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
           (%mark-dirty)))))
    (%mark-dirty)
    conn))

(defun %drop-client (conn &key bye)
  "Remove CONN: optionally send a bye frame, close its socket, and
   unregister it.  Safe to call more than once."
  (when (member conn *clients*)
    (setf (client-conn-ui-prefix-p conn) nil)
    (when bye
      (ignore-errors (send-frame (client-conn-stream conn) (msg-bye))))
    (ignore-errors (close-socket (client-conn-socket conn)))
    (setf *clients* (remove conn *clients*))))
