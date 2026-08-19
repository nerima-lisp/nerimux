(in-package #:nerimux/test)

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
      (expect (= 1 (nerimux/model:organization-repository-count organization)))
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
