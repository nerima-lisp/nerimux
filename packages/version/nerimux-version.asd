;;; This form comes FIRST, before any other form. ASDF binds *package* to
;;; ASDF-USER only for a file it loads itself; read any other way — a REPL
;;; `load`, an editor evaluating the buffer — the file is read in whatever
;;; package happens to be current, and an unqualified `defsystem` then fails to
;;; read at all. See PACKAGE_STANDARD.md "asd の書き方".
(in-package #:asdf-user)

;;; No "nerimux-version/test" system, and so no :in-order-to.
;;;
;;; This unit is one function returning a literal. What needs guarding is that
;;; the literal still equals nerimux.asd's :version, and that comparison can
;;; only be made from a system that can see nerimux.asd -- so it lives in the
;;; root suite as nerimux-version-string-matches-asdf-version, not here. An
;;; empty test system would report a vacuous pass instead.
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
