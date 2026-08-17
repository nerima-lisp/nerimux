(in-package #:cl-tmux/test)

(describe "worktree-pane-link"
  (it "keeps the pane back-pointer and avoids duplicate attachments"
    (let* ((worktree (cl-tmux/model:make-worktree :path "/work/cl-tmux"))
           (pane (cl-tmux/model:make-pane :id 7)))
      (cl-tmux/model:worktree-add-pane worktree pane)
      (cl-tmux/model:worktree-add-pane worktree pane)
      (expect (eq worktree (cl-tmux/model:pane-worktree pane)))
      (expect (= 1 (length (cl-tmux/model:worktree-panes worktree))))
      (expect (eq pane (first (cl-tmux/model:worktree-panes worktree)))))))
