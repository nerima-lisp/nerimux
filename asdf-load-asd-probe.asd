(in-package #:asdf-user)

(format t "PROBE-BEFORE-DEFSYSTEM~%")
(defsystem "asdf-load-asd-probe"
  :description "Temporary ASDF load-asd probe"
  :version "0.0.1"
  :components nil)
(format t "PROBE-AFTER-DEFSYSTEM~%")
