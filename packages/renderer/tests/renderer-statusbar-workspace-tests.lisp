(in-package #:nerimux/test/renderer)

(defun %fixture-pane-with-worktree (&key (branch "feature/x")
                                         (ahead 0)
                                         (unread-1 nil)
                                         (unread-2 nil))
  "A pane attached to a worktree/repository, with its window carrying a
   second pane so the middle block has more than one tab to show. Returns
   (VALUES FOCUS-PANE WORKTREE)."
  (let* ((pane-1
          (nerimux/pane:make-pane :id 1 :fd -1 :unread-output-p unread-1))
         (pane-2
          (nerimux/pane:make-pane :id 2 :fd -1 :unread-output-p unread-2))
         (window
          (nerimux/window:make-window :id
                                      1
                                      :name
                                      (format nil "~A" branch)
                                      :panes
                                      (list pane-1 pane-2)))
         (worktree
          (nerimux/workspace-model:make-worktree :id
                                                 "wt-status"
                                                 :path
                                                 "/repo/wt"
                                                 :branch
                                                 branch
                                                 :status
                                                 :fetched
                                                 :ahead
                                                 ahead))
         (repository
          (nerimux/workspace-model:make-repository :id
                                                   "repo-status"
                                                   :specification
                                                   "github.com/team/status"
                                                   :local-path
                                                   "/repo"
                                                   :worktrees
                                                   (list worktree))))
    (setf (nerimux/pane:pane-window pane-1) window
          (nerimux/pane:pane-window pane-2) window)
    (nerimux/pane:worktree-add-pane worktree pane-1)
    (nerimux/pane:worktree-add-pane worktree pane-2)
    (setf (nerimux/workspace-model:worktree-repository worktree) repository)
    (values pane-1 worktree)))

(describe "renderer-suite/statusbar-workspace-unselected"

  (it "shows the em-dash placeholder for repository, worktree, and state when nothing is focused"
    (multiple-value-bind (attention repository worktree state)
        (nerimux/renderer::%status-left-fields nil)
      (expect (string= " " attention))
      (expect (string= repository worktree))
      (expect (string= worktree state))
      (expect (= 1 (length repository)))
      (expect (= #x2014 (char-code (char repository 0))))))

  (it "shows the em-dash placeholder for the middle block when nothing is focused"
    (expect (string= (string (code-char #x2014))
                     (nerimux/renderer::%status-middle-text nil))))

  (it "shows the em-dash placeholder for the right block when there are no messages"
    (expect (string= (string (code-char #x2014))
                     (nerimux/renderer::%status-right-text nil)))))

(describe "renderer-suite/statusbar-workspace-three-blocks"

  (it "composes exactly mode-chip+left+middle+right, with no clock or other segment, when it all fits"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (let* ((messages (list "build ok"))
             (mode-chip (nerimux/renderer::%status-mode-chip :normal))
             (left (nerimux/renderer::%status-left-text
                    pane :include-repository-p t))
             (middle (nerimux/renderer::%status-middle-text pane))
             (right (nerimux/renderer::%status-right-text messages))
             (expected (format nil "~A  ~A  ~A  ~A" mode-chip left middle right))
             (composed
               (nerimux/renderer::%compose-workspace-status-line
                pane messages 200)))
        (expect (string= expected composed))))))

(describe "renderer-suite/statusbar-workspace-pane-tabs"

  (it "marks only the unread pane's tab with ! in [w1: 1 2*!3]"
    (let* ((pane-1 (nerimux/pane:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/pane:make-pane :id 2 :fd -1))
           (pane-3 (nerimux/pane:make-pane :id 3 :fd -1 :unread-output-p t))
           (window (nerimux/window:make-window
                    :id 1 :name "w" :panes (list pane-1 pane-2 pane-3)))
           (tab (nerimux/renderer::%status-window-tab window pane-2)))
      (expect (string= "[w1: 1 2*!3]" (strip-sgr tab)))
      (expect tab :to-contain-sgr nerimux/renderer::+sgr-warn+)
      (expect tab :to-contain-sgr nerimux/renderer::+sgr-accent-bold+)))

  (it "composes each pane's own tab token from its unread/active state"
    (let* ((pane-unread-active (nerimux/pane:make-pane :id 5 :fd -1 :unread-output-p t))
           (pane-read-inactive (nerimux/pane:make-pane :id 6 :fd -1)))
      (expect (string= "!5*"
                       (strip-sgr
                        (nerimux/renderer::%status-pane-tab-token
                         pane-unread-active pane-unread-active))))
      (expect (string= " 6"
                       (strip-sgr
                        (nerimux/renderer::%status-pane-tab-token
                         pane-read-inactive pane-unread-active))))))

  (it "lists every window of the focused pane's worktree in the middle block, not just its own"
    (let* ((pane-1 (nerimux/pane:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/pane:make-pane :id 2 :fd -1))
           (window-1 (nerimux/window:make-window :id 1 :name "w1" :panes (list pane-1)))
           (window-2 (nerimux/window:make-window :id 2 :name "w2" :panes (list pane-2)))
           (worktree (nerimux/workspace-model:make-worktree
                      :id "wt-multi-window" :path "/repo/wt" :branch "main")))
      (setf (nerimux/pane:pane-window pane-1) window-1
            (nerimux/pane:pane-window pane-2) window-2)
      (nerimux/pane:worktree-add-pane worktree pane-1)
      (nerimux/pane:worktree-add-pane worktree pane-2)
      (expect (string= "[w1: 1*][w2: 2]"
                       (strip-sgr
                        (nerimux/renderer::%status-middle-text pane-1)))))))

(describe "renderer-suite/statusbar-workspace-degradation"

  (it "drops notification, then tabs, then the repository name, in that order as cols shrink"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree :branch "feature/wide-enough-branch")
      (let* ((messages (list "a very long notification that will not fit once things get tight"))
             (full (nerimux/renderer::%compose-workspace-status-line pane messages 500))
             (full-width (nerimux/renderer::%visible-length full))
             (stage-1 (nerimux/renderer::%compose-workspace-status-line
                       pane messages (1- full-width)))
             (stage-1-width (nerimux/renderer::%visible-length stage-1)))
        (expect (not (search "a very long notification" stage-1)))
        (expect (search "[w1:" stage-1))
        (expect (search "feature/wide-enough-branch" stage-1))
        (let* ((stage-2 (nerimux/renderer::%compose-workspace-status-line
                          pane messages (1- stage-1-width)))
               (stage-2-width (nerimux/renderer::%visible-length stage-2)))
          (expect (not (search "[w1:" stage-2)))
          (expect (search "feature/wide-enough-branch" stage-2))
          (let ((stage-3 (nerimux/renderer::%compose-workspace-status-line
                          pane messages (1- stage-2-width))))
            (expect (not (search "github.com/team/status" stage-3)))
            (expect (search "feature/wide-enough-branch" stage-3))
            (expect (search "CLEAN" stage-3)))))))

  (it "never overflows COLS even at a pathologically narrow width"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (let ((composed
              (nerimux/renderer::%compose-workspace-status-line
               pane (list "notification") 5)))
        (expect (<= (nerimux/renderer::%visible-length composed) 5)))))

  (it "keeps the SCROLLBACK mode chip through every degradation stage, down to the 40-column floor"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree :branch "feature/wide-enough-branch")
      (let* ((messages (list "a very long notification that will not fit once things get tight"))
             (full (nerimux/renderer::%compose-workspace-status-line
                    pane messages 500 :mode :scrollback))
             (full-width (nerimux/renderer::%visible-length full))
             (stage-1 (nerimux/renderer::%compose-workspace-status-line
                       pane messages (1- full-width) :mode :scrollback))
             (stage-1-width (nerimux/renderer::%visible-length stage-1)))
        (expect (search "SCROLLBACK" (strip-sgr full)))
        (expect (search "SCROLLBACK" (strip-sgr stage-1)))
        (let* ((stage-2 (nerimux/renderer::%compose-workspace-status-line
                          pane messages (1- stage-1-width) :mode :scrollback))
               (stage-2-width (nerimux/renderer::%visible-length stage-2)))
          (expect (search "SCROLLBACK" (strip-sgr stage-2)))
          (let ((stage-3 (nerimux/renderer::%compose-workspace-status-line
                          pane messages (1- stage-2-width) :mode :scrollback)))
            (expect (search "SCROLLBACK" (strip-sgr stage-3)))
            (expect (search "SCROLLBACK"
                            (strip-sgr
                             (nerimux/renderer::%compose-workspace-status-line
                              pane messages 40 :mode :scrollback))))))))))

(describe "renderer-suite/statusbar-workspace-mode-chip"

  (it "renders no chip and no literal NIL text when mode is nil"
    (expect (null (nerimux/renderer::%status-mode-chip nil)))
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (let ((line (strip-sgr
                   (nerimux/renderer::%compose-workspace-status-line
                    pane (list "build ok") 200 :mode nil))))
        (expect (not (search "NIL" line))))))

  (it "shows the chip alone for a real modal value, with no i-to-type hint"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (let* ((messages (list "build ok"))
             (scrollback-line
               (strip-sgr
                (nerimux/renderer::%compose-workspace-status-line
                 pane messages 200 :mode :scrollback)))
             (command-line
               (strip-sgr
                (nerimux/renderer::%compose-workspace-status-line
                 pane messages 200 :mode :command))))
        (expect (search "SCROLLBACK" scrollback-line))
        (expect (not (search "i to type" scrollback-line)))
        (expect (search "COMMAND" command-line))
        (expect (not (search "i to type" command-line))))))

  (it "render-status-bar threads mode through to the chip"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (multiple-value-bind (session) (make-single-pane-session)
        (let ((output
                (strip-sgr
                 (with-output-to-string (s)
                   (nerimux/renderer::render-status-bar
                    s session 24 200
                    :focus-pane pane :messages (list "build ok") :mode :scrollback)))))
          (expect (search "SCROLLBACK" output))
          (expect (not (search "i to type" output)))))))

  (it "render-status-bar shows no literal NIL text when mode is nil"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (multiple-value-bind (session) (make-single-pane-session)
        (let ((output
                (strip-sgr
                 (with-output-to-string (s)
                   (nerimux/renderer::render-status-bar
                    s session 24 200
                    :focus-pane pane :messages (list "build ok") :mode nil)))))
          (expect (not (search "NIL" output))))))))
