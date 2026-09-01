(in-package #:nerimux)

;;;; Shared multi-client connection data.
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
  ;; The in-flight `/` overview tree-filter query (:tree-filter mode), or NIL
  ;; when no filter is active (cleared by ESC, kept by Enter -- see
  ;; %transition-client-ui-mode). NIL rather than "": an empty string is a
  ;; filter box the user has entered but not typed into yet, still a real
  ;; per-frame state the renderer draws differently from no filter at all.
  (tree-filter nil)
  (workspace-prefix-code +default-workspace-prefix-key-code+ :type fixnum)
  (ui-prefix-p nil :type boolean)
  (viewport 0 :type fixnum)
  ;; The two axes that replaced the old MODE x VIEW product (magit alignment,
  ;; FR-001/FR-007). VIEW says which screen is up; MODAL says what, if anything,
  ;; has taken the keyboard away from that screen.
  ;;
  ;; The product used to have unreachable cells -- (:detail . :normal) meant "a
  ;; pane is focused but keystrokes go to the UI", which is precisely the state
  ;; pressing `i` existed to leave. With panes now taking input directly, where
  ;; a key goes is DERIVED from VIEW whenever MODAL is NIL (%CLIENT-UI-KEYS-P),
  ;; so no such cell exists to be constructed, asserted about, or drifted into.
  ;;
  ;; MODAL is one slot rather than a flag per state on purpose: two flags set at
  ;; once is exactly the unreachable-combination problem this change removes.
  (view :repolist)
  (modal nil)
  ;; Per-client, per-session argument toggles for the transient menus (FR-010),
  ;; as an alist of TRANSIENT-KEY -> list of active flag strings. Kept when the
  ;; transient closes: magit remembers a `--force-with-lease` you set earlier in
  ;; the session, and losing it every close would make the toggle useless.
  (transient-arguments nil)
  (transient-view nil)
  ;; magit's 1/2/3/4 global visibility level (FR-005). 4 = everything expanded,
  ;; 1 = section headings only. Per client rather than per section table: the
  ;; level is a lens over whatever the per-row expand state says, so pressing 4
  ;; then 2 returns to the same rows rather than to a flattened remembering of
  ;; them.
  (visibility-level 2 :type (integer 1 4))
  (command-buffer "" :type string)
  (command-return-view nil)
  (attach-target nil)
  (attach-cwd nil)
  (picker-items nil)
  (picker-query "" :type string)
  (picker-regex-p nil :type boolean)
  (picker-index 0 :type fixnum)
  ;; Set to the REPOSITORY-ID of the repository a dry-run prune preview was
  ;; just shown for; a confirm (dry-run nil) prune must match it, so
  ;; wt-prune-confirm --confirm cannot skip straight past the preview a user
  ;; is meant to review first. Cleared once a confirmed prune completes.
  (pending-prune-preview-repository-id nil)
  ;; The full-screen confirmation (R6.4) this client is currently looking at, or
  ;; NIL. Per client, not per server: two attached clients can be mid-answer on
  ;; different questions, and a confirmation one of them never saw must not
  ;; capture the other's keystrokes.
  (confirm-view nil)
  ;; What to run when the user answers y to CONFIRM-VIEW. A closure of no
  ;; arguments; NIL when no confirmation is up. Kept beside the view rather than
  ;; encoded in it so the renderer keeps taking plain data.
  (confirm-action nil)
  ;; The `$` process log (FR-011): executed git command, exit status, output.
  ;; Most recent first, capped -- see +MAX-PROCESS-LOG-ENTRIES+.
  (process-log nil)
  (process-log-scroll 0 :type fixnum)
  ;; No HELP-VIEW-P flag: the help view carries no per-client data, so MODAL
  ;; :help IS its whole state. A boolean beside MODAL would be a second place
  ;; to say the same thing, and the two could disagree.
  (frame nil))

