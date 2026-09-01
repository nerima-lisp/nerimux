(in-package #:nerimux)

(defun %select-client-tree-relative (conn delta)
  (let* ((objects (%workspace-tree-objects
                   (nerimux/vcs:workspace-organizations)
                   (client-conn-tree-filter conn)))
         (count (length objects)))
    (when (plusp count)
      (let* ((current (%client-tree-object conn))
             (index (or (and current
                             (position current objects :test #'equal))
                        (if (minusp delta) 0 -1)))
             (next (max 0 (min (1- count) (+ index delta))))
             (visible (max 1 (nerimux/renderer:workspace-tree-view-rows
                              (client-conn-rows conn)))))
        (%set-client-selected-tree-object conn (nth next objects))
        (when (< next (client-conn-tree-scroll conn))
          (setf (client-conn-tree-scroll conn) next))
        (when (>= next (+ (client-conn-tree-scroll conn) visible))
          (setf (client-conn-tree-scroll conn)
                (max 0 (+ next 1 (- visible)))))
        (%mark-dirty)
        (nth next objects)))))
