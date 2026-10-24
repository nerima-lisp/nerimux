(in-package #:nerimux)

(defvar *client-meta-pending*
  (make-hash-table :test #'eq :weakness :key)
  "Pending escape-sequence state keyed by client connection.")

(defvar *client-meta-tree-filter-snapshots*
  (make-hash-table :test #'eq :weakness :key)
  "Retained tree filters cleared while resolving an Escape-prefixed key.")
