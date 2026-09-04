(defpackage #:nerimux/version
            (:use #:cl)
            (:documentation
             "FOUNDATION: the dependency-free source of the runtime version string.  It is
    used by command-line version reporting, terminal identification replies,
    and format expansion.")
            (:export #:version-string))

(in-package #:nerimux/version)

(defun version-string ()
  "Return the nerimux runtime version string.

   Kept as a literal, not a read of nerimux.asd's :version at runtime, because
   this package stays dependency-free even in the built standalone binary
   where ASDF's system definitions are not guaranteed to still be registered.
   nerimux.asd's :version is the single source of truth; the
   nerimux-version-string-matches-asdf-version test in
   tests/unit/bootstrap/package-version-tests.lisp pins this literal to it so the
   two cannot drift silently again."
  "0.3.0")
