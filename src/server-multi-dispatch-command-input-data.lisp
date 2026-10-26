(in-package #:nerimux)

(defvar *client-meta-pending*
  (make-hash-table :test #'eq :weakness :key)
  "Pending escape-sequence state keyed by client connection.")

(defvar *client-meta-tree-filter-snapshots*
  (make-hash-table :test #'eq :weakness :key)
  "Retained tree filters cleared while resolving an Escape-prefixed key.")

(defvar *client-meta-prefix-deadlines*
  (make-hash-table :test #'eq :weakness :key)
  "Escape-prefix deadlines keyed by client connection.")

(defconstant +client-meta-prefix-timeout+
  (ceiling internal-time-units-per-second 4))
