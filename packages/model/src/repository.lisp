(in-package #:nerimux/workspace-model)

(defstruct 
    (repository
     (:constructor %make-repository
                   (&key id
                         organization
                         specification
                         remote
                         local-path
                         backend
                         worktrees
                         main-worktree
                         dirty-p
                         conflict-p
                         ahead
                         behind
                         missing-p)))
  (id "" :type string)
  (organization nil)
  (specification "" :type string)
  (remote nil)
  (local-path "" :type string)
  (backend :git)
  (worktrees nil :type list)
  (main-worktree nil)
  (dirty-p nil :type boolean)
  (conflict-p nil :type boolean)
  (ahead 0 :type integer)
  (behind 0 :type integer)
  (missing-p nil :type boolean))

(defun repository-key (specification local-path)
  (let ((specification-string (%model-string specification))
        (path-string (%model-string local-path)))
    (if (plusp (length specification-string))
        specification-string
        path-string)))

(defun make-repository (&key id
                             organization
                             specification
                             remote
                             local-path
                             (backend :git)
                             worktrees
                             main-worktree
                             dirty-p
                             conflict-p
                             (ahead 0)
                             (behind 0)
                             missing-p)
  (let* ((specification-string (%model-string specification))
         (path-string (%model-string local-path)))
    (%make-repository :id
                      (or id (repository-key specification-string path-string))
                      :organization
                      organization
                      :specification
                      specification-string
                      :remote
                      remote
                      :local-path
                      path-string
                      :backend
                      backend
                      :worktrees
                      (copy-list worktrees)
                      :main-worktree
                      main-worktree
                      :dirty-p
                      (not (null dirty-p))
                      :conflict-p
                      (not (null conflict-p))
                      :ahead
                      ahead
                      :behind
                      behind
                      :missing-p
                      (not (null missing-p)))))

(defun repository-path (repository)
  (repository-local-path repository))
