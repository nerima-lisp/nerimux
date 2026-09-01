(in-package #:nerimux/test/model)

(describe "repository-status"
          (it "uses the main worktree for repository ahead and behind state"
              (let* ((repository
                      (nerimux/workspace-model:make-repository :specification
                                                               "nerima-lisp/nerimux"))
                     (main-worktree
                      (nerimux/workspace-model:make-worktree :path
                                                             "/work/nerimux"
                                                             :branch
                                                             "main"
                                                             :ahead
                                                             3
                                                             :behind
                                                             4))
                     (feature-worktree
                      (nerimux/workspace-model:make-worktree :path
                                                             "/work/nerimux-feature"
                                                             :branch
                                                             "feature"
                                                             :ahead
                                                             9
                                                             :behind
                                                             8)))
                (nerimux/workspace-model:repository-add-worktree repository
                                                                 main-worktree)
                (nerimux/workspace-model:repository-add-worktree repository
                                                                 feature-worktree)
                (expect
                 (eq main-worktree
                     (nerimux/workspace-model:repository-main-worktree
                      repository)))
                (expect
                 (= 3 (nerimux/workspace-model:repository-ahead repository)))
                (expect
                 (= 4 (nerimux/workspace-model:repository-behind repository)))
                (expect
                 (equal "/work/nerimux-feature"
                        (nerimux/workspace-model:worktree-path
                         (nerimux/workspace-model:repository-worktree-by-path
                          repository
                          "/work/nerimux-feature")))))))

(describe "repository-values"
          (it "keeps the raw model constructor defaults available"
              (let ((repository (nerimux/workspace-model::%make-repository)))
                (expect
                 (equal "" (nerimux/workspace-model:repository-id repository)))
                (expect
                 (equal ""
                        (nerimux/workspace-model:repository-specification
                         repository)))
                (expect
                 (equal ""
                        (nerimux/workspace-model:repository-local-path
                         repository)))
                (expect
                 (eq :git
                     (nerimux/workspace-model:repository-backend repository)))
                (expect
                 (null
                  (nerimux/workspace-model:repository-worktrees repository)))
                (expect
                 (= 0 (nerimux/workspace-model:repository-ahead repository)))
                (expect
                 (= 0 (nerimux/workspace-model:repository-behind repository)))))
          (it "retains defaults when optional values are omitted"
              (let ((repository (nerimux/workspace-model:make-repository)))
                (expect
                 (equal "" (nerimux/workspace-model:repository-id repository)))
                (expect
                 (eq :git
                     (nerimux/workspace-model:repository-backend repository)))
                (expect
                 (null
                  (nerimux/workspace-model:repository-worktrees repository)))
                (expect
                 (null
                  (nerimux/workspace-model:repository-main-worktree repository)))
                (expect
                 (= 0 (nerimux/workspace-model:repository-ahead repository)))
                (expect
                 (= 0 (nerimux/workspace-model:repository-behind repository)))
                (expect
                 (not (nerimux/workspace-model:repository-dirty-p repository)))))
          (it "normalizes identifiers and copies worktree collections"
              (let ((worktrees
                     (list
                      (nerimux/workspace-model:make-worktree :path "/work/one"))))
                (let ((repository
                       (nerimux/workspace-model:make-repository :specification
                                                                "nerima-lisp/nerimux"
                                                                :local-path
                                                                #p"/work/nerimux"
                                                                :worktrees
                                                                worktrees)))
                  (expect
                   (equal "nerima-lisp/nerimux"
                          (nerimux/workspace-model:repository-id repository)))
                  (expect
                   (equal "nerima-lisp/nerimux"
                          (nerimux/workspace-model:repository-specification
                           repository)))
                  (expect
                   (equal "/work/nerimux"
                          (nerimux/workspace-model:repository-local-path
                           repository)))
                  (expect
                   (equal worktrees
                          (nerimux/workspace-model:repository-worktrees
                           repository)))
                  (expect
                   (not
                    (eq worktrees
                        (nerimux/workspace-model:repository-worktrees
                         repository)))))))
          (it "falls back to the local path when specification is absent"
              (let ((repository
                     (nerimux/workspace-model:make-repository :local-path
                                                              #p"/work/nerimux")))
                (expect
                 (equal "/work/nerimux"
                        (nerimux/workspace-model:repository-id repository)))
                (expect
                 (equal "/work/nerimux"
                        (nerimux/workspace-model:repository-local-path
                         repository))))))
