(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(require :sb-posix)

(format t "~&Before minimal load~%")
(finish-output)
(let ((*package* (find-package :asdf-user)))
  (load (truename "asdf-two-system-probe.asd")))
(format t "~&After minimal load~%")
(finish-output)

(format t "~&Registered ~S~%"
        (let ((symbol (find-symbol "REGISTERED-SYSTEMS" :asdf)))
          (when (and symbol (fboundp symbol))
            (funcall symbol))))
(finish-output)
