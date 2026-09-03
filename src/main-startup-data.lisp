(in-package #:nerimux)

(defmacro %startup-mode (mode-name handler &key raw-args-p)
  `(list ,mode-name
         ',handler
         ,@(when raw-args-p
             '(:raw-args-p t))))

(defparameter *startup-modes*
  (list (%startup-mode "server" run-server)
        (%startup-mode "attach" run-attach-simple)
        (%startup-mode "kill" run-kill :raw-args-p t)
        (%startup-mode "-V" run-version :raw-args-p t)
        (%startup-mode "--version" run-version :raw-args-p t)
        (%startup-mode "-h" run-usage :raw-args-p t)
        (%startup-mode "--help" run-usage :raw-args-p t))
  "Mode-name to handler metadata for the binary entry point.")
