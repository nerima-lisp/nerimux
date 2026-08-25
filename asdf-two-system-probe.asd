(in-package #:asdf-user)

(defsystem "probe-one")

(defsystem "probe-two"
  :depends-on ("probe-one"))
