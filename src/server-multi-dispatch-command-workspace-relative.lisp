(in-package #:nerimux)

(defun %tree-selection-index (current objects delta)
  (cond
    ((and current (position current objects :test #'equal)))
    ((minusp delta) 0)
    (t -1)))

(defun %tree-selection-scroll (next scroll visible)
  (cond
    ((< next scroll) next)
    ((>= next (+ scroll visible))
     (max 0 (+ next 1 (- visible))))
    (t scroll)))

(defun %select-client-tree-relative (conn delta)
  (let* ((objects (%workspace-tree-objects
                   (nerimux/vcs:workspace-organizations)
                   (client-conn-tree-filter conn)))
         (count (length objects)))
    (when (plusp count)
      (let* ((current (%client-tree-object conn))
             (index (%tree-selection-index current objects delta))
             (next (max 0 (min (1- count) (+ index delta))))
             (visible (max 1 (nerimux/renderer:workspace-tree-view-rows
                              (client-conn-rows conn)))))
        (%set-client-selected-tree-object conn (nth next objects))
        (setf (client-conn-tree-scroll conn)
              (%tree-selection-scroll next
                                      (client-conn-tree-scroll conn)
                                      visible))
        (%mark-dirty)
        (nth next objects)))))
