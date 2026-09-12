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
      (%workspace-find-tree-object (%client-selection-token conn))))

(defun %client-row-worktree (object)
  "The worktree a selected row belongs to when the row is not a worktree
   itself: a pane knows its own, and every file, diff, commit and stash row
   carries its worktree id as its second element."
  (typecase object
    (nerimux/pane:pane (nerimux/pane:pane-worktree object))
    (cons
     (and (keywordp (first object))
          (stringp (second object))
          (%workspace-find-worktree (second object))))))

(defun %client-context-worktree (conn)
  "The worktree CONN's current view acts on, whatever row is selected inside
   it. The status view is built around SELECTED-WORKTREE and keeps it while
   the selection moves over that worktree's own file, stash and commit rows,
   so a row that is not itself a worktree still has one behind it."
  (let ((object (%client-tree-object conn)))
    (if (typep object 'nerimux/workspace-model:worktree)
        object
        (or (%client-row-worktree object)
            (client-conn-selected-worktree conn)))))

(defun %client-selected-repository (conn &optional target)
  (let ((object (%client-context-object conn target)))
    (typecase object
      (nerimux/workspace-model:repository object)
      (nerimux/workspace-model:worktree
       (nerimux/workspace-model:worktree-repository object))
      (nerimux/workspace-model:organization
       (let ((repositories
               (nerimux/workspace-model:organization-repositories object)))
         (and (= (length repositories) 1) (first repositories))))
      (t
       (let ((worktree (%client-context-worktree conn)))
         (and worktree
              (nerimux/workspace-model:worktree-repository worktree)))))))

(defun %client-selected-organization (conn &optional target)
  (let ((object (%client-context-object conn target)))
    (typecase object
      (nerimux/workspace-model:organization object)
      (nerimux/workspace-model:repository
       (nerimux/workspace-model:repository-organization object))
      (nerimux/workspace-model:worktree
       (let ((repository (nerimux/workspace-model:worktree-repository object)))
         (and repository
              (nerimux/workspace-model:repository-organization repository))))
      (t
       (let* ((worktree (%client-context-worktree conn))
              (repository
                (and worktree
                     (nerimux/workspace-model:worktree-repository worktree))))
         (and repository
              (nerimux/workspace-model:repository-organization repository)))))))

(defun %client-operation-worktree (conn &optional target)
  "The worktree an operation acts on: TARGET when it names one, otherwise
   the worktree behind CONN's current selection. A TARGET that names nothing
   answers NIL rather than the selection, so a mistyped -t cannot run a
   destructive command against a worktree the user never named."
  (if target
      (%workspace-find-worktree target)
      (%client-context-worktree conn)))

(defun %client-report-missing-target (conn target &optional
                                                  (finder
                                                   #'%workspace-find-tree-object))
  "True, having said so, when TARGET was given and FINDER resolves it to
   nothing. FINDER is the same lookup the command itself will use, so a
   worktree command rejects a spec that names only a repository instead of
   running against whatever is selected."
  (and target
       (null (funcall finder target))
       (progn
         (%client-notify conn (format nil "target not found: ~A" target))
         t)))
