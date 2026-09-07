(in-package #:nerimux/test)

(describe "main-suite"


  (it "run-attach-simple-is-fbound"
    (expect (fboundp 'nerimux::run-attach-simple)))

  (it "run-attach-simple-routes-slash-selector-to-default-server-target"
    (let (ensure-args client-args)
      (with-stubbed-fdefinition
          ((nerimux::%ensure-server-running
            (lambda (&rest args) (setf ensure-args args)))
           (nerimux::run-client
            (lambda (&rest args) (setf client-args args))))
        (nerimux::run-attach-simple "org/repo")
        (expect (equal '("0") ensure-args))
        (expect (equal '("0" :target "org/repo") client-args)))))

  (it "run-attach-simple-keeps-plain-name-as-session"
    (let (client-args)
      (with-stubbed-fdefinition
          ((nerimux::%ensure-server-running (lambda (&rest _) (declare (ignore _)) nil))
           (nerimux::run-client
            (lambda (&rest args) (setf client-args args))))
        (nerimux::run-attach-simple "workspace")
        (expect (equal '("workspace") client-args)))))

  (it "workspace-attach-target-p-recognizes-path-like-selectors"
    (dolist (case '(("/tmp/worktree" . t) ("org/repository" . t)
                    ("repository" . nil) ("" . nil) (nil . nil) (42 . nil)))
      (expect (eql (cdr case)
                   (not (null (nerimux::%workspace-attach-target-p
                               (car case))))))))

  (it "strip-kill-reply-status-line-removes-status-and-blank-separator"
    (expect (string= (format nil "pane-1~%pane-2~%")
                     (nerimux::%strip-kill-reply-status-line
                      (format nil "DENIED~%pane-1~%pane-2~%"))))
    (expect (string= ""
                     (nerimux::%strip-kill-reply-status-line "DENIED"))))

  (it "control-mode-startup-modes-are-gone"
    (expect (null (nerimux::%startup-mode-entry "-C")))
    (expect (null (nerimux::%startup-mode-entry "control")))
    (expect (not (fboundp 'nerimux::run-control-mode))))

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

  (it "dispatch-unknown-command-word-prints-usage-and-exits-one"
    (let (exit-code errout)
      (setf errout
            (with-output-to-string (*error-output*)
              (with-stubbed-exit exit-code
                (let ((sb-ext:*posix-argv* (list "nerimux" "list-sessions")))
                  (nerimux::main)))))
      (expect (eql 1 exit-code))
      (expect (search "usage: nerimux" errout) :to-be-truthy)))

  (it "dispatch-no-arguments-falls-back-to-attach-with-default-session"
    (let (client-args)
      (with-stubbed-fdefinition
          ((nerimux::run-client
            (lambda (&rest args) (setf client-args args)))
           (nerimux::%ensure-server-running
            (lambda (&rest _) (declare (ignore _)) nil)))
        (let ((sb-ext:*posix-argv* (list "nerimux")))
          (nerimux::main)))
      (expect (equal '("0") client-args))))


  (it "run-version-prints-version-and-exits-zero"
    (let (exit-code output)
      (setf output
            (with-output-to-string (*standard-output*)
              (with-stubbed-exit exit-code
                (nerimux::run-version nil))))
      (expect (eql 0 exit-code))
      (expect (string= (format nil "nerimux ~A~%" (nerimux/version:version-string))
                       output))))

  (it "run-usage-prints-usage-and-exits-zero"
    (let (exit-code output)
      (setf output
            (with-output-to-string (*standard-output*)
              (with-stubbed-exit exit-code
                (nerimux::run-usage nil))))
      (expect (eql 0 exit-code))
      (expect (eql 0 (search "usage: nerimux" output)))))

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

  (it "dispatch-unknown-dash-flag-prints-usage-and-exits-one"
    (let (exit-code
          errout)
      (setf errout
            (with-output-to-string (*error-output*)
              (with-stubbed-exit exit-code
                (let ((sb-ext:*posix-argv* (list "nerimux" "-Z")))
                  (nerimux::main)))))
      (expect (eql 1 exit-code))
      (expect (search "usage: nerimux" errout) :to-be-truthy)))

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
