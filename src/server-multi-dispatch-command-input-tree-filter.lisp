(in-package #:nerimux)

(defun %client-enter-tree-filter-mode (conn)
  (setf (client-conn-tree-filter conn) nil
        (client-conn-tree-scroll conn) 0)
  (%set-client-modal conn :filter)
  (%mark-dirty)
  t)
