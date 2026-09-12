(in-package #:nerimux)

(defun %transient-branch (conn)
  (let ((worktree (%client-operation-worktree conn)))
    (and worktree (nerimux/workspace-model:worktree-head worktree))))

(defun %transient-upstream (conn)
  (let ((worktree (%client-operation-worktree conn)))
    (and worktree (nerimux/vcs:worktree-upstream worktree))))

(defun %transient-subtitle (key conn)
  "The line under a transient's title. Push and Fetch read <branch> → its
   real upstream, Pull reads the other way, and a branch that tracks nothing
   says so: the old subtitle named origin/<branch> for every repository,
   including ones with no remote at all, which invited a push to a
   destination that does not exist."
  (let ((branch (%transient-branch conn)))
    (when branch
      (if (member key '(#\P #\F #\f))
          (let ((upstream (%transient-upstream conn)))
            (cond
              ((null upstream) "no upstream")
              ((eql key #\F) (format nil "~A → ~A" upstream branch))
              (t (format nil "~A → ~A" branch upstream))))
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
