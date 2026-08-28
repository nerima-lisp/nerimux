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

(describe "worktree-values"
  (it "retains defaults when optional values are omitted"
    (let ((worktree (nerimux/model:make-worktree)))
      (expect (equal "||" (nerimux/model:worktree-id worktree)))
      (expect (equal "" (nerimux/model:worktree-path worktree)))
      (expect (null (nerimux/model:worktree-panes worktree)))
      (expect (= 0 (nerimux/model:worktree-ahead worktree)))
      (expect (= 0 (nerimux/model:worktree-behind worktree)))
      (expect (not (nerimux/model:worktree-dirty-p worktree)))))
  (it "keeps raw constructor defaults explicit"
    (let ((worktree (nerimux/model::%make-worktree)))
      (expect (equal "" (nerimux/model:worktree-id worktree)))
      (expect (null (nerimux/model:worktree-repository worktree)))
      (expect (equal "" (nerimux/model:worktree-path worktree)))
      (expect (null (nerimux/model:worktree-branch worktree)))
      (expect (null (nerimux/model:worktree-head worktree)))
      (expect (null (nerimux/model:worktree-status worktree)))
      (expect (null (nerimux/model:worktree-panes worktree)))
      (expect (null (nerimux/model:worktree-dirty-p worktree)))
      (expect (null (nerimux/model:worktree-conflict-p worktree)))
      (expect (= 0 (nerimux/model:worktree-ahead worktree)))
      (expect (= 0 (nerimux/model:worktree-behind worktree)))
      (expect (null (nerimux/model:worktree-bare-p worktree)))
      (expect (null (nerimux/model:worktree-locked-p worktree)))
      (expect (null (nerimux/model:worktree-prunable-p worktree)))
      (expect (null (nerimux/model:worktree-missing-p worktree)))))
  (it "normalizes pathname values and copies pane collections"
    (let ((panes (list (nerimux/model:make-pane :id 1))))
      (let ((worktree (nerimux/model:make-worktree
                       :path #p"/work/nerimux"
                       :branch "main"
                       :head 42
                       :panes panes)))
        (expect (equal "/work/nerimux"
                       (nerimux/model:worktree-path worktree)))
        (expect (equal "/work/nerimux|main|42"
                       (nerimux/model:worktree-id worktree)))
        (expect (equal panes (nerimux/model:worktree-panes worktree)))
        (expect (not (eq panes (nerimux/model:worktree-panes worktree)))))))
  (it "uses empty components when generating a key from absent values"
    (expect (equal "||" (nerimux/model::worktree-key nil nil nil)))))
