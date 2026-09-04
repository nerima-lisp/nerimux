(in-package #:nerimux)

(defun %workspace-find-repository (token &optional
                                         (organizations
                                          (nerimux/vcs:workspace-organizations)))
  (when token
    (dolist (organization organizations)
      (dolist (repository
                (nerimux/workspace-model:organization-repositories organization))
        (when (or (eq repository token)
                  (and (stringp token)
                       (some (lambda (value)
                               (and value
                                    (string= token (princ-to-string value))))
                             (list
                              (nerimux/workspace-model:repository-id repository)
                              (nerimux/workspace-model:repository-specification
                               repository)
                              (nerimux/workspace-model:repository-local-path
                               repository)))))
          (return-from %workspace-find-repository repository))))))

(defun %workspace-find-organization (token &optional
                                           (organizations
                                            (nerimux/vcs:workspace-organizations)))
  (when token
    (find-if
     (lambda (organization)
       (or (eq organization token)
           (and (stringp token)
                (some (lambda (value)
                        (and value
                             (string= token (princ-to-string value))))
                      (list
                       (nerimux/workspace-model:organization-id organization)
                       (nerimux/workspace-model:organization-host organization)
                       (nerimux/workspace-model:organization-name organization)
                       (%organization-selection-token organization))))))
     organizations)))

(defun %workspace-find-tree-object (token &optional
                                          (organizations
                                           (nerimux/vcs:workspace-organizations)))
  (cond
    ((typep token 'nerimux/workspace-model:organization) token)
    ((typep token 'nerimux/workspace-model:repository) token)
    ((typep token 'nerimux/workspace-model:worktree) token)
    ((and (consp token) (keywordp (first token)))
     (case (first token)
       (:organization
        (%workspace-find-organization (second token) organizations))
       (:repository (%workspace-find-repository (second token) organizations))
       (:worktree (%workspace-find-worktree (second token) organizations))
       (:section (second token))))
    ((stringp token)
     (or (%workspace-find-worktree token organizations)
         (%workspace-find-repository token organizations)
         (%workspace-find-organization token organizations)))))

(defun %client-context-object (conn target)
  (or (%workspace-find-tree-object target)
      (%client-tree-object conn)
      (%workspace-find-tree-object (%client-selection-token conn))
      (and (client-conn-focus conn)
           (nerimux/pane:pane-worktree (client-conn-focus conn)))))

(defun %client-selected-repository (conn &optional target)
  (let ((object (%client-context-object conn target)))
    (typecase object
      (nerimux/workspace-model:repository object)
      (nerimux/workspace-model:worktree
       (nerimux/workspace-model:worktree-repository object))
      (nerimux/workspace-model:organization
       (let ((repositories
               (nerimux/workspace-model:organization-repositories object)))
         (and (= (length repositories) 1) (first repositories)))))))

(defun %client-selected-organization (conn &optional target)
  (let ((object (%client-context-object conn target)))
    (typecase object
      (nerimux/workspace-model:organization object)
      (nerimux/workspace-model:repository
       (nerimux/workspace-model:repository-organization object))
      (nerimux/workspace-model:worktree
       (let ((repository (nerimux/workspace-model:worktree-repository object)))
         (and repository
              (nerimux/workspace-model:repository-organization repository)))))))

(defun %client-operation-worktree (conn &optional target)
  (let ((selected (%client-tree-object conn))
        (focused (client-conn-focus conn)))
    (or (%workspace-find-worktree target)
        (and (typep selected 'nerimux/workspace-model:worktree) selected)
        (and focused (nerimux/pane:pane-worktree focused)))))
