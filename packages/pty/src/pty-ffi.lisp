(in-package #:nerimux/pty)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(defconstant +stdout-fd+
  1
  "Standard output.")
