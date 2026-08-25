(require :asdf)

(let ((main-thread sb-thread:*current-thread*))
  (sb-thread:make-thread
   (lambda ()
     (sleep 2)
     (sb-thread:interrupt-thread
      main-thread
      (lambda ()
        (format *error-output* "WATCHDOG-BACKTRACE~%")
        (finish-output *error-output*)
        (sb-debug:backtrace 80)
        (finish-output *error-output*)
        (sb-ext:exit :code 2))))))

(load (truename "asdf-main-option-isolate.lisp"))
