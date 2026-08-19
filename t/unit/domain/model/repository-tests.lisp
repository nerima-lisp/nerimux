(in-package #:nerimux/test)

(describe "repository-status"
  (it "uses the main worktree for repository ahead and behind state"
    (let* ((repository (nerimux/model:make-repository
                        :specification "nerima-lisp/nerimux"))
           (main-worktree (nerimux/model:make-worktree
                           :path "/work/nerimux"
                           :branch "main"
                           :ahead 3
                           :behind 4))
           (feature-worktree (nerimux/model:make-worktree
                              :path "/work/nerimux-feature"
                              :branch "feature"
                              :ahead 9
                              :behind 8)))
      (nerimux/model:repository-add-worktree repository main-worktree)
      (nerimux/model:repository-add-worktree repository feature-worktree)
      (expect (eq main-worktree (nerimux/model:repository-main-worktree repository)))
      (expect (= 3 (nerimux/model:repository-ahead repository)))
      (expect (= 4 (nerimux/model:repository-behind repository)))
      (expect (equal "/work/nerimux-feature"
                     (nerimux/model:worktree-path
                      (nerimux/model:repository-worktree-by-path
                       repository "/work/nerimux-feature")))))))
