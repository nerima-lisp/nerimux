(in-package #:nerimux/vcs)

(defvar *directory-resolve-timeout*
  2.0d0)

(defun %make-directory-vcs-repository (directory)
  (vcs-kit:make-vcs-repository directory
                               :default-timeout
                               *directory-resolve-timeout*))

(defun %path-missing-p (path)
  (and (stringp path) (plusp (length path)) (null (probe-file path))))

(defun %directory-repository-root (directory)
  (let ((worktrees
         (vcs-kit:vcs-list-worktrees (%make-directory-vcs-repository directory))))
    (when worktrees
      (let ((bare (find-if #'vcs-kit:vcs-worktree-bare-p worktrees)))
        (values (vcs-kit:vcs-worktree-path (or bare (first worktrees)))
                worktrees)))))

(defun %directory-under-p (root path)
  (and (stringp root)
       (plusp (length root))
       (stringp path)
       (plusp (length path))
       (let ((prefix
              (if (char= (char root (1- (length root))) #\/)
                  root
                  (concatenate 'string root "/"))))
         (and (>= (length path) (length prefix))
              (string= prefix path :end2 (length prefix))))))

(defun %directory-specification (repository-root)
  (let ((ghq-root (ghq-root-directory)))
    (if (and repository-root
             ghq-root
             (%directory-under-p ghq-root repository-root))
        (let ((prefix
               (if (char= (char ghq-root (1- (length ghq-root))) #\/)
                   ghq-root
                   (concatenate 'string ghq-root "/"))))
          (if (>= (length repository-root) (length prefix))
              (subseq repository-root (length prefix))
              ""))
        "local")))

(defun resolve-directory-organizations (directory)
  (handler-case (when (and (stringp directory) (plusp (length directory)))
                  (multiple-value-bind (repository-root raw-worktrees)
                      (%directory-repository-root directory)
                    (when (and repository-root (plusp (length repository-root)))
                      (let* ((specification
                              (%directory-specification repository-root))
                             (repository
                              (nerimux/workspace-model:make-repository
                               :specification
                               specification
                               :local-path
                               repository-root
                               :backend
                               :git)))
                        (multiple-value-bind (host name)
                            (%organization-and-name specification)
                          (let ((organization
                                 (nerimux/workspace-model:make-organization
                                  :id
                                  (nerimux/workspace-model:organization-key host name)
                                  :host host
                                  :name name)))
                            (nerimux/workspace-model:organization-add-repository
                             organization
                             repository)
                            (%apply-repository-worktrees repository
                                                         raw-worktrees
                                                         (%path-missing-p
                                                          repository-root))
                            (list organization)))))))
    (error ()
      nil)))
