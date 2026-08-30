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
