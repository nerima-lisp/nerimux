(in-package #:cl-tmux/test)

(describe "worktree attention"
  (it "reports every active attention reason in stable order"
    (let ((worktree
            (cl-tmux/model:make-worktree
             :id "attention"
             :path "/tmp/attention"
             :branch "feature/attention"
             :dirty-p t
             :conflict-p t
             :ahead 2
             :behind 1
             :missing-p t)))
      (expect (equal '(:conflict :dirty :ahead :behind :missing)
                     (cl-tmux/model:worktree-attention-reasons worktree)))
      (expect (cl-tmux/model:worktree-attention-p worktree))))

  (it "projects attention from worktrees to their organization"
    (let* ((organization
             (cl-tmux/model:make-organization :id "org"))
           (repository
             (cl-tmux/model:make-repository
              :id "repo"
              :organization organization))
           (clean
             (cl-tmux/model:make-worktree
              :id "clean"
              :repository repository))
           (attention
             (cl-tmux/model:make-worktree
              :id "attention"
              :repository repository
              :dirty-p t)))
      (cl-tmux/model:organization-add-repository organization repository)
      (cl-tmux/model:repository-add-worktree repository clean)
      (cl-tmux/model:repository-add-worktree repository attention)
      (let ((worktrees
              (cl-tmux/model:organization-attention-worktrees organization)))
        (expect (= 1 (length worktrees)))
        (expect (eq attention (first worktrees)))
        (expect (= 1 (cl-tmux/model:organization-attention-count organization)))))))

  (it "tracks pane output, lifecycle failures, and focus clearing"
    (let ((pane (cl-tmux/model:make-pane :id 7 :title "editor")))
      (cl-tmux/model:pane-mark-output pane #(72 105 10))
      (expect (cl-tmux/model:pane-unread-output-p pane))
      (expect (search "Hi" (cl-tmux/model:pane-last-output pane)))
      (expect (member :unread-output
                      (cl-tmux/model:pane-attention-reasons pane)))
      (cl-tmux/model:pane-mark-bell pane)
      (expect (member :bell (cl-tmux/model:pane-attention-reasons pane)))
      (cl-tmux/model:pane-mark-process-exit pane :status 2)
      (expect (cl-tmux/model:pane-process-exited-p pane))
      (expect (cl-tmux/model:pane-non-zero-exit-p pane))
      (cl-tmux/model:pane-mark-focused pane)
      (expect (null (cl-tmux/model:pane-unread-output-p pane)))
      (expect (member :bell (cl-tmux/model:pane-attention-reasons pane)))
      (expect (member :process-exited
                      (cl-tmux/model:pane-attention-reasons pane)))
      (expect (integerp (cl-tmux/model:pane-last-focused-time pane)))
      (cl-tmux/model:pane-mark-startup-failure pane)
      (expect (member :startup-failed
                      (cl-tmux/model:pane-attention-reasons pane)))))
