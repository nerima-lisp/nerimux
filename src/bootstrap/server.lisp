(in-package #:nerimux)

;;;; Detach-attach server: socket serve-loop.
;;;;
;;;; The server owns the session, PTYs, and per-pane reader threads, and serves
;;;; one attached client at a time over a Unix socket.  Client keystrokes are
;;;; run through the SAME process-byte pipeline the in-process loop uses, so
;;;; prefix commands / copy mode / prompts all behave identically when attached.
;;;; On detach the client disconnects but the session persists for re-attach;
;;;; the server only exits when the last window is killed (:quit) or *running*
;;;; is cleared.
;;;;
;;;; Session registry management (server-add-session, server-find-session)
;;;; lives in session-registry.lisp.
;;;;
;;;; with-incoming-frame is defined in nerimux/transport so both server and
;;;; client can use it without creating a circular dependency.

(defvar *bound-socket-path* nil
  "The socket path this server actually bound (#{socket_path}); NIL in
   standalone mode where no socket exists.")

(defvar *runtime-server-name* "default"
  "Name used to select the server's persistent runtime snapshot.")

(defun %socket-tmp-base ()
  "The socket base directory: $TMPDIR, else /tmp (§1.4 — no -L/-S override,
   and no tmux-derived temp-dir env var: R1.17 removed the CLI flags that
   could reach an override, and R2.7 drops that env var alongside them)."
  (let ((tmpdir (sb-ext:posix-getenv "TMPDIR")))
    (string-right-trim
     "/"
     (if (and tmpdir (plusp (length tmpdir))) tmpdir "/tmp"))))

(defun %socket-directory ()
  "Per-UID socket directory <base>/nerimux-<uid> (tmux's /tmp/tmux-UID/),
   created mode 0700 when possible.  Returns the directory string without a
   trailing slash.  Creation/chmod failures are ignored — socket binding will
   surface a real permission problem with a better error."
  (require :sb-posix)
  (let* ((uid (handler-case (sb-posix:getuid) (error () 0)))
         (dir (format nil "~A/nerimux-~D" (%socket-tmp-base) uid)))
    (ignore-errors
      (ensure-directories-exist (format nil "~A/" dir))
      (sb-posix:chmod dir #o700))
    dir))

(defun socket-path (name)
  "Filesystem path of the Unix socket for the server named NAME: a fixed name
   inside the per-UID socket directory (§1.4). No -L/-S override exists —
   R1.17 removed the CLI flags that could set one."
  (format nil "~A/nerimux-~A.sock" (%socket-directory) name))

(defconstant +status-line-rows+ 1
  "Rows the status bar occupies. Fixed at 1 (§1.4 — no `status' option).")

(defun %relayout-active-window (session rows cols)
  "Relayout SESSION's active window for ROWS and COLS, if any."
  (let ((active-window (session-active-window session)))
    (when active-window
      (window-relayout active-window
                       (- rows +status-line-rows+)
                       cols))))

;;; ── Message-type dispatch macro ──────────────────────────────────────────────
;;;
;;; define-msg-dispatch follows the define-csi-rules / with-incoming-frame
;;; Prolog-dispatch pattern: a declarative rule table whose keys are message-type
;;; predicates and whose bodies are handler forms.  TYPE and PAYLOAD are bound in
;;; every rule body.  The generated function returns the serve-loop outcome.
;;;
;;; define-message-dispatch-fn is the shared COND-expansion engine used by both
;;; define-msg-dispatch (single-client server) and define-multi-msg-dispatch
;;; (multi-client server, server-multi.lisp + server-multi-loop.lisp).  Both
;;; wrappers delegate to it so the two event loops can never diverge in their
;;; macro structure.

(defmacro define-message-dispatch-fn (fn-name lambda-list docstring &rest rules)
  "Build a named message-dispatch function from a declarative rule table.
   FN-NAME is the symbol to DEFUN; LAMBDA-LIST is its full argument list;
   DOCSTRING is its documentation string.  Each RULE is (condition &rest body).
   The generated function dispatches via COND and returns whatever the matching
   arm returns.  Shared infrastructure for define-msg-dispatch (server.lisp) and
   define-multi-msg-dispatch (server-multi.lisp + server-multi-loop.lisp).

   Prolog analogy:
     fn(nil, ...) :- rule1-body.
     fn(T1,  ...) :- rule2-body.
     fn(T2,  ...) :- rule3-body."
  `(defun ,fn-name ,lambda-list
     ,docstring
     (cond
       ,@(mapcar (lambda (rule)
                   (destructuring-bind (condition &rest body) rule
                     `(,condition ,@body)))
                 rules))))

(defun run-server (name)
  "Run a headless server owning a session, serving clients attaching to
   (socket-path NAME).  The session persists across detaches until its last
   window is killed."
  (require :sb-posix)
  (install-pty-port)              ; wire the PTY adapter into the domain port
  (setf *running*          t
        *dirty*            t
        *resize-pending*   nil
        *server-sessions*  nil
        *runtime-server-name* name)
  (let* ((session (create-initial-session *term-rows* *term-cols*))
         (path    (socket-path name)))
    (setf *bound-socket-path* path)
    (server-add-session session)
    (ignore-errors (delete-file path))
    (let ((listener (make-listener path)))
      (dolist (pane (all-panes session))
        (start-reader-thread pane))
      (install-sigwinch-handler)
      (unwind-protect
   ;; Multi-client event loop: a single select(2) over the listener fd +
   ;; every attached client fd, serving them all concurrently
   ;; (%run-multi-server-loop, server-multi-loop.lisp).
           (%run-multi-server-loop listener session)
        (close-socket listener)
        (ignore-errors (delete-file path))
        (dolist (pane (all-panes session))
          (close-pane-pty pane))))))
