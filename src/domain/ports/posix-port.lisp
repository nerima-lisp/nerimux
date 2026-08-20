(in-package #:nerimux/ports)

;;;; POSIX symbol lookup.
;;;;
;;;; Domain code must not depend on SB-POSIX being present, and must not reach
;;;; up into the application layer to ask.  This resolves an SB-POSIX function
;;;; by name at CALL time -- deferred, so a load-time defvar cannot capture NIL
;;;; before the package exists -- and returns NIL when the implementation does
;;;; not offer it, leaving the caller to decide what a missing syscall means.
;;;;
;;;; It lived in nerimux/config, which made every domain caller depend upward on
;;;; application for a pure reflection helper.  Its application-side callers now
;;;; depend downward on this package instead, which is the direction the layering
;;;; rule allows.

(defun find-posix-function (name)
  "The SB-POSIX function named NAME, or NIL when SB-POSIX is absent or does not
   export it.  NAME is a string, e.g. \"SETENV\"."
  (let ((package (find-package "SB-POSIX")))
    (and package (find-symbol name package))))
