(in-package #:cl-tmux/test)

(describe "repository-status"
  (it "uses the main worktree for repository ahead and behind state"
    (let* ((repository (cl-tmux/model:make-repository
                        :specification "nerima-lisp/cl-tmux"))
           (main-worktree (cl-tmux/model:make-worktree
                           :path "/work/cl-tmux"
                           :branch "main"
                           :ahead 3
                           :behind 4))
           (feature-worktree (cl-tmux/model:make-worktree
                              :path "/work/cl-tmux-feature"
                              :branch "feature"
                              :ahead 9
                              :behind 8)))
      (cl-tmux/model:repository-add-worktree repository main-worktree)
      (cl-tmux/model:repository-add-worktree repository feature-worktree)
      (expect (eq main-worktree (cl-tmux/model:repository-main-worktree repository)))
      (expect (= 3 (cl-tmux/model:repository-ahead repository)))
      (expect (= 4 (cl-tmux/model:repository-behind repository)))
      (expect (equal "/work/cl-tmux-feature"
                     (cl-tmux/model:worktree-path
                      (cl-tmux/model:repository-worktree-by-path
                       repository "/work/cl-tmux-feature")))))))
