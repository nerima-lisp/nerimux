(in-package #:nerimux/vcs)

(defvar *directory-resolve-timeout*
  2.0d0)

(defun %make-directory-vcs-repository (directory)
  (vcs-kit:make-vcs-repository directory
                               :default-timeout
                               *directory-resolve-timeout*))

(defun %path-missing-p (path)
  (and (stringp path) (plusp (length path)) (null (probe-file path))))

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

(defun %directory-repository-root (directory)
  (let ((worktrees
         (vcs-kit:vcs-list-worktrees (%make-directory-vcs-repository directory))))
    (when worktrees
      (let* ((bare (find-if #'vcs-kit:vcs-worktree-bare-p worktrees))
             (containing
               (find-if
                (lambda (worktree)
                  (let ((path (vcs-kit:vcs-worktree-path worktree)))
                    (and (stringp directory)
                         (stringp path)
                         (or (string= path directory)
                             (%directory-under-p path directory)))))
                worktrees)))
        (values (vcs-kit:vcs-worktree-path
                 (or bare containing (first worktrees)))
                worktrees)))))

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
(defun %canonicalize-bare-repository-entry (entry)
  "Return ENTRY normalized to a bare root and its raw worktree rows."
  (let* ((path (%string-value (vcs-kit:ghq-repository-entry-path entry)))
         (backend (vcs-kit:ghq-repository-entry-backend entry)))
    (if (and (stringp path)
             (plusp (length path))
             (eq (or backend :git) :git))
        (handler-case
            (multiple-value-bind (root worktrees)
                (%directory-repository-root path)
              (if (find-if
                   (function vcs-kit:vcs-worktree-bare-p)
                   worktrees)
                  (values
                   (vcs-kit:make-ghq-repository-entry
                    :specification (%directory-specification root)
                    :path root
                    :backend :git)
                   worktrees)
                (values entry worktrees)))
          (error ()
                 (values entry nil)))
      (values entry nil))))

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
