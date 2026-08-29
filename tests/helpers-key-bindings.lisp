;;;; Key translation and binding assertion helpers for nerimux tests.

(in-package #:nerimux/test)

(defun alist-value (key alist &key (test #'eql))
  "Return the value bound to KEY in ALIST."
  (cdr (assoc key alist :test test)))
