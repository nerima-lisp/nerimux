(in-package #:nerimux/picker)

(in-package #:nerimux/picker)

(defstruct 
    (picker-item
     (:constructor %make-picker-item
                   (&key id kind label organization repository worktree pane)))
  id
  kind
  label
  organization
  repository
  worktree
  pane)

(defun %picker-string (value)
  (cond
    ((null value) "")
    ((stringp value) value)
    ((pathnamep value) (namestring value))
    (t (princ-to-string value))))

(defun %first-picker-string (&rest values)
  (loop for value in values
        for string = (%picker-string value)
        when (plusp (length string))
          do (return string)
        finally (return "")))

(defun %organization-label (organization)
  (let ((host
         (%picker-string
          (nerimux/workspace-model:organization-host organization)))
        (name
         (%picker-string
          (nerimux/workspace-model:organization-name organization))))
    (cond
      ((and (plusp (length host)) (plusp (length name)))
       (format nil "~A/~A" host name))
      ((plusp (length host)) host)
      ((plusp (length name)) name)
      (t
       (%picker-string (nerimux/workspace-model:organization-id organization))))))

(defun %repository-label (repository)
  (%first-picker-string
   (nerimux/workspace-model:repository-specification repository)
   (nerimux/workspace-model:repository-local-path repository)
   (nerimux/workspace-model:repository-id repository)))

(defun %worktree-label (worktree)
  (let ((branch
         (%picker-string (nerimux/workspace-model:worktree-branch worktree)))
        (path (%picker-string (nerimux/workspace-model:worktree-path worktree))))
    (cond
      ((and (plusp (length branch)) (plusp (length path)))
       (format nil "~A — ~A" branch path))
      ((plusp (length branch)) branch)
      ((plusp (length path)) path)
      (t (%picker-string (nerimux/workspace-model:worktree-id worktree))))))

(defun %organization-id (organization)
  (format nil
          "organization/~A"
          (%first-picker-string
           (nerimux/workspace-model:organization-id organization)
           (%organization-label organization))))

(defun %repository-id (organization repository)
  (format nil
          "~A/repository/~A"
          (%organization-id organization)
          (%first-picker-string
           (nerimux/workspace-model:repository-id repository)
           (%repository-label repository))))

(defun %worktree-id (organization repository worktree)
  (format nil
          "~A/worktree/~A"
          (%repository-id organization repository)
          (%first-picker-string (nerimux/workspace-model:worktree-id worktree)
                                (%worktree-label worktree))))

(defun %pane-label (pane)
  (format nil
          "pane/~D ~A"
          (nerimux/pane:pane-id pane)
          (%first-picker-string (nerimux/pane:pane-title pane)
                                (nerimux/pane:pane-start-command pane)
                                "shell")))

(defun %pane-id (organization repository worktree pane)
  (format nil
          "~A/pane/~D"
          (%worktree-id organization repository worktree)
          (nerimux/pane:pane-id pane)))

(defun %make-organization-item (organization)
  (%make-picker-item :id
                     (%organization-id organization)
                     :kind
                     :organization
                     :label
                     (%organization-label organization)
                     :organization
                     organization))

(defun %make-repository-item (organization repository)
  (%make-picker-item :id
                     (%repository-id organization repository)
                     :kind
                     :repository
                     :label
                     (%repository-label repository)
                     :organization
                     organization
                     :repository
                     repository))

(defun %make-worktree-item (organization repository worktree)
  (%make-picker-item :id
                     (%worktree-id organization repository worktree)
                     :kind
                     :worktree
                     :label
                     (%worktree-label worktree)
                     :organization
                     organization
                     :repository
                     repository
                     :worktree
                     worktree))

(defun %make-pane-item (organization repository worktree pane)
  (%make-picker-item :id
                     (%pane-id organization repository worktree pane)
                     :kind
                     :pane
                     :label
                     (%pane-label pane)
                     :organization
                     organization
                     :repository
                     repository
                     :worktree
                     worktree
                     :pane
                     pane))

(defun build-global-picker-items (organizations)
  (check-type organizations list)
  (let ((items nil))
    (dolist (organization (reverse organizations) items)
      (dolist 
          (repository
           (reverse
            (nerimux/workspace-model:organization-repositories organization)))
        (dolist 
            (worktree
             (reverse (nerimux/workspace-model:repository-worktrees repository)))
          (dolist 
              (pane (reverse (nerimux/workspace-model:worktree-panes worktree)))
            (push (%make-pane-item organization repository worktree pane) items))
          (push (%make-worktree-item organization repository worktree) items))
        (push (%make-repository-item organization repository) items))
      (push (%make-organization-item organization) items))))

(defun %repository-attention-p (repository)
  (or (nerimux/workspace-model:repository-dirty-p repository)
      (nerimux/workspace-model:repository-conflict-p repository)
      (plusp (nerimux/workspace-model:repository-ahead repository))
      (plusp (nerimux/workspace-model:repository-behind repository))
      (nerimux/workspace-model:repository-missing-p repository)
      (some #'nerimux/workspace-model:worktree-attention-p
            (nerimux/workspace-model:repository-worktrees repository))))

(defun picker-item-attention-p (item)
  (check-type item picker-item)
  (case (picker-item-kind item)
    (:organization
     (or
      (nerimux/workspace-model:organization-missing-p
       (picker-item-organization item))
      (plusp
       (nerimux/workspace-model:organization-attention-count
        (picker-item-organization item)))
      (some #'%repository-attention-p
            (nerimux/workspace-model:organization-repositories
             (picker-item-organization item)))))
    (:repository (%repository-attention-p (picker-item-repository item)))
    (:worktree
     (nerimux/workspace-model:worktree-attention-p (picker-item-worktree item)))
    (:pane (nerimux/pane:pane-attention-p (picker-item-pane item)))
    (otherwise nil)))

