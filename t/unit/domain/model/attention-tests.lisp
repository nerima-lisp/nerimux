(in-package #:nerimux/test)

(describe "worktree attention"
  (it "reports every active attention reason in stable order"
    (let ((worktree
            (nerimux/model:make-worktree
             :id "attention"
             :path "/tmp/attention"
             :branch "feature/attention"
             :dirty-p t
             :conflict-p t
             :ahead 2
             :behind 1
             :missing-p t)))
      (expect (equal '(:conflict :dirty :ahead :behind :missing)
                     (nerimux/model:worktree-attention-reasons worktree)))
      (expect (nerimux/model:worktree-attention-p worktree))))

  (it "projects attention from worktrees to their organization"
    (let* ((organization
             (nerimux/model:make-organization :id "org"))
           (repository
             (nerimux/model:make-repository
              :id "repo"
              :organization organization))
           (clean
             (nerimux/model:make-worktree
              :id "clean"
              :repository repository))
           (attention
             (nerimux/model:make-worktree
              :id "attention"
              :repository repository
              :dirty-p t)))
      (nerimux/model:organization-add-repository organization repository)
      (nerimux/model:repository-add-worktree repository clean)
      (nerimux/model:repository-add-worktree repository attention)
      (let ((worktrees
              (nerimux/model:organization-attention-worktrees organization)))
        (expect (= 1 (length worktrees)))
        (expect (eq attention (first worktrees)))
        (expect (= 1 (nerimux/model:organization-attention-count organization))))))

  (it "tracks pane output, lifecycle failures, and focus clearing"
    (let ((pane (nerimux/model:make-pane :id 7 :title "editor")))
      (nerimux/model:pane-mark-output pane #(72 105 10))
      (expect (nerimux/model:pane-unread-output-p pane))
      (expect (search "Hi" (nerimux/model:pane-last-output pane)))
      (expect (member :unread-output
                      (nerimux/model:pane-attention-reasons pane)))
      (nerimux/model:pane-mark-bell pane)
      (expect (member :bell (nerimux/model:pane-attention-reasons pane)))
      (nerimux/model:pane-mark-process-exit pane :status 2)
      (expect (nerimux/model:pane-process-exited-p pane))
      (expect (nerimux/model:pane-non-zero-exit-p pane))
      (nerimux/model:pane-mark-focused pane)
      (expect (null (nerimux/model:pane-unread-output-p pane)))
      (expect (member :bell (nerimux/model:pane-attention-reasons pane)))
      (expect (member :process-exited
                      (nerimux/model:pane-attention-reasons pane)))
      (expect (integerp (nerimux/model:pane-last-focused-time pane)))
      (nerimux/model:pane-mark-startup-failure pane)
      (expect (member :startup-failed
                      (nerimux/model:pane-attention-reasons pane))))))
