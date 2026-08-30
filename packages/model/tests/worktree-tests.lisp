(in-package #:nerimux/test/model)

(describe "worktree-pane-link"
  (it "keeps the pane back-pointer and avoids duplicate attachments"
    (let* ((worktree (nerimux/workspace-model:make-worktree :path "/work/nerimux"))
           (pane (nerimux/pane:make-pane :id 7)))
      (nerimux/pane:worktree-add-pane worktree pane)
      (nerimux/pane:worktree-add-pane worktree pane)
      (expect (eq worktree (nerimux/pane:pane-worktree pane)))
      (expect (= 1 (length (nerimux/workspace-model:worktree-panes worktree))))
      (expect (eq pane (first (nerimux/workspace-model:worktree-panes worktree)))))))

(describe "worktree-values"
  (it "retains defaults when optional values are omitted"
    (let ((worktree (nerimux/workspace-model:make-worktree)))
      (expect (equal "||" (nerimux/workspace-model:worktree-id worktree)))
      (expect (equal "" (nerimux/workspace-model:worktree-path worktree)))
      (expect (null (nerimux/workspace-model:worktree-panes worktree)))
      (expect (= 0 (nerimux/workspace-model:worktree-ahead worktree)))
      (expect (= 0 (nerimux/workspace-model:worktree-behind worktree)))
      (expect (not (nerimux/workspace-model:worktree-dirty-p worktree)))))
  (it "keeps raw constructor defaults explicit"
    (let ((worktree (nerimux/workspace-model::%make-worktree)))
      (expect (equal "" (nerimux/workspace-model:worktree-id worktree)))
      (expect (null (nerimux/workspace-model:worktree-repository worktree)))
      (expect (equal "" (nerimux/workspace-model:worktree-path worktree)))
      (expect (null (nerimux/workspace-model:worktree-branch worktree)))
      (expect (null (nerimux/workspace-model:worktree-head worktree)))
      (expect (null (nerimux/workspace-model:worktree-status worktree)))
      (expect (null (nerimux/workspace-model:worktree-panes worktree)))
      (expect (null (nerimux/workspace-model:worktree-dirty-p worktree)))
      (expect (null (nerimux/workspace-model:worktree-conflict-p worktree)))
      (expect (= 0 (nerimux/workspace-model:worktree-ahead worktree)))
      (expect (= 0 (nerimux/workspace-model:worktree-behind worktree)))
      (expect (null (nerimux/workspace-model:worktree-bare-p worktree)))
      (expect (null (nerimux/workspace-model:worktree-locked-p worktree)))
      (expect (null (nerimux/workspace-model:worktree-prunable-p worktree)))
      (expect (null (nerimux/workspace-model:worktree-missing-p worktree)))))
  (it "normalizes pathname values and copies pane collections"
    (let ((panes (list (nerimux/pane:make-pane :id 1))))
      (let ((worktree (nerimux/workspace-model:make-worktree
                       :path #p"/work/nerimux"
                       :branch "main"
                       :head 42
                       :panes panes)))
        (expect (equal "/work/nerimux"
                       (nerimux/workspace-model:worktree-path worktree)))
        (expect (equal "/work/nerimux|main|42"
                       (nerimux/workspace-model:worktree-id worktree)))
        (expect (equal panes (nerimux/workspace-model:worktree-panes worktree)))
        (expect (not (eq panes (nerimux/workspace-model:worktree-panes worktree)))))))
  (it "uses empty components when generating a key from absent values"
    (expect (equal "||" (nerimux/workspace-model::worktree-key nil nil nil)))))
