(in-package #:nerimux/test)
(defun %renderer-numstat-failure-worktree ()
  (nerimux/workspace-model:make-worktree
   :id "wt-numstat-failed"
   :path "/repo/numstat-failed"
   :branch "numstat-failed"
   :status :fetched
   :dirty-p t
   :numstat-state :failed
   :additions 8
   :deletions 3
   :ahead 2))
(describe "renderer-worktree-numstat-failure-suite"
  (it "reports failed numstat as unknown in the status view title"
    (let* ((worktree (%renderer-numstat-failure-worktree))
           (title (nerimux/renderer::%worktree-status-label worktree)))
      (expect (string= "DIRTY UNKNOWN AHEAD 2" title))
      (expect (not (search "+8 -3" title)))))

  (it "reports failed numstat as unknown in the statusbar"
    (let* ((worktree (%renderer-numstat-failure-worktree))
           (state (strip-sgr (nerimux/renderer::%status-state-text worktree))))
      (expect (search "UNKNOWN" state))
      (expect (not (search "+8 -3" state)))))

  (it "reports failed numstat as unknown in the workspace tree"
    (let* ((worktree (%renderer-numstat-failure-worktree))
           (pane (nerimux/pane:make-pane :id 1 :fd -1)))
      (nerimux/pane:worktree-add-pane worktree pane)
      (setf (nerimux/pane:pane-last-output-time pane)
            (- (get-universal-time) 300))
      (let ((summary (nerimux/renderer::%worktree-tree-info-suffix worktree 100)))
        (expect (search "UNKNOWN" summary))
        (expect (not (search "+8 −3" summary)))))))