(in-package #:nerimux/renderer)

(defun workspace-tree-view-rows (terminal-rows)
  "Rows available for the tree in the one-column overview layout."
  (max 1
       (- terminal-rows
          (if (< terminal-rows 12)
              6
              8))))
