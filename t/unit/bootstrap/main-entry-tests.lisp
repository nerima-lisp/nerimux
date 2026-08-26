(in-package #:nerimux/test)

;;;; Tests for CLI entry point reachability and command forwarding.

;;; ── Coverage: stub handler functions ─────────────────────────────────────────
;;;
;;; sb-ext:exit terminates the process rather than signalling a condition.
;;; We stub it to capture the exit code for testing.

(defmacro with-stubbed-exit (code-var &body body)
  "Stub sb-ext:exit so it captures the :code argument in the existing variable
   CODE-VAR and non-locally exits the body via THROW (matching sb-ext:exit's
   declared return type of NIL — a returning stub triggers SIMPLE-CONTROL-ERROR).
   Assertions should follow the macro form, where CODE-VAR holds the captured
   value.  Uses WITHOUT-PACKAGE-LOCKS because SB-EXT is a locked package."
  (let ((tag     (gensym "EXIT-TAG"))
        (orig    (gensym "ORIG-EXIT")))
    `(sb-ext:without-package-locks
       (let ((,orig (fdefinition 'sb-ext:exit)))
         (setf (fdefinition 'sb-ext:exit)
               (lambda (&rest args &key (code 0) &allow-other-keys)
                 (declare (ignore args))
                 (setf ,code-var code)
                 (throw ',tag nil)))
         (unwind-protect
              (catch ',tag ,@body)
           (setf (fdefinition 'sb-ext:exit) ,orig))))))

(describe "main-suite"

  ;;; ── run-attach-simple reachability ────────────────────────────────────────

  ;; run-attach-simple is defined as a function.
  (it "run-attach-simple-is-fbound"
    (expect (fboundp 'nerimux::run-attach-simple)))

  ;; Control mode (-C) was removed with the tmux compatibility surface. Both
  ;; entry points it had are gone: the "-C"/"control" *startup-modes* rows and
  ;; the :control cl-cli option that %dispatch-global-cli-flag-actions read.
  (it "control-mode-startup-modes-are-gone"
    (expect (null (nerimux::%startup-mode-entry "-C")))
    (expect (null (nerimux::%startup-mode-entry "control")))
    (expect (not (fboundp 'nerimux::run-control-mode))))

  ;; The above pins the tables; this pins the observable behaviour, which is
  ;; what a user actually hits.  -C is now rejected by cl-cli's global option
  ;; parser (main-startup-flags.lisp *cli-app* no longer declares it), so the
  ;; rejection happens inside %parse-global-cli-argv -- BEFORE
  ;; %dispatch-unknown-mode's dash-flag branch is reached.  Without this test,
  ;; re-registering -C as a cl-cli option pointing somewhere else would leave
  ;; the table assertions above green.
  ;;
  ;; This no longer stubs run-standalone -- that function was deleted along
  ;; with the rest of src/bootstrap/main.lisp, so there is nothing left for
  ;; -C to fall back to; the assertion that matters is that -C is rejected
  ;; with a usage error before dispatch, which exit-code and errout already
  ;; establish.
  (it "control-mode-flag-exits-with-usage"
    (let (exit-code
          errout)
      (setf errout
            (with-output-to-string (*error-output*)
              (with-stubbed-exit exit-code
                (let ((sb-ext:*posix-argv* (list "nerimux" "-C")))
                  (nerimux::main)))))
      (expect (eql 1 exit-code))
      (expect (search "usage: nerimux" errout) :to-be-truthy)))

  ;; An unrecognised command word -- previously forwarded to a running server
  ;; as a command client (e.g. "list-sessions") -- is now a plain usage error,
  ;; like every other case %dispatch-unknown-mode sees. The forwarding branch
  ;; and run-command-client are gone; nothing probes for a live server anymore.
  (it "dispatch-unknown-command-word-prints-usage-and-exits-one"
    (let (exit-code errout)
      (setf errout
            (with-output-to-string (*error-output*)
              (with-stubbed-exit exit-code
                (let ((sb-ext:*posix-argv* (list "nerimux" "list-sessions")))
                  (nerimux::main)))))
      (expect (eql 1 exit-code))
      (expect (search "usage: nerimux" errout) :to-be-truthy)))

  ;; `nerimux` with no arguments used to fall back to run-standalone; that
  ;; fallback is gone, so a bare invocation is now a usage error too -- the
  ;; entry surface has no implicit default mode anymore.
  (it "dispatch-no-arguments-prints-usage-and-exits-one"
    (let (exit-code errout)
      (setf errout
            (with-output-to-string (*error-output*)
              (with-stubbed-exit exit-code
                (let ((sb-ext:*posix-argv* (list "nerimux")))
                  (nerimux::main)))))
      (expect (eql 1 exit-code))
      (expect (search "usage: nerimux" errout) :to-be-truthy)))

  ;;; ── -V / --version / -h / --help / bad-flag usage ───────────────────────────

  ;; run-version prints "nerimux <version>" to stdout and exits 0.
  (it "run-version-prints-version-and-exits-zero"
    (let (exit-code output)
      (setf output
            (with-output-to-string (*standard-output*)
              (with-stubbed-exit exit-code
                (nerimux::run-version nil))))
      (expect (eql 0 exit-code))
      (expect (string= (format nil "nerimux ~A~%" (nerimux/version:version-string))
                       output))))

  ;; run-usage prints a usage summary to stdout and exits 0.
  (it "run-usage-prints-usage-and-exits-zero"
    (let (exit-code output)
      (setf output
            (with-output-to-string (*standard-output*)
              (with-stubbed-exit exit-code
                (nerimux::run-usage nil))))
      (expect (eql 0 exit-code))
      (expect (eql 0 (search "usage: nerimux" output)))))

  ;; argv -V/--version routes to run-version; -h/--help routes to run-usage.
  (it "dispatch-version-and-help-flags"
    (dolist (c '(("-V" :version) ("--version" :version)
                 ("-h" :usage)   ("--help" :usage)))
      (destructuring-bind (flag expected) c
        (let ((called nil))
          (with-stubbed-fdefinition
              ((nerimux::run-version
                (lambda (&rest a) (declare (ignore a)) (setf called :version)))
               (nerimux::run-usage
                (lambda (&rest a) (declare (ignore a)) (setf called :usage))))
            (let ((sb-ext:*posix-argv* (list "nerimux" flag)))
              (nerimux::main))
            (expect (eq expected called)))))))

  ;; An unknown dash-flag is a usage error (stderr + exit 1), not a silent
  ;; standalone start.  This no longer stubs run-standalone -- see the comment
  ;; on control-mode-flag-exits-with-usage above; that function is gone.
  (it "dispatch-unknown-dash-flag-prints-usage-and-exits-one"
    (let (exit-code
          errout)
      (setf errout
            (with-output-to-string (*error-output*)
              (with-stubbed-exit exit-code
                (let ((sb-ext:*posix-argv* (list "nerimux" "-Z")))
                  (nerimux::main)))))
      (expect (eql 1 exit-code))
      ;; cl-cli (main-startup-flags.lisp *cli-app*) now rejects -Z during global
      ;; flag parsing and prints its own diagnostic (e.g. "nerimux: Unknown
      ;; option...") before the usage block, so "usage: nerimux" no longer
      ;; starts at position 0 -- it just needs to be present.
      (expect (search "usage: nerimux" errout) :to-be-truthy)))

  ;; A mode handler that signals an ERROR (e.g. run-server hitting a runtime
  ;; failure) must be caught at main's top level and reported as a clean
  ;; stderr message + exit 1 -- never left to propagate into the raw SBCL
  ;; debugger the saved core would otherwise drop a real user into.  The old
  ;; version of this test drove the error through %parse-new-session-flags
  ;; rejecting an unsupported flag; that parser (and the new-session mode
  ;; itself) is gone, and no surviving mode (server, attach) does its own flag
  ;; parsing anymore, so the only way left to exercise main's handler-case is
  ;; to stub a mode handler to error directly.
  (it "unhandled-mode-error-prints-message-and-exits-one"
    (let (exit-code errout)
      (with-stubbed-fdefinition
          ((nerimux::run-server
            (lambda (name) (declare (ignore name)) (error "boom -x 80"))))
        (setf errout
              (with-output-to-string (*error-output*)
                (with-stubbed-exit exit-code
                  (let ((sb-ext:*posix-argv* (list "nerimux" "server" "work")))
                    (nerimux::main))))))
      (expect (eql 1 exit-code))
      (expect (search "nerimux:" errout) :to-be-truthy)
      (expect (search "boom -x 80" errout) :to-be-truthy)))

  ;; MAIN binds *PRINT-CIRCLE* T around the whole mode dispatch (see its
  ;; docstring): the domain model is cyclic (REPOSITORY <-> ORGANIZATION
  ;; back-pointers), and a condition report that walks into one without this
  ;; bound exhausts the control stack instead of printing.  Drive a mode
  ;; handler that captures the ambient value and errors, same shape as
  ;; unhandled-mode-error-prints-message-and-exits-one above.
  (it "main-binds-print-circle-around-mode-dispatch"
    (let (exit-code captured-print-circle)
      (with-stubbed-fdefinition
          ((nerimux::run-server
            (lambda (name)
              (declare (ignore name))
              (setf captured-print-circle *print-circle*)
              (error "boom"))))
        (with-output-to-string (*error-output*)
          (with-stubbed-exit exit-code
            (let ((sb-ext:*posix-argv* (list "nerimux" "server" "work"))
                  (*print-circle* nil))
              (nerimux::main)))))
      (expect (eql 1 exit-code))
      (expect (eq t captured-print-circle)))))
