(in-package #:nerimux)

(declaim (special *workspace-expanded-node-ids* *workspace-file-diffs*))

(defun %tree-selection-index (current objects delta)
  (let ((selected (and current (position current objects :test #'equal))))
    (or selected (if (minusp delta) 0 -1))))

(defun %tree-selection-scroll (next scroll visible)
  (if (< next scroll)
      next
      (if (>= next (+ scroll visible))
          (max 0 (+ next 1 (- visible)))
          scroll)))

(defun %client-status-view-objects (conn)
  "The status view's own rows for CONN, in the order it draws them -- the
   same list RENDER-WORKSPACE-STATUS-TO-TUI-STRING builds, from the same
   expansion and visibility state."
  (let ((worktree (client-conn-selected-worktree conn)))
    (when worktree
      (nerimux/renderer:workspace-status-objects worktree
                                                 :expanded-node-ids
                                                 *workspace-expanded-node-ids*
                                                 :file-diffs
                                                 *workspace-file-diffs*
                                                 :visibility-level
                                                 (client-conn-visibility-level
                                                  conn)))))

(defun %select-client-status-relative (conn delta)
  "Move CONN's selection DELTA rows inside the status view's row list.
   SELECTED-TREE-OBJECT is written directly rather than through
   %SET-CLIENT-SELECTED-TREE-OBJECT: that helper clears SELECTED-WORKTREE
   for every object that is not a worktree, and SELECTED-WORKTREE is the one
   thing this whole view is rendered from -- clearing it dropped the client."
  (let* ((objects (%client-status-view-objects conn))
         (count (length objects)))
    (when (plusp count)
      (let* ((current (%client-tree-object conn))
             (index (%tree-selection-index current objects delta))
             (next (max 0 (min (1- count) (+ index delta))))
             (visible (max 1 (nerimux/renderer:workspace-status-view-rows
                              (client-conn-rows conn)))))
        (setf (client-conn-selected-tree-object conn) (nth next objects)
              (client-conn-tree-scroll conn)
              (%tree-selection-scroll next
                                      (client-conn-tree-scroll conn)
                                      visible))
        (%mark-dirty)
        (nth next objects)))))

(defun %select-client-tree-relative (conn delta)
  (if (eq (client-conn-view conn) :status)
      (%select-client-status-relative conn delta)
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
            (nth next objects))))))
