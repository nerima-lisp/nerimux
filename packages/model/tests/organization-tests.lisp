(in-package #:nerimux/test/model)

(describe "organization-values"
          (it "normalizes model identifiers from supported value types"
              (let ((organization
                     (nerimux/workspace-model:make-organization :host
                                                                #p"github.com/"
                                                                :name
                                                                42
                                                                :repositories
                                                                '(:repository))))
                (expect
                 (equal "github.com//42"
                        (nerimux/workspace-model:organization-id organization)))
                (expect
                 (equal "github.com/"
                        (nerimux/workspace-model:organization-host organization)))
                (expect
                 (equal "42"
                        (nerimux/workspace-model:organization-name organization)))
                (expect
                 (equal '(:repository)
                        (nerimux/workspace-model:organization-repositories
                         organization)))))
          (it "uses local and default keys for absent values"
              (expect
               (equal "local/default"
                      (nerimux/workspace-model:organization-key nil nil)))
              (expect
               (equal "local/default"
                      (nerimux/workspace-model:organization-key "" ""))))
          (it "formats non-string key values"
              (expect
               (equal "git.example/42"
                      (nerimux/workspace-model:organization-key #p"git.example"
                                                                42))))
          (it "retains defaults when optional values are omitted"
              (let ((organization (nerimux/workspace-model:make-organization)))
                (expect
                 (equal "local/default"
                        (nerimux/workspace-model:organization-id organization)))
                (expect
                 (null
                  (nerimux/workspace-model:organization-repositories
                   organization)))
                (expect
                 (= 0
                    (nerimux/workspace-model:organization-active-worktree-count
                     organization)))
                (expect
                 (= 0
                    (nerimux/workspace-model:organization-attention-count
                     organization)))
                (expect
                 (not
                  (nerimux/workspace-model:organization-missing-p organization)))))
          (it "keeps raw constructor defaults explicit"
              (let ((organization (nerimux/workspace-model::%make-organization)))
                (expect
                 (equal ""
                        (nerimux/workspace-model:organization-id organization)))
                (expect
                 (equal ""
                        (nerimux/workspace-model:organization-host organization)))
                (expect
                 (equal ""
                        (nerimux/workspace-model:organization-name organization)))
                (expect
                 (null
                  (nerimux/workspace-model:organization-repositories
                   organization)))
                (expect
                 (= 0
                    (nerimux/workspace-model:organization-active-worktree-count
                     organization)))
                (expect
                 (= 0
                    (nerimux/workspace-model:organization-attention-count
                     organization)))
                (expect
                 (null
                  (nerimux/workspace-model:organization-missing-p organization)))
                (expect
                 (null
                  (nerimux/workspace-model::organization-counts-derived-p
                   organization))))))

(describe "organization-hierarchy"
          (it "links repositories and counts worktree attention"
              (let* ((organization
                      (nerimux/workspace-model:make-organization :host
                                                                 "github.com"
                                                                 :name
                                                                 "nerima-lisp"))
                     (repository
                      (nerimux/workspace-model:make-repository :specification
                                                               "nerima-lisp/nerimux"
                                                               :local-path
                                                               "/work/nerimux"))
                     (dirty-worktree
                      (nerimux/workspace-model:make-worktree :path
                                                             "/work/nerimux"
                                                             :branch
                                                             "main"
                                                             :head
                                                             "abc"
                                                             :dirty-p
                                                             t
                                                             :conflict-p
                                                             t
                                                             :ahead
                                                             2
                                                             :behind
                                                             1))
                     (missing-worktree
                      (nerimux/workspace-model:make-worktree :path
                                                             "/work/nerimux-old"
                                                             :missing-p
                                                             t)))
                (nerimux/workspace-model:organization-add-repository
                 organization
                 repository)
                (nerimux/workspace-model:repository-add-worktree repository
                                                                 dirty-worktree)
                (nerimux/workspace-model:repository-add-worktree repository
                                                                 missing-worktree)
                (expect
                 (eq organization
                     (nerimux/workspace-model:repository-organization
                      repository)))
                (expect
                 (eq repository
                     (nerimux/workspace-model:worktree-repository
                      dirty-worktree)))
                (expect
                 (eq dirty-worktree
                     (nerimux/workspace-model:repository-worktree-by-path
                      repository
                      "/work/nerimux")))
                (expect (nerimux/workspace-model:repository-dirty-p repository))
                (expect
                 (nerimux/workspace-model:repository-conflict-p repository))
                (expect
                 (= 2 (nerimux/workspace-model:repository-ahead repository)))
                (expect
                 (= 1 (nerimux/workspace-model:repository-behind repository)))
                (expect
                 (= 1
                    (nerimux/workspace-model:organization-active-worktree-count
                     organization)))
                (expect
                 (= 2
                    (nerimux/workspace-model:organization-attention-count
                     organization)))
                (expect
                 (nerimux/workspace-model:worktree-attention-p dirty-worktree))
                (expect
                 (nerimux/workspace-model:worktree-attention-p missing-worktree)))))
