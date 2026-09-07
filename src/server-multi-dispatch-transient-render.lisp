(in-package #:nerimux)

(defun %transient-branch (conn)
  (let ((worktree (%client-operation-worktree conn)))
    (and worktree (nerimux/workspace-model:worktree-head worktree))))

(defun %transient-subtitle (key conn)
  (let ((branch (%transient-branch conn)))
    (when branch
      (if (member key '(#\P #\F #\f))
          (format nil "~A -> origin/~A" branch branch)
          (format nil "on ~A" branch)))))

(defun %transient-action-display-description (conn description)
  (if (search "~A" description)
      (format nil description (or (%transient-branch conn) "?"))
      description))

(defun %transient-render-arguments (transient-key conn arguments)
  (let ((active (%client-transient-active-flags conn transient-key)))
    (mapcar
     (lambda (spec)
       (let ((flag (cdr spec)))
         (list (car spec)
               flag
               flag
               (and (member flag active :test #'string=) t)
               transient-key)))
     arguments)))

(defun %transient-render-actions (conn actions)
  (mapcar
   (lambda (entry)
     (list (first entry)
           (%transient-action-display-description conn (second entry))
           (third entry)))
   actions))
