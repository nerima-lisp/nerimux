(in-package #:nerimux)

;; SERVER-MULTI.LISP initializes the registry after this dispatch file loads.
(declaim (special *clients*))

(defvar *last-selected-worktree-token* nil
  "Stable selector for the most recently selected worktree across clients.")

;;;; Multi-client message handlers extracted from server-multi.lisp.
;;;;
;;;; The event loop keeps the dispatch table, while these helpers own the
;;;; per-message policy for attach/resize, keys, and forwarded commands.

;;; WITH-LOOP-SAFE-ERROR is defined here because this file owns the per-client
;;; handler policy and every handler below uses the same error boundary.  The
;;; message-dispatch macro itself lives in server.lisp, which ASDF loads before
;;; this file; server-multi.lisp then uses the same expansion.
(defmacro with-loop-safe-error (binding &body body)
  "Run BODY, catching any ERROR so one bad client/command can never wedge the
   multi-client event loop.  On success, returns BODY's value; on an ERROR,
   evaluates and returns ON-ERROR instead — optionally with the condition bound
   to CONDITION-VAR so ON-ERROR can log it.  This is the single shape behind
   this file's 'never let one client take down the server loop' invariant."
  (let ((condition-var (first binding))
        (on-error (getf (rest binding) :on-error)))
    `(handler-case (progn ,@body)
       (error ,(if condition-var (list condition-var) '())
         ,on-error))))

(defvar *client-esc-swallow-counts* (make-hash-table :test #'eq :weakness :key)
  "CONN -> count of upcoming key bytes to discard unconditionally.

Set by ESC in a text-input UI mode (:picker / :command, R4.3): the client
forwards stdin one byte at a time, so an arrow key still arrives as the
3-byte escape sequence ESC [ A/B/C/D, split across three separate key
messages. R4.1 dropped byte-sequence matching entirely, so without this the
trailing 2 bytes of that sequence would land on whatever key handler runs
next (typically the search/command buffer) as literal `[` and a letter.
Keyed by CONN rather than a client-conn slot because client-conn is defined
in server-multi.lisp, outside this file's scope; :weakness :key lets a
dropped connection's entry be reclaimed instead of leaking.")

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

(defun %handle-multi-key-message (session conn payload)
  "Feed PAYLOAD through the stdin-target fast path or the shared key pipeline.
   A byte consumed by CONN's pending ESC-swallow (R4.3) never reaches any of
   this: it is discarded before the prefix key and mode dispatch even see it."
  (cond
    ;; Swallowed by a pending ESC sequence (R4.3): never reaches any dispatch.
    ((%client-esc-swallow-consume conn) nil)
    ;; A confirmation owns every key while it is up (R6.4).
    ((client-conn-confirm-view conn)
     (nth-value 1 (%handle-confirm-key session conn payload)))
    (t
     (multiple-value-bind (prefix-handled prefix-result)
         (%handle-workspace-prefix-key session conn payload)
       (if prefix-handled
           prefix-result
           (cond
             ((and (eq (client-conn-mode conn) :normal)
                   (%client-byte-p payload 16))
              (%open-client-picker conn))
             ((eq (client-conn-mode conn) :picker)
              (%handle-client-picker-key-payload session conn payload))
             ((eq (client-conn-mode conn) :input)
              (%handle-client-input-key-payload session conn payload))
             ((eq (client-conn-mode conn) :copy)
              (%handle-client-copy-key-payload session conn payload))
             ((eq (client-conn-mode conn) :command)
              (%handle-client-command-key-payload session conn payload))
             ;; A key the workspace UI does not bind is dropped in :normal mode.
             ;; It used to fall through to the prefix-key keystroke pipeline
             ;; (prefix key + key tables) -- that fallthrough was the only
             ;; thing making prefix bindings reachable from an attached
             ;; client.  Typing into a pane is what :input mode is for; a
             ;; stdin-target still gets fed.
             ((eq (client-conn-mode conn) :normal)
              (or (%handle-client-normal-key-payload session conn payload)
                  (%feed-client-stdin-target conn payload)))
             (t
              (%feed-client-stdin-target conn payload))))))))

(defun %feed-client-stdin-target (conn payload)
  "Feed PAYLOAD to CONN's split-window -I stdin target, if it has one.
   Returns NIL either way: an unbound key is a no-op, not a loop disposition."
  (let ((stdin-target (client-conn-stdin-target conn)))
    (when stdin-target
      (pane-feed stdin-target payload)
      (%mark-dirty))
    nil))

(defun %handle-workspace-prefix-key (session conn payload)
  "Handle the client-local prefix (C-q, R4.4) and the key it introduces.

The prefix is consumed before the stdin-target path.  Once struck, the next
byte is resolved against 1.5's binding table by %workspace-prefix-dispatch;
a byte the table does not recognize is discarded there instead of falling
through to the normal key pipeline — the old 'unbound means pass through'
behavior (:96-107 pre-R4.4) is gone."
  (let ((single-byte (and (arrayp payload)
                          (= (length payload) 1)
                          (aref payload 0))))
    (cond
      ((client-conn-ui-prefix-p conn)
       (setf (client-conn-ui-prefix-p conn) nil)
       (values t (%workspace-prefix-dispatch session conn single-byte)))
      ((and (integerp single-byte)
            (= single-byte (client-conn-workspace-prefix-code conn)))
       (setf (client-conn-ui-prefix-p conn) t)
       (values t nil))
      (t
       (values nil nil)))))
