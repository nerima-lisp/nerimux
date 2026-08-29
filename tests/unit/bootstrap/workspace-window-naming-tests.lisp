(in-package #:nerimux/test)

;;;; R5.8: window names are branch name + sequence number
;;;; (workspace-window.lisp), unit-tested directly against %worktree-window-name
;;;; / %worktree-windows -- no session/dispatch machinery needed for the naming
;;;; rule itself.

(describe "workspace-window-naming-suite"

  (it "workspace-new-window-passes-geometry-and-starts-reader-by-default"
    (let ((arguments nil)
          (reader-pane nil)
          (window (nerimux/model:make-window :id 1 :name "new"))
          (pane :active-pane))
      (with-stubbed-fdefinition
          ((nerimux::session-new-window
            (lambda (session name rows cols base-index start-dir)
              (setf arguments (list session name rows cols base-index start-dir))
              window))
           (nerimux::start-reader-thread
            (lambda (pane) (setf reader-pane pane)))
           (nerimux::window-active-pane
            (lambda (active-window)
              (declare (ignore active-window))
              pane))
           (nerimux/session::%shell-basename
            (lambda () "shell")))
        (let ((nerimux::*term-rows* 30)
              (nerimux::*term-cols* 100))
          (expect (eq window (nerimux::%workspace-new-window :session
                                                            :start-dir "/tmp/work")))
          (expect (equal '(:session "shell" 29 100 1 "/tmp/work") arguments))
          (expect (eq pane reader-pane))))))

  (it "workspace-new-window-can-defer-reader-start"
    (let ((reader-called nil)
          (window :deferred-window))
      (with-stubbed-fdefinition
          ((nerimux::session-new-window
            (lambda (&rest args)
              (declare (ignore args))
              window))
           (nerimux::start-reader-thread
            (lambda (pane) (declare (ignore pane)) (setf reader-called t))))
        (expect (eq window (nerimux::%workspace-new-window :session
                                                            :name "named"
                                                            :start-reader-p nil)))
        (expect (not reader-called)))))

  ;; The first window for a worktree is bare: just the branch name.
  (it "worktree-window-name-first-window-is-bare-branch-name"
    (let ((worktree
            (nerimux/model:make-worktree
             :id "wt" :path "/tmp/wt" :branch "feat/phase3")))
      (expect (string= "feat/phase3" (nerimux::%worktree-window-name worktree)))))

  ;; A worktree with an existing window numbers the next one (2), and a third
  ;; window continues the count -- the ordinal is 1 + the count of windows
  ;; %worktree-windows already finds among the worktree's panes.
  (it "worktree-window-name-numbers-subsequent-windows"
    (let* ((worktree
             (nerimux/model:make-worktree
              :id "wt" :path "/tmp/wt" :branch "feat/phase3"))
           (win-1 (make-no-pty-pane 1 0 0 20 5))
           (win-2 (make-no-pty-pane 2 0 0 20 5)))
      (setf (nerimux/model:pane-window win-1)
            (nerimux/model:make-window :id 1 :name "feat/phase3" :panes (list win-1)))
      (setf (nerimux/model:pane-window win-2)
            (nerimux/model:make-window :id 2 :name "feat/phase3 (2)" :panes (list win-2)))
      (nerimux/model:worktree-add-pane worktree win-1)
      (expect (string= "feat/phase3 (2)" (nerimux::%worktree-window-name worktree)))
      (nerimux/model:worktree-add-pane worktree win-2)
      (expect (string= "feat/phase3 (3)" (nerimux::%worktree-window-name worktree)))))

  ;; A detached-HEAD worktree (no branch) falls back to its path, then its id.
  (it "worktree-window-name-falls-back-to-path-then-id-with-no-branch"
    (let ((by-path
            (nerimux/model:make-worktree :id "wt-1" :path "/tmp/detached" :branch nil))
          (by-id
            (nerimux/model:make-worktree :id "wt-2" :path "" :branch nil)))
      (expect (string= "/tmp/detached" (nerimux::%worktree-window-name by-path)))
      (expect (string= "wt-2" (nerimux::%worktree-window-name by-id)))))

  ;; %worktree-windows returns the DISTINCT windows holding the worktree's
  ;; panes, ordered by window id -- not one entry per pane.
  (it "worktree-windows-deduplicates-and-orders-by-window-id"
    (let* ((worktree (nerimux/model:make-worktree :id "wt" :path "/tmp/wt"))
           (window-a (nerimux/model:make-window :id 5 :name "a"))
           (window-b (nerimux/model:make-window :id 2 :name "b"))
           (pane-1 (make-no-pty-pane 1 0 0 20 5))
           (pane-2 (make-no-pty-pane 2 0 0 20 5))
           (pane-3 (make-no-pty-pane 3 0 0 20 5)))
      (setf (nerimux/model:pane-window pane-1) window-a
            (nerimux/model:pane-window pane-2) window-a
            (nerimux/model:pane-window pane-3) window-b)
      (nerimux/model:worktree-add-pane worktree pane-1)
      (nerimux/model:worktree-add-pane worktree pane-2)
      (nerimux/model:worktree-add-pane worktree pane-3)
      (expect (equal (list window-b window-a) (nerimux::%worktree-windows worktree))))))
