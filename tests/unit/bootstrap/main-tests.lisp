(in-package #:nerimux/test)

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
          (nerimux::%ensure-server-running
           (lambda (&rest _) (declare (ignore _)) nil)))
       ,@body)))

(describe "main-suite"

  (it "application-argv-strips-sbcl-wrapper-options"
    (let ((sb-ext:*posix-argv*
            (list "sbcl" "--noinform" "--core" "/nix/store/core"
                  "--no-sysinit" "--no-userinit"
                  "attach" "myname")))
      (expect (equal '("attach" "myname")
                     (nerimux::%application-argv)))))

  (it "application-argv-strips-the-last-wrapper-option-marker"
    (let ((sb-ext:*posix-argv*
            (list "sbcl" "--noinform" "attach" "--end-toplevel-options"
                  "server" "0")))
      (expect (equal '("server" "0")
                     (nerimux::%application-argv)))))

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

  (it "dispatch-unknown-mode-prints-usage-and-exits-one"
    (with-stubbed-entries
      (let (exit-code errout)
        (setf errout
              (with-output-to-string (*error-output*)
                (with-stubbed-exit exit-code
                  (let ((sb-ext:*posix-argv* (list "nerimux" "bogus" "foo")))
                    (nerimux::main)))))
        (expect (eql 1 exit-code))
        (expect (search "usage: nerimux" errout) :to-be-truthy)
        (expect (null *main-calls*)))))

  (it "dispatch-no-args-falls-back-to-attach-with-default-session"
    (with-stubbed-entries
      (let ((sb-ext:*posix-argv* (list "nerimux")))
        (nerimux::main))
      (expect (= 1 (length *main-calls*)))
      (expect (eq :client (car (first *main-calls*))))
      (expect (equal "0" (first (cdr (first *main-calls*)))))))

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


  (it "startup-modes-contains-server-and-attach"
    (expect (assoc "server" nerimux::*startup-modes* :test #'equal))
    (expect (assoc "attach" nerimux::*startup-modes* :test #'equal))
    (dolist (name '("server" "attach"))
      (let ((entry (alist-value name nerimux::*startup-modes* :test #'equal)))
        (expect (consp entry))
        (expect (symbolp (first entry))))))


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


  (it "startup-modes-version-flag-has-raw-args-key"
    (let ((entry (alist-value "-V" nerimux::*startup-modes* :test #'equal)))
      (expect (getf (rest entry) :raw-args-p) :to-be-truthy)))

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


  (it "server-socket-poll-constants-are-positive"
    (expect (plusp nerimux::+server-socket-poll-interval-seconds+))
    (expect (plusp nerimux::+server-socket-poll-max-iterations+))
    (expect (integerp nerimux::+server-socket-poll-max-iterations+))))
