(in-package #:nerimux/test)

(defun %make-server-dispatch-helper-fixture ()
  (let* ((organization
          (nerimux/workspace-model:make-organization :id
                                                     "org-id"
                                                     :host
                                                     "origin"
                                                     :name
                                                     "team"))
         (repository
          (nerimux/workspace-model:make-repository :id
                                                   "repo-id"
                                                   :organization
                                                   organization
                                                   :specification
                                                   "origin/team/repo"
                                                   :local-path
                                                   "/workspace/repo"))
         (main-worktree
          (nerimux/workspace-model:make-worktree :id
                                                 "main-id"
                                                 :repository
                                                 repository
                                                 :path
                                                 "/workspace/repo"
                                                 :branch
                                                 "main"))
         (feature-worktree
          (nerimux/workspace-model:make-worktree :id
                                                 "feature-id"
                                                 :repository
                                                 repository
                                                 :path
                                                 "/workspace/repo/feature"
                                                 :branch
                                                 "feature")))
    (nerimux/workspace-model:organization-add-repository organization
                                                         repository)
    (nerimux/workspace-model:repository-add-worktree repository main-worktree)
    (nerimux/workspace-model:repository-add-worktree repository
                                                     feature-worktree)
    (values (list organization)
            organization
            repository
            main-worktree
            feature-worktree)))

(defmacro with-server-dispatch-helper-fixture ((organizations organization
                                                repository main-worktree
                                                feature-worktree)
                                               &body body)
  `(multiple-value-bind (,organizations ,organization ,repository
                        ,main-worktree ,feature-worktree)
       (%make-server-dispatch-helper-fixture)
     ,@body))
