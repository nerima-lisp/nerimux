(in-package #:nerimux/test)

(describe "worktree-pane-link"
  (it "keeps the pane back-pointer and avoids duplicate attachments"
    (let* ((worktree (nerimux/model:make-worktree :path "/work/nerimux"))
           (pane (nerimux/model:make-pane :id 7)))
      (nerimux/model:worktree-add-pane worktree pane)
      (nerimux/model:worktree-add-pane worktree pane)
      (expect (eq worktree (nerimux/model:pane-worktree pane)))
      (expect (= 1 (length (nerimux/model:worktree-panes worktree))))
      (expect (eq pane (first (nerimux/model:worktree-panes worktree)))))))
