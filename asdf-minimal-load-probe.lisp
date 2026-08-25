(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(require :sb-posix)

(let ((*package* (find-package :asdf-user)))
  (load (truename "asdf-two-system-probe.asd")))

(format t "Before minimal load-system~%")
(finish-output)
(asdf:load-system "probe-one")
(format t "After minimal load-system~%")
(finish-output)
