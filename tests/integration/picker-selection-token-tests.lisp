(in-package #:nerimux/test)

;;;; Selection tokens the picker derives from model objects.
;;;;
;;;; Moved out of packages/picker/tests/global-picker-tests.lisp when
;;;; application/picker became nerimux-picker. The token functions are BOOTSTRAP
;;;; internals (src/server-multi-dispatch-picker.lisp), not picker ones, so this
;;;; case never belonged to the unit -- it pins that the two agree.

(describe "picker-selection-token-suite"


  (it "derives stable selection tokens from fallback model fields"
    (let ((organization
            (nerimux/workspace-model:make-organization
             :host "github.com"
             :name "team"))
          (repository
            (nerimux/workspace-model:make-repository
             :specification "github.com/team/repo"))
          (worktree
            (nerimux/workspace-model:make-worktree
             :path "/tmp/worktree"))
          (branch-worktree
            (nerimux/workspace-model:make-worktree :branch "feature")))
      (expect (equal "github.com/team"
                     (nerimux::%organization-selection-token organization)))
      (expect (equal "github.com/team/repo"
                     (nerimux::%repository-selection-token repository)))
      (expect (equal "/tmp/worktree||"
                     (nerimux::%worktree-selection-token worktree)))
      (expect (equal "|feature|"
                     (nerimux::%worktree-selection-token branch-worktree)))
      (expect (equal '(:organization "github.com/team")
                     (nerimux::%tree-object-selection-token organization)))
      (expect (null (nerimux::%tree-object-selection-token nil))))))

  (it "uses the first stable identity available for every selectable model"
    (let ((cases
            (list
             (list (nerimux/workspace-model:make-worktree :id "wt-id"
                                                           :path "/ignored")
                   '(:worktree "wt-id"))
             (list (nerimux/workspace-model:make-organization :id "org-id"
                                                               :host "ignored"
                                                               :name "ignored")
                   '(:organization "org-id"))
             (list (nerimux/workspace-model:make-repository :id "repo-id"
                                                             :specification "ignored")
                   '(:repository "repo-id"))
             (list (nerimux/workspace-model:make-repository :local-path "/local")
                   '(:repository "/local"))
             (list '(:diff-line "worktree-id")
                   '(:worktree "worktree-id"))
             (list :active '(:section :active)))))
      (dolist (case cases)
        (let ((object (first case))
              (expected (second case)))
          (expect (equal expected
                         (nerimux::%tree-object-selection-token object)))))))
