(in-package #:asdf-user)

;;; The root suite compares this literal with nerimux.asd's :version.
(defsystem "nerimux-version"
  :description "FOUNDATION compiled-in release version for nerimux, depending on nothing"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "0.3.0"
  :homepage "https://github.com/nerima-lisp/nerimux"
  :bug-tracker "https://github.com/nerima-lisp/nerimux/issues"
  :source-control (:git "https://github.com/nerima-lisp/nerimux.git")
  :depends-on ()
  :pathname "src"
  :serial t
  :components ((:file "version")))
