(in-package #:nerimux)

(defvar *client-meta-pending*
  (make-hash-table :test #'eq :weakness :key)
  "Pending escape-sequence state keyed by client connection.")
