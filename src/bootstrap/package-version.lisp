;;;; Package definitions for nerimux.
;;;; All package declarations live here so cross-package dependencies are explicit.

(defpackage #:nerimux/version
  (:use #:cl)
  (:documentation
   "FOUNDATION: the compiled-in release version, kept in a package of its own so
    every reporter can reach it without dragging in a heavier dependency.  Read by
    -V, by the cl-cli option spec, by the XTVERSION (DA3) terminal reply, and by
    the #{version} format variable.

    Marked FOUNDATION rather than BOOTSTRAP, which is what it used to claim.  It
    depends on nothing, its fragment is the first one package.lisp loads, and its
    one function returns a constant -- while three of its four callers sit in
    DOMAIN (csi-replies, format-context-screen) and APPLICATION
    (config-directives-set).  Under the old label those were upward references,
    and no-source-file-references-a-higher-layer-package found all three the first
    time it ran.  The label was wrong, not the callers.")
  (:export #:version-string))

(in-package #:nerimux/version)

(defun version-string ()
  "Return the nerimux runtime version string."
  "0.1.0")
