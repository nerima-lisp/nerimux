;;;; Package definitions for nerimux.
;;;; All package declarations live here so cross-package dependencies are explicit.

(defpackage #:nerimux/version
  (:use #:cl)
  (:documentation
   "BOOTSTRAP layer: the compiled-in release version, kept in a package of its own
    so every reporter can reach it without dragging in a heavier dependency.  Read
    by -V, by the cl-cli option spec, by the XTVERSION (DA3) terminal reply, and by
    the #{version} format variable.")
  (:export #:version-string))

(in-package #:nerimux/version)

(defun version-string ()
  "Return the nerimux runtime version string."
  "0.1.0")
