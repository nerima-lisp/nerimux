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
                     (nerimux/workspace-model:make-organization :host
                                                                "github.com"
                                                                :name
                                                                "team"))
                    (repository
                     (nerimux/workspace-model:make-repository :specification
                                                              "github.com/team/repo"))
                    (worktree
                     (nerimux/workspace-model:make-worktree :path
                                                            "/tmp/worktree"))
                    (branch-worktree
                     (nerimux/workspace-model:make-worktree :branch "feature")))
                (expect
                 (equal "github.com/team"
                        (nerimux::%organization-selection-token organization)))
                (expect
                 (equal "github.com/team/repo"
                        (nerimux::%repository-selection-token repository)))
                (expect
                 (equal "/tmp/worktree||"
                        (nerimux::%worktree-selection-token worktree)))
                (expect
                 (equal "|feature|"
                        (nerimux::%worktree-selection-token branch-worktree)))
                (expect
                 (equal '(:organization "github.com/team")
                        (nerimux::%tree-object-selection-token organization)))
                (expect (null (nerimux::%tree-object-selection-token nil)))))
          (it
           "uses the first stable identity available for every selectable model"
           (let ((cases
                  (list
                   (list
                    (nerimux/workspace-model:make-worktree :id
                                                           "wt-id"
                                                           :path
                                                           "/ignored")
                    '(:worktree "wt-id"))
                   (list
                    (nerimux/workspace-model:make-organization :id
                                                               "org-id"
                                                               :host
                                                               "ignored"
                                                               :name
                                                               "ignored")
                    '(:organization "org-id"))
                   (list
                    (nerimux/workspace-model:make-repository :id
                                                             "repo-id"
                                                             :specification
                                                             "ignored")
                    '(:repository "repo-id"))
                   (list
                    (nerimux/workspace-model:make-repository :local-path
                                                             "/local")
                    '(:repository "/local"))
                   (list '(:file "worktree-id" "README.md")
                         '(:worktree "worktree-id"))
                   (list '(:commit "worktree-id" "abc123")
                         '(:worktree "worktree-id"))
                   (list '(:diff-line "worktree-id") '(:worktree "worktree-id"))
                   (list :active '(:section :active)))))
             (dolist 
                 (case cases)
               (let ((object (first case))
                     (expected (second case)))
                 (expect
                  (equal expected
                         (nerimux::%tree-object-selection-token object)))))))
          (it "uses a repository local path as its direct fallback token"
              (let ((repository
                     (nerimux/workspace-model:make-repository :local-path
                                                              "/local/repository")))
                (expect
                 (equal "/local/repository"
                        (nerimux::%repository-selection-token repository)))))
          (it "normalizes row, pane, and empty identity tokens"
              (let* ((worktree
                      (nerimux/workspace-model:make-worktree :id "wt-id"))
                     (pane (nerimux/pane:make-pane :id 1 :worktree worktree)))
                (expect
                 (equal '(:worktree "wt-id")
                        (nerimux::%tree-object-selection-token pane)))
                (expect
                 (equal '(:section :attention)
                        (nerimux::%tree-object-selection-token :attention)))
                (expect
                 (equal '(:worktree "row-wt")
                        (nerimux::%tree-object-selection-token
                         '(:diff-more "row-wt" "file"))))
                (expect
                 (null (nerimux::%tree-object-selection-token '(row "value"))))
                (expect
                 (equal '(:repository nil)
                        (nerimux::%tree-object-selection-token
                         (nerimux/workspace-model:make-repository))))
                (let ((conn (nerimux::%make-client-conn)))
                  (setf (nerimux::client-conn-focus conn) pane)
                  (expect (eq worktree (nerimux::%client-tree-object conn)))
                  (expect
                   (equal '(:worktree "wt-id")
                          (nerimux::%client-tree-selection-token conn)))
                  (expect
                   (equal "wt-id" (nerimux::%client-selection-token conn)))))))
