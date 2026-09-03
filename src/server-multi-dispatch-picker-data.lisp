(in-package #:nerimux)

(defun %worktree-selection-token (worktree)
  (and worktree
       (or (and (plusp (length (nerimux/workspace-model:worktree-id worktree)))
                (nerimux/workspace-model:worktree-id worktree))
           (and (plusp (length (nerimux/workspace-model:worktree-path worktree)))
                (nerimux/workspace-model:worktree-path worktree))
           (and (nerimux/workspace-model:worktree-branch worktree)
                (princ-to-string (nerimux/workspace-model:worktree-branch worktree))))))

(defun %organization-selection-token (organization)
  (and organization
       (or (and (plusp (length (nerimux/workspace-model:organization-id organization)))
                (nerimux/workspace-model:organization-id organization))
           (and (plusp (length (nerimux/workspace-model:organization-host organization)))
                (plusp (length (nerimux/workspace-model:organization-name organization)))
                (format nil "~A/~A" (nerimux/workspace-model:organization-host organization)
                        (nerimux/workspace-model:organization-name organization))))))

(defun %repository-selection-token (repository)
  (and repository
       (or (and (plusp (length (nerimux/workspace-model:repository-id repository)))
                (nerimux/workspace-model:repository-id repository))
           (and (plusp (length (nerimux/workspace-model:repository-specification repository)))
                (nerimux/workspace-model:repository-specification repository))
           (and (plusp (length (nerimux/workspace-model:repository-local-path repository)))
                (nerimux/workspace-model:repository-local-path repository)))))

(defun %tree-object-selection-token (object)
  (typecase object
    (nerimux/workspace-model:organization (list :organization (%organization-selection-token object)))
    (nerimux/workspace-model:repository (list :repository (%repository-selection-token object)))
    (nerimux/workspace-model:worktree (list :worktree (%worktree-selection-token object)))
    (nerimux/pane:pane
     (let ((worktree (nerimux/pane:pane-worktree object)))
       (and worktree (list :worktree (%worktree-selection-token worktree)))))
    (t (cond ((and (consp object) (keywordp (first object))
                   (member (first object) '(:file :commit :diff-line :diff-more)))
              (list :worktree (second object)))
             ((keywordp object) (list :section object))))))
