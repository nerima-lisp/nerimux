(in-package #:nerimux/test)

(describe "organization-values"
  (it "normalizes model identifiers from supported value types"
    (let ((organization (nerimux/model:make-organization
                         :host #p"github.com/"
                         :name 42
                         :repositories '(:repository))))
      (expect (equal "github.com//42"
                     (nerimux/model:organization-id organization)))
      (expect (equal "github.com/"
                     (nerimux/model:organization-host organization)))
      (expect (equal "42"
                     (nerimux/model:organization-name organization)))
      (expect (equal '(:repository)
                     (nerimux/model:organization-repositories organization)))))
  (it "uses local and default keys for absent values"
    (expect (equal "local/default"
                   (nerimux/model:organization-key nil nil)))
    (expect (equal "local/default"
                   (nerimux/model:organization-key "" ""))))
  (it "formats non-string key values"
    (expect (equal "git.example/42"
                   (nerimux/model:organization-key #p"git.example" 42))))
  (it "retains defaults when optional values are omitted"
    (let ((organization (nerimux/model:make-organization)))
      (expect (equal "local/default"
                     (nerimux/model:organization-id organization)))
      (expect (null (nerimux/model:organization-repositories organization)))
      (expect (= 0 (nerimux/model:organization-active-worktree-count organization)))
      (expect (= 0 (nerimux/model:organization-attention-count organization)))
      (expect (not (nerimux/model:organization-missing-p organization))))))
  (it "keeps raw constructor defaults explicit"
    (let ((organization (nerimux/model::%make-organization)))
      (expect (equal "" (nerimux/model:organization-id organization)))
      (expect (equal "" (nerimux/model:organization-host organization)))
      (expect (equal "" (nerimux/model:organization-name organization)))
      (expect (null (nerimux/model:organization-repositories organization)))
      (expect (= 0 (nerimux/model:organization-active-worktree-count organization)))
      (expect (= 0 (nerimux/model:organization-attention-count organization)))
      (expect (null (nerimux/model:organization-missing-p organization)))
      (expect (null (nerimux/model::organization-counts-derived-p organization)))))

(describe "organization-hierarchy"
  (it "links repositories and counts worktree attention"
    (let* ((organization (nerimux/model:make-organization
                          :host "github.com"
                          :name "nerima-lisp"))
           (repository (nerimux/model:make-repository
                        :specification "nerima-lisp/nerimux"
                        :local-path "/work/nerimux"))
           (dirty-worktree (nerimux/model:make-worktree
                            :path "/work/nerimux"
                            :branch "main"
                            :head "abc"
                            :dirty-p t
                            :conflict-p t
                            :ahead 2
                            :behind 1))
           (missing-worktree (nerimux/model:make-worktree
                              :path "/work/nerimux-old"
                              :missing-p t)))
      (nerimux/model:organization-add-repository organization repository)
      (nerimux/model:repository-add-worktree repository dirty-worktree)
      (nerimux/model:repository-add-worktree repository missing-worktree)
      (expect (eq organization (nerimux/model:repository-organization repository)))
      (expect (eq repository (nerimux/model:worktree-repository dirty-worktree)))
      (expect (eq dirty-worktree
                  (nerimux/model:repository-worktree-by-path repository "/work/nerimux")))
      (expect (nerimux/model:repository-dirty-p repository))
      (expect (nerimux/model:repository-conflict-p repository))
      (expect (= 2 (nerimux/model:repository-ahead repository)))
      (expect (= 1 (nerimux/model:repository-behind repository)))
      (expect (= 1 (nerimux/model:organization-active-worktree-count organization)))
      (expect (= 2 (nerimux/model:organization-attention-count organization)))
      (expect (nerimux/model:worktree-attention-p dirty-worktree))
      (expect (nerimux/model:worktree-attention-p missing-worktree)))))
