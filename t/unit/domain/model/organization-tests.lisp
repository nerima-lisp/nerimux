(in-package #:cl-tmux/test)

(describe "organization-hierarchy"
  (it "links repositories and counts worktree attention"
    (let* ((organization (cl-tmux/model:make-organization
                          :host "github.com"
                          :name "nerima-lisp"))
           (repository (cl-tmux/model:make-repository
                        :specification "nerima-lisp/cl-tmux"
                        :local-path "/work/cl-tmux"))
           (dirty-worktree (cl-tmux/model:make-worktree
                            :path "/work/cl-tmux"
                            :branch "main"
                            :head "abc"
                            :dirty-p t
                            :conflict-p t
                            :ahead 2
                            :behind 1))
           (missing-worktree (cl-tmux/model:make-worktree
                              :path "/work/cl-tmux-old"
                              :missing-p t)))
      (cl-tmux/model:organization-add-repository organization repository)
      (cl-tmux/model:repository-add-worktree repository dirty-worktree)
      (cl-tmux/model:repository-add-worktree repository missing-worktree)
      (expect (= 1 (cl-tmux/model:organization-repository-count organization)))
      (expect (eq organization (cl-tmux/model:repository-organization repository)))
      (expect (eq repository (cl-tmux/model:worktree-repository dirty-worktree)))
      (expect (eq dirty-worktree
                  (cl-tmux/model:repository-worktree-by-path repository "/work/cl-tmux")))
      (expect (cl-tmux/model:repository-dirty-p repository))
      (expect (cl-tmux/model:repository-conflict-p repository))
      (expect (= 2 (cl-tmux/model:repository-ahead repository)))
      (expect (= 1 (cl-tmux/model:repository-behind repository)))
      (expect (= 1 (cl-tmux/model:organization-active-worktree-count organization)))
      (expect (= 2 (cl-tmux/model:organization-attention-count organization)))
      (expect (cl-tmux/model:worktree-attention-p dirty-worktree))
      (expect (cl-tmux/model:worktree-attention-p missing-worktree)))))
