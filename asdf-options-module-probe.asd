(in-package #:asdf-user)

(asdf:defsystem "asdf-options-module-probe"
  :components
  ((:module "src"
    :serial t
    :components nil))
  :build-operation "program-op"
  :build-pathname "nerimux"
  :entry-point "nerimux:main"
  :in-order-to ((test-op (test-op "asdf-options-module-probe/test"))))

(asdf:defsystem "asdf-options-module-probe/test"
  :depends-on ("asdf-options-module-probe")
  :components nil)

(asdf:defsystem "asdf-options-module-probe/second"
  :components nil)

(asdf:defsystem "asdf-depends-module-probe"
  :depends-on ("alpha" "beta" "gamma")
  :components
  ((:module "src"
    :serial t
    :components nil)))

(asdf:defsystem "asdf-depends-module-probe/second"
  :components nil)
