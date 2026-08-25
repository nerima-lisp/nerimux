(in-package #:asdf-user)

(asdf:defsystem "nerimux"
  :description "A git-worktree workspace multiplexer in Common Lisp"
  :author "author <author@example.test>"
  :maintainer "maintainer <maintainer@example.test>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://example.test/nerimux"
  :bug-tracker "https://example.test/nerimux/issues"
  :source-control (:git "https://example.test/nerimux.git")
  :depends-on (:cl-date-kit
               :cl-concurrent-kit
               :cl-regex-kit
               :cl-cli
               :cl-parser-kit
               :cl-tty-kit
               :cl-process-kit
               :cl-codec-kit
               :cl-host-kit
               :cl-tui-kit/ansi
               :cl-tui-kit/layout
               :cl-tui-kit/widgets
               :cl-vcs-kit)
  :components
  ((:module "src"
    :serial t
    :components nil))
  :build-operation "program-op"
  :build-pathname "nerimux"
  :entry-point "nerimux:main"
  :in-order-to ((test-op (test-op "nerimux/test"))))

(asdf:defsystem "nerimux/test"
  :depends-on ("nerimux" (:version "cl-weave" "1.3.0"))
  :components nil)

(asdf:defsystem "nerimux/second"
  :components nil)
