(in-package #:nerimux/test)

(describe "client-startup-modes-suite"

  (it "startup-modes-all-handlers-are-symbols"
    (dolist (entry nerimux::*startup-modes*)
      (let ((handler (first (cdr entry))))
        (expect (symbolp handler)))))

  (it "startup-modes-mode-handlers-table"
    (dolist (c '(("server"     nerimux::run-server        nil "server → run-server")
                 ("attach"     nerimux::run-attach-simple nil "attach → run-attach-simple")
                 ("-V"         nerimux::run-version         t "-V → run-version")
                 ("-h"         nerimux::run-usage           t "-h → run-usage")))
      (destructuring-bind (mode handler raw-args-p desc) c
        (declare (ignore desc))
        (let ((entry (assoc mode nerimux::*startup-modes* :test #'equal)))
          (expect entry :to-be-truthy)
          (expect (eq handler (first (cdr entry))))
          (when raw-args-p
            (expect (getf (rest (cdr entry)) :raw-args-p) :to-be-truthy)))))))