;;;; Multi-client message handlers extracted from server-multi.lisp.
;;;;
;;;; The event loop keeps the dispatch table, while these helpers own the
;;;; per-message policy for attach/resize, keys, and forwarded commands.
;;; WITH-LOOP-SAFE-ERROR is defined here because this file owns the per-client
;;; handler policy and every handler below uses the same error boundary.  The
;;; message-dispatch macro itself lives in server.lisp, which ASDF loads before
;;; this file; server-multi.lisp then uses the same expansion.
(defmacro with-loop-safe-error (binding &body body)
  "Run BODY, catching a failed client/command so one of them can never wedge
   the multi-client event loop.  On success, returns BODY's value; on a
   failure, evaluates and returns ON-ERROR instead — optionally with the
   condition bound to CONDITION-VAR so ON-ERROR can log it.  This is the
   single shape behind this file's 'never let one client take down the server
   loop' invariant.

   The clause is PEER-IO-FAILURE (server.lisp), not ERROR, and the difference is
   the whole invariant.  SB-EXT:TIMEOUT is a SERIOUS-CONDITION that is
   deliberately NOT an ERROR — verified on SBCL 2.6.6:
   (subtypep 'sb-ext:timeout 'error) => NIL — so an ERROR-only clause misses
   it silently.

   That is exactly the condition this macro is wrapped around.  SEND-FRAME
   (infrastructure/net/transport.lisp) bounds its write with
   SB-EXT:WITH-TIMEOUT and documents itself as signalling SB-EXT:TIMEOUT when
   the peer is too slow to accept it.  %BROADCAST-FRAME calls it through this
   macro for every attached client on every dirty frame.  With an ERROR-only
   clause, one client whose socket stalls for +send-frame-timeout-seconds+ —
   a suspended terminal, a laggy hop, a full send buffer — raised a condition
   that passed straight through this handler, through the serve loop, and out
   of RUN-SERVER, taking the process down and disconnecting EVERY client.
   The macro promised the opposite of what it did, for the one failure it
   most needed to contain.

   %DROP-CLIENT (server-multi.lisp) already had the correct shape, listing
   (SB-EXT:TIMEOUT () NIL) beside its socket and stream clauses; this brings
   the shared macro in line with it.

   Deliberately NOT widening to SERIOUS-CONDITION: that would also swallow
   STORAGE-CONDITION, and heap exhaustion must stay fatal rather than be
   retried once per client per frame.  Confirmed the narrow specifier keeps
   it fatal."
  (let ((condition-var (first binding))
        (on-error (getf (rest binding) :on-error)))
    `(handler-case (progn
                     ,@body)
       (peer-io-failure ,(if condition-var
                             (list condition-var)
                             '())
         ,on-error))))

(defun %client-esc-swallow-start (conn &optional (n 2))
  (setf (gethash conn *client-esc-swallow-counts*) n))

(defun %client-esc-swallow-consume (conn)
  "If CONN has a pending swallow count, decrement it and return T (the byte
   this call was invoked for must be discarded). Returns NIL otherwise."
  (let ((remaining (gethash conn *client-esc-swallow-counts*)))
    (when (and remaining (plusp remaining))
      (if (<= remaining 1)
          (remhash conn *client-esc-swallow-counts*)
          (setf (gethash conn *client-esc-swallow-counts*) (1- remaining)))
      t)))

(defun %handle-multi-attach-or-resize (session conn type payload)
  "Update CONN's geometry from PAYLOAD, refresh client ordering for
   window-size latest, and reapply the effective shared size."
  (declare (ignore type))
  (multiple-value-bind (rows cols) (decode-size payload)
    (setf (client-conn-rows conn) rows
          (client-conn-cols conn) cols))
  ;; Keep this client most-recent so window-size latest follows the active peer.
  (setf *clients* (cons conn (remove conn *clients*)))
  (%apply-effective-size session)
  nil)

(defun %client-ui-keys-p (conn)
  "T when CONN's keystrokes belong to the workspace UI rather than to a shell.

   This is the whole of FR-007's rule, and it is a DERIVATION rather than a
   stored flag: with no modal up, a key belongs to the UI exactly when the
   screen in front of the user is a UI screen. There is no state in which a
   pane is on screen and the UI is nonetheless eating keys, because there is
   no slot in which to record one -- which is what retired `i` and the old
   :normal/:input pair together."
  (and (null (client-conn-modal conn))
       (member (client-conn-view conn) '(:repolist :status) :test #'eq)))

(defun %set-client-modal (conn modal)
  "Put CONN into MODAL (NIL to return the keyboard to the current view)."
  (setf (client-conn-modal conn) modal)
  (%mark-dirty)
  modal)

(defun %handle-multi-key-message (session conn payload)
  "Feed PAYLOAD to whatever currently owns CONN's keyboard.

   Precedence, highest first: a pending ESC-swallow, a keyboard-owning MODAL
   (+KEYBOARD-OWNING-MODALS+), the C-q prefix, any remaining MODAL, then the
   view-derived default. The modal branch is a single CASE over one slot rather
   than a chain of flag tests, so two owners cannot both claim a key -- the
   failure the old MODE x VIEW product allowed.

   The default arm is where FR-007 lands: :repolist and :status route to the UI
   keymap, and every other view (i.e. :pane) hands the byte straight to the
   shell with no mode to leave first."
  (cond
    ;; Swallowed by a pending ESC sequence (R4.3): never reaches any dispatch.
    ((%client-esc-swallow-consume conn) nil)
    ;; Before the prefix, not after -- see +KEYBOARD-OWNING-MODALS+.
    ((member (client-conn-modal conn) +keyboard-owning-modals+ :test #'eq)
     (case (client-conn-modal conn)
       (:confirm (nth-value 1 (%handle-confirm-key session conn payload)))
       (:help (%handle-help-view-key conn payload))
       (:transient (%handle-client-transient-key-payload session conn payload))
       (:process-log (%handle-process-log-key conn payload))))
    (t
     (multiple-value-bind (prefix-handled prefix-result)
         (%handle-workspace-prefix-key session conn payload)
       (if prefix-handled
           prefix-result
           (case (client-conn-modal conn)
             (:picker (%handle-client-picker-key-payload session conn payload))
             (:scrollback (%handle-client-copy-key-payload session conn payload))
             (:command (%handle-client-command-key-payload session conn payload))
             (:filter (%handle-client-tree-filter-key-payload session conn payload))
             (t
              (cond
                ((and (%client-ui-keys-p conn) (%client-byte-p payload 16))
                 (%open-client-picker conn))
                ((%client-ui-keys-p conn)
                 ;; A key the UI does not bind is simply dropped here. It must
                 ;; NOT fall through to the shell: the retired keys (j/k/i/c/r
                 ;; and friends) would otherwise land in whatever program the
                 ;; focused pane is running, which is worse than doing nothing.
                 (or (%handle-client-ui-key-payload session conn payload) nil))
                (t
                 ;; :pane -- FR-007. Every byte goes to the shell, ESC included.
                 (%handle-client-input-key-payload session conn payload))))))))))

(defun %handle-workspace-prefix-key (session conn payload)
  "Handle the client-local prefix (C-q, R4.4) and the key it introduces.

The prefix is consumed before the stdin-target path.  Once struck, the next
byte is resolved against 1.5's binding table by %workspace-prefix-dispatch;
a byte the table does not recognize is discarded there instead of falling
through to the normal key pipeline — the old 'unbound means pass through'
behavior (:96-107 pre-R4.4) is gone."
  (let ((single-byte
         (and (arrayp payload) (= (length payload) 1) (aref payload 0))))
    (cond
      ((client-conn-ui-prefix-p conn)
        (setf (client-conn-ui-prefix-p conn) nil)
        (values t (%workspace-prefix-dispatch session conn single-byte)))
      ((and (integerp single-byte)
            (= single-byte (client-conn-workspace-prefix-code conn)))
        (setf (client-conn-ui-prefix-p conn) t)
        (values t nil))
      (t (values nil nil)))))

;;; ── `?` full-screen help view (FR-005) ──────────────────────────────────────
(defun %client-open-help-view (conn)
  "Put the static key-reference view up. Reached from the `?` transient's `k`
   entry (FR-010) rather than from `?` directly -- `?` now opens the dispatch
   transient, matching magit."
  (%set-client-modal conn :help)
  t)

(defun %close-help-view (conn)
  (%set-client-modal conn nil))

(defun %handle-help-view-key (conn payload)
  "Answer the help view CONN is looking at: q, ?, Enter, and ESC close it;
   every other key is swallowed, the same shape as %HANDLE-CONFIRM-KEY, just
   with no y/n answer to route.  ESC goes through %CLIENT-ESC-SWALLOW-START
   first (R4.3): a lone ESC byte here could be the first byte of a 3-byte
   arrow-key sequence, and closing the view immediately would hand its
   trailing 2 bytes to :normal mode's key pipeline as literal `[` and a
   letter, same hazard %HANDLE-CLIENT-PICKER-KEY-PAYLOAD's ESC clause guards
   against."
  (cond
    ((%client-byte-p payload 27)
      (%client-esc-swallow-start conn)
      (%close-help-view conn))
    ((or (%client-key-p payload #\q)
         (%client-key-p payload #\?)
         (%client-byte-p payload 13)
         (%client-byte-p payload 10)) (%close-help-view conn)))
  nil)
