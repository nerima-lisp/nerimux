(in-package #:asdf-user)

(asdf:defsystem "asdf-module-probe-one"
  :components
  ((:module "src"
    :serial t
    :components nil)))

(asdf:defsystem "asdf-module-probe-two"
  :components nil)
