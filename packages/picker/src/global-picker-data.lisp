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

(defun %repository-display-label (repository)
  "`org/repo' as the workspace tree writes it, so a picker row and a tree row
   name the same repository the same way."
  (nerimux/text:strip-dot-git-suffix (%repository-label repository)))

(defun %path-final-segment (path)
  (let* ((string (string-right-trim "/" (%picker-string path)))
         (slash (position #\/ string :from-end t)))
    (if slash
        (subseq string (1+ slash))
        string)))

(defun %worktree-display-label (repository worktree)
  "`org/repo · branch' for a picker worktree row.  A worktree with no branch
   falls back to what tells it apart from its siblings: its directory name."
  (let ((repository-name (and repository (%repository-display-label repository)))
        (branch (%picker-string (nerimux/workspace-model:worktree-branch worktree))))
    (let ((tail
           (cond
             ((plusp (length branch)) branch)
             (t (%path-final-segment
                 (nerimux/workspace-model:worktree-path worktree))))))
      (cond
        ((and repository-name (plusp (length repository-name)) (plusp (length tail)))
         (format nil "~A · ~A" repository-name tail))
        ((plusp (length tail)) tail)
        (t (%worktree-label worktree))))))

(defun %picker-item-kind-prefix (item)
  (case (picker-item-kind item)
    (:organization "org ")
    (:repository "repo")
    (:worktree "  wt ")
    (:pane "pane")
    (otherwise "     ")))

(defun picker-item-row-text (item)
  "The row text the picker paints for ITEM.  Regex mode matches against this
   rather than against the hidden field index, so `^' and `$' bind to what the
   user can see.  Exported because the renderer draws the row from this, not
   from a second copy of the format that could drift out of step with it."
  (format nil "~A ~:[ ~;!~] ~A"
          (%picker-item-kind-prefix item)
          (picker-item-attention-p item)
          (picker-item-label item)))

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

(defun %pane-display-label (repository worktree pane)
  "`org/repo · branch — what the pane is running', so a pane row says which
   worktree it belongs to without the user opening it."
  (format nil "~A — ~A"
          (%worktree-display-label repository worktree)
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
                     (%repository-display-label repository)
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
                     (%worktree-display-label repository worktree)
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
                     (%pane-display-label repository worktree pane)
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
      (some #'nerimux/pane:repository-attention-p
            (nerimux/workspace-model:organization-repositories
             (picker-item-organization item)))))
    (:repository (nerimux/pane:repository-attention-p (picker-item-repository item)))
    (:worktree
     (nerimux/workspace-model:worktree-attention-p (picker-item-worktree item)))
    (:pane (nerimux/pane:pane-attention-p (picker-item-pane item)))
    (otherwise nil)))
