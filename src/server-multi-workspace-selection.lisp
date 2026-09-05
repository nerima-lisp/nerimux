(in-package #:nerimux)

(defun %picker-item-worktree (item)
  (or (nerimux/picker:picker-item-worktree item)
      (let ((repository (nerimux/picker:picker-item-repository item)))
        (or
         (and repository
              (or (nerimux/workspace-model:repository-main-worktree repository)
                  (first
                   (nerimux/workspace-model:repository-worktrees repository))))
         (let ((organization (nerimux/picker:picker-item-organization item)))
           (when organization
             (loop for repository in (nerimux/workspace-model:organization-repositories
                                      organization)
                   for worktree = (or
                                   (nerimux/workspace-model:repository-main-worktree
                                    repository)
                                   (first
                                    (nerimux/workspace-model:repository-worktrees
                                     repository)))
                   when worktree
                     return worktree)))))))

(defun %workspace-worktrees (&optional
                             (organizations
                              (nerimux/vcs:workspace-organizations)))
  "Return the catalog worktrees in stable organization/repository order."
  (loop for organization in organizations
        append (loop for repository in (nerimux/workspace-model:organization-repositories
                                        organization)
                     append (copy-list
                             (nerimux/workspace-model:repository-worktrees
                              repository)))))

(defun %workspace-tree-objects (&optional
                                (organizations
                                 (nerimux/vcs:workspace-organizations))
                                filter
                                (file-diffs (%workspace-file-diffs)))
  "Return the selectable tree rows in display order.

   FILTER and FILE-DIFFS must match the corresponding render pass so
   navigation and selection follow the visible rows."
  (nerimux/renderer:workspace-tree-objects organizations
                                           (%workspace-collapsed-nodes)
                                           :filter
                                           filter
                                           :expanded-node-ids
                                           (%workspace-expanded-nodes)
                                           :file-diffs
                                           file-diffs))

(defun %workspace-worktree-matches-token-p (worktree token)
  (or (eq worktree token)
      (and (stringp token)
           (or (string= token (nerimux/workspace-model:worktree-id worktree))
               (string= token (nerimux/workspace-model:worktree-path worktree))
               (and (nerimux/workspace-model:worktree-branch worktree)
                    (string= token
                             (princ-to-string
                              (nerimux/workspace-model:worktree-branch worktree))))))))

(defun %workspace-find-worktree (token &optional
                                       (organizations
                                        (nerimux/vcs:workspace-organizations)))
  (when token
    (find-if
     (lambda (worktree)
       (%workspace-worktree-matches-token-p worktree token))
     (%workspace-worktrees organizations))))

(defun %workspace-directory-prefix-p (directory path)
  (and (stringp directory)
       (string/= directory "")
       (stringp path)
       (let ((prefix
              (if (char= (char directory (1- (length directory))) #\/)
                  directory
                  (concatenate 'string directory "/"))))
         (or (string= directory path)
             (and (>= (length path) (length prefix))
                  (string= prefix path :end2 (length prefix)))))))

(defun %workspace-find-worktree-for-attach (token organizations)
  "Resolve an explicit attach selector TOKEN to a worktree.

   A directory selector matches a worktree below that directory."
  (or (%workspace-find-worktree token organizations)
      (find-if
       (lambda (worktree)
         (%workspace-directory-prefix-p token
                                        (nerimux/workspace-model:worktree-path
                                         worktree)))
       (%workspace-worktrees organizations))))

(defun %workspace-find-worktree-for-cwd (cwd organizations)
  "Resolve CWD to the deepest worktree containing it."
  (or (%workspace-find-worktree cwd organizations)
      (let ((best nil))
        (dolist (worktree (%workspace-worktrees organizations))
          (let ((path (nerimux/workspace-model:worktree-path worktree)))
            (when 
                (and (%workspace-directory-prefix-p path cwd)
                     (or (null best)
                         (> (length path)
                            (length
                             (nerimux/workspace-model:worktree-path best)))))
              (setf best worktree))))
        best)))

(defun %workspace-find-repository-for-attach (token organizations)
  "The repository TOKEN names, by specification, local path, or id (R7.6).

   `nerimux attach github.com/org/repo` is a repository selector, and until this
   existed the attach path matched only against worktrees — so a repository
   spec resolved to nothing and reported \"attach target not found\" for
   something the workspace was holding."
  (when (and (stringp token) (plusp (length token)))
    (loop for organization in organizations
          thereis (find-if
                   (lambda (repository)
                     (some
                      (lambda (field)
                        (and (stringp field) (string= field token)))
                      (list
                       (nerimux/workspace-model:repository-specification
                        repository)
                       (nerimux/workspace-model:repository-local-path
                        repository)
                       (nerimux/workspace-model:repository-id repository))))
                   (nerimux/workspace-model:organization-repositories
                    organization)))))
