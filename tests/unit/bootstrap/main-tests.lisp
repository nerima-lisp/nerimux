(in-package #:nerimux/test)

;;;; Tests for argv dispatch routing in src/bootstrap/main-startup*.lisp
;;;; (server/attach entry surface).
(defvar *main-calls*
  nil
  "Records (TAG . ARGS) for each stubbed entry function call.")

(defmacro with-stubbed-entries (&body body)
  "Replace run-server / run-client with recorders that push onto *main-calls*,
   and stub %ensure-server-running to a no-op so tests do not probe or spawn
   real sockets.  Runs BODY with a fresh *main-calls*, then restores."
  `(let ((*main-calls* nil))
     (with-stubbed-fdefinition
         ((nerimux::run-server
           (lambda (&rest a) (push (cons :server a) *main-calls*)))
          (nerimux::run-client
           (lambda (&rest a) (push (cons :client a) *main-calls*)))
          ;; Stub out the socket-probe / server-spawn so tests stay fast and
          ;; sandboxed.  run-client is still called; attach tests check that.
          (nerimux::%ensure-server-running
           (lambda (&rest _) (declare (ignore _)) nil)))
       ,@body)))

(defmacro with-stubbed-main-exit (code-var &body body)
  "Stub sb-ext:exit so it captures the :code argument in the existing variable
   CODE-VAR and non-locally exits BODY via THROW (matching sb-ext:exit's
   declared return type of NIL — a returning stub triggers SIMPLE-CONTROL-ERROR).
   Uses WITHOUT-PACKAGE-LOCKS because SB-EXT is a locked package."
  (let ((tag (gensym "EXIT-TAG"))
        (orig (gensym "ORIG-EXIT")))
    `(sb-ext:without-package-locks
      (let ((,orig (fdefinition 'sb-ext:exit)))
        (setf (fdefinition 'sb-ext:exit) (lambda 
                                             (&rest args
                                                    &key
                                                    (code 0)
                                                    &allow-other-keys)
                                           (declare (ignore args))
                                           (setf ,code-var code)
                                           (throw ',tag
                                             nil)))
        (unwind-protect 
            (catch ',tag
              ,@body)
          (setf (fdefinition 'sb-ext:exit) ,orig))))))

(describe "main-suite"

  ;; %application-argv drops SBCL saved-core wrapper options before dispatch.
  (it "application-argv-strips-sbcl-wrapper-options"
    (let ((sb-ext:*posix-argv*
            (list "sbcl" "--noinform" "--core" "/nix/store/core"
                  "--no-sysinit" "--no-userinit"
                  "attach" "myname")))
      (expect (equal '("attach" "myname")
                     (nerimux::%application-argv)))))

  ;; main routes argv to the correct entry point with the correct session name
  ;; (the first positional entry-function argument).
  (it "dispatch-main-table"
    (dolist (c '((("server" "foo") :server "foo" "server with name")
                 (("attach" "foo") :client "foo" "attach with name")
                 (("server")       :server "0"   "server default name")
                 (("attach")       :client "0"   "attach default name")))
      (destructuring-bind (argv-tail expected-key expected-name desc) c
        (declare (ignore desc))
        (with-stubbed-entries
          (let ((sb-ext:*posix-argv* (cons "nerimux" argv-tail)))
            (nerimux::main))
          (expect (= 1 (length *main-calls*)))
          (expect (eq expected-key (car (first *main-calls*))))
          (expect (equal expected-name (first (cdr (first *main-calls*)))))))))

  ;; An unrecognized mode word is a usage error: %dispatch-unknown-mode no
  ;; longer forwards to a running server or falls back to a standalone run,
  ;; it always prints usage to *error-output* and exits 1, and no entry
  ;; function is dispatched.
  (it "dispatch-unknown-mode-prints-usage-and-exits-one"
    (with-stubbed-entries
      (let (exit-code errout)
        (setf errout
              (with-output-to-string (*error-output*)
                (with-stubbed-main-exit exit-code
                  (let ((sb-ext:*posix-argv* (list "nerimux" "bogus" "foo")))
                    (nerimux::main)))))
        (expect (eql 1 exit-code))
        (expect (search "usage: nerimux" errout) :to-be-truthy)
        (expect (null *main-calls*)))))

  ;; FR-001: a bare `nerimux` (no argv at all) no longer takes the
  ;; unknown-mode usage-error path -- %dispatch-startup-mode-entry defaults
  ;; that case to `attach` at its own default-session convention, so this
  ;; dispatches exactly like the ("attach") row of dispatch-main-table above:
  ;; one :client call, session name "0", and no usage error/exit at all.
  (it "dispatch-no-args-falls-back-to-attach-with-default-session"
    (with-stubbed-entries
      (let ((sb-ext:*posix-argv* (list "nerimux")))
        (nerimux::main))
      (expect (= 1 (length *main-calls*)))
      (expect (eq :client (car (first *main-calls*))))
      (expect (equal "0" (first (cdr (first *main-calls*)))))))

  ;; main routes argv correctly when the saved core is launched through SBCL options.
  (it "dispatch-main-from-sbcl-wrapper-argv"
    (with-stubbed-entries
      (let ((sb-ext:*posix-argv*
              (list "sbcl" "--noinform" "--core" "/nix/store/core"
                    "--no-sysinit" "--no-userinit"
                    "server" "myserver")))
        (nerimux::main))
      (expect (= 1 (length *main-calls*)))
      (expect (eq :server (car (first *main-calls*))))
      (expect (equal "myserver" (first (cdr (first *main-calls*)))))))

  ;;; ── *startup-modes* data table ───────────────────────────────────────────────

  ;; *startup-modes* has handler entries for server and attach.
  (it "startup-modes-contains-server-and-attach"
    (expect (assoc "server" nerimux::*startup-modes* :test #'equal))
    (expect (assoc "attach" nerimux::*startup-modes* :test #'equal))
    ;; Each entry's cdr is a list starting with the handler symbol.
    (dolist (name '("server" "attach"))
      (let ((entry (alist-value name nerimux::*startup-modes* :test #'equal)))
        (expect (consp entry))
        (expect (symbolp (first entry))))))

  ;;; ── %startup-mode-raw-args-p ────────────────────────────────────────────────

  ;; %startup-mode-raw-args-p returns T only for the version/help flags, which
  ;; receive the full argv tail; name-only modes and unknown words are falsy.
  (it "startup-mode-raw-args-p-known-raw-modes"
    (expect (nerimux::%startup-mode-raw-args-p "-V") :to-be-truthy)
    (expect (nerimux::%startup-mode-raw-args-p "--version") :to-be-truthy)
    (expect (nerimux::%startup-mode-raw-args-p "-h") :to-be-truthy)
    (expect (nerimux::%startup-mode-raw-args-p "--help") :to-be-truthy)
    (expect (nerimux::%startup-mode-raw-args-p "server") :to-be-falsy)
    (expect (nerimux::%startup-mode-raw-args-p "attach") :to-be-falsy)
    (expect (nerimux::%startup-mode-raw-args-p "bogus") :to-be-falsy))

  (it "dispatches-raw-startup-handler-with-complete-argv-tail"
    (let ((received nil))
      (with-stubbed-fdefinition
          ((nerimux::run-version
             (lambda (args)
               (setf received args))))
        (nerimux::%dispatch-startup-mode-handler
         (nerimux::%startup-mode-entry "-V")
         "-V"
         '("--version" "extra")))
      (expect (equal '("--version" "extra") received) :to-be-truthy)))

  ;;; ── *startup-modes* table structure tests ────────────────────────────────────

  ;; The '-V' entry in *startup-modes* carries :raw-args-p T (it receives the
  ;; full argv tail rather than a single session name, like --version/-h/--help).
  (it "startup-modes-version-flag-has-raw-args-key"
    (let ((entry (alist-value "-V" nerimux::*startup-modes* :test #'equal)))
      (expect (getf (rest entry) :raw-args-p) :to-be-truthy)))

  ;; Each *startup-modes* entry names the correct handler symbol.
  (it "startup-modes-handler-table"
    (dolist (c '(("server"    nerimux::run-server        "server → run-server")
                 ("attach"    nerimux::run-attach-simple  "attach → run-attach-simple")
                 ("-V"        nerimux::run-version        "-V → run-version")
                 ("--version" nerimux::run-version        "--version → run-version")
                 ("-h"        nerimux::run-usage          "-h → run-usage")
                 ("--help"    nerimux::run-usage          "--help → run-usage")))
      (destructuring-bind (mode expected-fn desc) c
        (declare (ignore desc))
        (let ((entry (alist-value mode nerimux::*startup-modes* :test #'equal)))
          (expect (eq expected-fn (first entry)))))))

  ;;; ── server-socket-poll constants ─────────────────────────────────────────────

  ;; +server-socket-poll-interval-seconds+ and +server-socket-poll-max-iterations+
  ;; are positive numbers used to bound the server-start wait loop.
  (it "server-socket-poll-constants-are-positive"
    (expect (plusp nerimux::+server-socket-poll-interval-seconds+))
    (expect (plusp nerimux::+server-socket-poll-max-iterations+))
    (expect (integerp nerimux::+server-socket-poll-max-iterations+))))
