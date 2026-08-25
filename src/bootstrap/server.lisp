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
   and no legacy temp-dir env var override: R1.17 removed the CLI flags
   that could reach one, and R2.7 dropped the env var alongside them)."
  (let ((tmpdir (sb-ext:posix-getenv "TMPDIR")))
    (string-right-trim
     "/"
     (if (and tmpdir (plusp (length tmpdir))) tmpdir "/tmp"))))

(defun %socket-directory ()
  "Per-UID socket directory <base>/nerimux-<uid>, created mode 0700 when
   possible.  Returns the directory string without a
   trailing slash.  Creation/chmod failures are ignored — socket binding will
   surface a real permission problem with a better error."
  (require :sb-posix)
  (let* ((uid (sb-posix:getuid))
         (dir (format nil "~A/nerimux-~D" (%socket-tmp-base) uid)))
    (handler-case
        (ensure-directories-exist (format nil "~A/" dir))
      (file-error () nil))
    (handler-case
        (sb-posix:chmod dir #o700)
      (sb-posix:syscall-error () nil))
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
;;; (below, used by the multi-client runtime).  Both
;;; wrappers delegate to it so the two event loops can never diverge in their
;;; macro structure.

(defmacro define-message-dispatch-fn (fn-name lambda-list docstring &rest rules)
  "Build a named message-dispatch function from a declarative rule table.
   FN-NAME is the symbol to DEFUN; LAMBDA-LIST is its full argument list;
   DOCSTRING is its documentation string.  Each RULE is (condition &rest body).
   The generated function dispatches via COND and returns whatever the matching
   arm returns.  Shared infrastructure for define-msg-dispatch (server.lisp) and
   define-multi-msg-dispatch (below).

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

(defmacro define-multi-msg-dispatch (&rest rules)
  "Build %HANDLE-MULTI-CLIENT-MESSAGE from a message-type rule table.

Each RULE is (CONDITION &rest BODY). TYPE, PAYLOAD, SESSION, and CONN are
bound in every rule body. The shared dispatch macro keeps the single-client
and multi-client message handlers structurally aligned."
  `(define-message-dispatch-fn
       %handle-multi-client-message
       (type payload session conn)
       "Dispatch one message of TYPE/PAYLOAD from client CONN.  Returns a disposition:
     :quit           — a command ended the session (loop must stop);
     :drop           — CONN should be removed (EOF / detach / unknown type);
     :detach-others  — drop every OTHER client (the `attach -d' request);
     NIL             — keep serving.
   Resize/attach updates CONN's geometry and re-applies the effective size; keys
   run through the shared prefix/copy-mode pipeline with CONN's private state."
       ,@rules))

;;; ── Key-payload and UI-command dispatch macros ───────────────────────────────
;;;
;;; The same pattern-polymorphism DEFINE-STATE uses for the terminal parser
;;; (nerimux/terminal/parser's parser-core.lisp: an integer pattern becomes a
;;; byte-equality test, a symbol becomes a predicate call, anything else
;;; passes through verbatim) generalized one layer up again, for the two
;;; remaining hand-rolled COND shapes in the client dispatch layer: matching a
;;; key payload against a literal character/byte, and matching a UI command
;;; keyword against a literal keyword/keyword-list. Both keep the same
;;; escape hatch DEFINE-STATE does — a pattern that isn't one of the literal
;;; shapes passes through as the COND test unchanged, so a compound AND/OR or
;;; a predicate call reads exactly as it always did.
;;;
;;; %HANDLE-CLIENT-UI-COMMAND dispatches a fixed, compile-time-enumerable set
;;; of workspace UI command keywords reached from exactly two call sites
;;; (%handle-multi-command-message and %submit-client-command) — not the
;;; open-ended, user-configurable tmux command table R1 deleted (see git log
;;; 2a5fa47, "delete the tmux command table and keystroke pipeline"). That
;;; table's failure mode was runtime FIND-SYMBOL over an unbounded,
;;; config-file-driven vocabulary; DEFINE-COMMAND-RULES below expands to a
;;; literal, compile-time COND over a closed keyword set, which is a
;;; different mechanism, not a reintroduction of the deleted one.

(defmacro define-key-rules (name (session-var conn-var payload-var) &rest clauses)
  "Build a named key-payload dispatch function from a declarative rule table.
   CLAUSES may start with a docstring, exactly like an ordinary DEFUN body,
   then an optional (:LET ((var expr)...)) form -- exactly a LET*, in scope
   for every rule below it -- for a dispatcher whose rules need shared
   context (e.g. the focused pane's screen) rather than PAYLOAD-VAR alone.
   Each remaining RULE is (PATTERN &rest BODY) where PATTERN is:
     character → (%CLIENT-KEY-P PAYLOAD-VAR character)
     integer   → (%CLIENT-BYTE-P PAYLOAD-VAR integer)
     t         → default clause
     anything else → used verbatim as the COND test
   SESSION-VAR, CONN-VAR, and PAYLOAD-VAR are bound in every rule body."
  (let* ((docstring (and (stringp (first clauses)) (first clauses)))
         (rest1 (if docstring (rest clauses) clauses))
         (let-form (and (consp (first rest1)) (eq (caar rest1) :let)
                        (first rest1)))
         (bindings (second let-form))
         (rules (if let-form (rest rest1) rest1)))
    `(defun ,name (,session-var ,conn-var ,payload-var)
       ,@(when docstring (list docstring))
       (declare (ignorable ,session-var ,conn-var ,payload-var))
       (let* ,bindings
         (cond
           ,@(mapcar
              (lambda (rule)
                (destructuring-bind (pattern &rest body) rule
                  `(,(cond
                       ((eq pattern t)       t)
                       ((characterp pattern) `(%client-key-p ,payload-var ,pattern))
                       ((integerp pattern)   `(%client-byte-p ,payload-var ,pattern))
                       (t                    pattern))
                    ,@body)))
              rules))))))

(defmacro define-command-rules
    (name (session-var conn-var cmd-var target-var args-var) &rest clauses)
  "Build a named UI-command dispatch function from a declarative rule table.
   CLAUSES may start with a docstring, exactly like an ordinary DEFUN body.
   Each remaining RULE is (PATTERN &rest BODY) where PATTERN is:
     (keyword...) → (MEMBER CMD-VAR '(keyword...) :test #'EQ)
     keyword      → (EQ CMD-VAR keyword)
     t            → default clause
     anything else → used verbatim as the COND test
   SESSION-VAR, CONN-VAR, CMD-VAR, TARGET-VAR, and ARGS-VAR are bound in
   every rule body."
  (let* ((docstring (and (stringp (first clauses)) (first clauses)))
         (rules (if docstring (rest clauses) clauses)))
    `(defun ,name (,session-var ,conn-var ,cmd-var ,target-var ,args-var)
       ,@(when docstring (list docstring))
       (declare (ignorable ,session-var ,conn-var ,cmd-var ,target-var ,args-var))
       (cond
         ,@(mapcar
            (lambda (rule)
              (destructuring-bind (pattern &rest body) rule
                `(,(cond
                     ((eq pattern t) t)
                     ((and (consp pattern) (every #'keywordp pattern))
                      `(member ,cmd-var ',pattern :test #'eq))
                     ((keywordp pattern) `(eq ,cmd-var ,pattern))
                     (t pattern))
                  ,@body)))
            rules)))))

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
    (handler-case (delete-file path)
      (file-error () nil))
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
        (handler-case (delete-file path)
          (file-error () nil))
        (dolist (pane (all-panes session))
          (close-pane-pty pane))))))
