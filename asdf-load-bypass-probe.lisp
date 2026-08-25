(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))
(asdf/session:call-with-asdf-session
 (lambda ()
   (setf (asdf/session:asdf-upgraded-p
          (asdf/session:toplevel-asdf-session))
         t)
   (format t "BEFORE-LOAD-ASD~%")
   (finish-output)
   (asdf:load-asd (truename "nerimux.asd"))
   (format t "AFTER-LOAD-ASD~%")
   (finish-output)
   (format t "SYSTEM=~S~%" (asdf:find-system "nerimux"))
   (finish-output)
   (format t "BEFORE-LOAD~%")
   (finish-output)
   (asdf:load-system "nerimux" :verbose nil)
   (format t "AFTER-LOAD~%")
   (finish-output)))
