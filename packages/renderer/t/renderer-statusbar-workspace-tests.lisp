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

  (it "leaves every left-block field out when nothing is focused"
    (multiple-value-bind (attention repository worktree state)
        (nerimux/renderer::%status-left-fields nil)
      (expect (null attention))
      (expect (null repository))
      (expect (null worktree))
      (expect (null state))
      (expect (null (nerimux/renderer::%status-left-text
                     nil :include-repository-p t)))))

  (it "shows no middle block when nothing is focused"
    (expect (null (nerimux/renderer::%status-middle-text nil))))

  (it "shows the prefix key hints in the right block when there are no messages"
    (expect (string= "C-q ? keys  C-q C-p picker  C-q ; prev pane  C-q L prev win  C-q q sends C-q  C-q w repolist  C-q d detach"
                     (strip-sgr (nerimux/renderer::%status-right-text nil))))))

(describe "renderer-suite/statusbar-workspace-three-blocks"

  (it "composes exactly left+middle+right, with no chip, clock, or other segment, when it all fits"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (let* ((messages (list "build ok"))
             (left (nerimux/renderer::%status-left-text
                    pane :include-repository-p t))
             (middle (nerimux/renderer::%status-middle-text pane))
             (right (nerimux/renderer::%status-right-text messages))
             (expected (format nil "~A  ~A  ~A" left middle right))
             (composed
               (nerimux/renderer::%compose-workspace-status-line
                pane messages 200)))
        (expect (string= expected composed))
        (expect (search "github.com/team/status · feature/x" (strip-sgr composed))))))

  (it "reads the worktree as org/repo · branch, with no em-dash placeholder anywhere"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (let ((line (strip-sgr
                   (nerimux/renderer::%compose-workspace-status-line pane nil 200))))
        (expect (not (find (code-char #x2014) line)))
        (expect (search "github.com/team/status · feature/x CLEAN" line))))))

(describe "renderer-suite/statusbar-workspace-pane-tabs"

  (it "marks only the unread pane's tab with ! in win 1:feature/x · pane 1 2* 3!"
    (let* ((pane-1 (nerimux/pane:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/pane:make-pane :id 2 :fd -1))
           (pane-3 (nerimux/pane:make-pane :id 3 :fd -1 :unread-output-p t))
           (window (nerimux/window:make-window
                    :id 1 :name "feature/x" :panes (list pane-1 pane-2 pane-3)))
           (tab (nerimux/renderer::%status-window-tab window pane-2)))
      (expect (string= "win 1:feature/x · pane 1 2* 3!" (strip-sgr tab)))
      (expect tab :to-contain-sgr nerimux/renderer::+sgr-warn+)
      (expect tab :to-contain-sgr nerimux/renderer::+sgr-accent-bold+)))
  (it "removes C0, C1, and bidi controls from the window label"
    (let* ((pane (nerimux/pane:make-pane :id 1 :fd -1))
           (window (nerimux/window:make-window
                    :id 1
                    :name (format nil "feature/~C[52c~C~C" (code-char 27) (code-char #x9b) (code-char #x200e))
                    :panes (list pane)))
           (tab (nerimux/renderer::%status-window-tab window pane)))
      (expect (string= "win 1:feature/[52c · pane 1*" (strip-sgr tab)))))

  (it "keeps listing every pane, plus a zoom marker, while the window is zoomed"
    (let* ((pane-1 (nerimux/pane:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/pane:make-pane :id 2 :fd -1))
           (window (nerimux/window:make-window
                    :id 4 :name "feature/zoom" :panes (list pane-1 pane-2))))
      (setf (nerimux/window:window-zoom-tree window)
            (nerimux/layout:make-layout-split
             :h
             (nerimux/layout:make-layout-leaf pane-1)
             (nerimux/layout:make-layout-leaf pane-2))
            (nerimux/window:window-panes window) (list pane-1)
            (nerimux/window:window-zoom-p window) t)
      (expect (string= "win 4:feature/zoom · pane 1* 2 [zoom]"
                       (strip-sgr
                        (nerimux/renderer::%status-window-tab window pane-1))))))

  (it "composes each pane's own tab token from its unread/active state"
    (let* ((pane-unread-active (nerimux/pane:make-pane :id 5 :fd -1 :unread-output-p t))
           (pane-read-inactive (nerimux/pane:make-pane :id 6 :fd -1)))
      (expect (string= " 5*!"
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
           (window-1 (nerimux/window:make-window :id 1 :name "feature/main" :panes (list pane-1)))
           (window-2 (nerimux/window:make-window :id 2 :name "feature/main (2)" :panes (list pane-2)))
           (worktree (nerimux/workspace-model:make-worktree
                      :id "wt-multi-window" :path "/repo/wt" :branch "main")))
      (setf (nerimux/pane:pane-window pane-1) window-1
            (nerimux/pane:pane-window pane-2) window-2)
      (nerimux/pane:worktree-add-pane worktree pane-1)
      (nerimux/pane:worktree-add-pane worktree pane-2)
      (expect (string= "win 1:feature/main · pane 1*  win 2:feature/main (2) · pane 2"
                       (strip-sgr
                        (nerimux/renderer::%status-middle-text pane-1))))))

  (it "leaves the middle block out for a single unzoomed pane in a single window"
    (let* ((pane (nerimux/pane:make-pane :id 1 :fd -1))
           (window (nerimux/window:make-window :id 1 :name "w" :panes (list pane)))
           (worktree (nerimux/workspace-model:make-worktree
                      :id "wt-single" :path "/repo/wt" :branch "main")))
      (setf (nerimux/pane:pane-window pane) window)
      (nerimux/pane:worktree-add-pane worktree pane)
      (expect (null (nerimux/renderer::%status-middle-text pane))))))

(describe "renderer-suite/statusbar-workspace-degradation"

  (it "elides the notification, then tabs, then drops it, then the repository name, as cols shrink"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree :branch "feature/wide-enough-branch")
      (let ((messages
              (list "a very long notification that will not fit once things get tight"))
            (head "a very long notification")
            (elided nil)
            (dropped nil)
            (no-tabs nil)
            (no-repository nil))
        (flet ((compose (cols)
                 (strip-sgr
                  (nerimux/renderer::%compose-workspace-status-line pane
                                                                    messages
                                                                    cols))))
          (expect (search head (compose 500)))
          (loop for cols from 500 downto 20
                for line = (compose cols)
                do (when (and (null elided) (find #\… line))
                     (setf elided cols))
                   (when (and (null dropped)
                              (not (find #\… line))
                              (not (search head line)))
                     (setf dropped cols))
                   (when (and (null no-tabs) (not (search "win 1:" line)))
                     (setf no-tabs cols))
                   (when (and (null no-repository)
                              (not (search "github.com/team/status" line)))
                     (setf no-repository cols)))
          (expect (and elided dropped no-tabs no-repository))
          (expect (> elided dropped))
          (expect (> no-tabs dropped))
          (expect (>= no-tabs no-repository))
          ;; The tail of the elided notification is the half that identifies it.
          (expect (search "tight" (compose (1- elided))))
          (expect (search "feature/wide-enough-branch" (compose 40)))
          (expect (search "CLEAN" (compose 40)))))))
  (it "keeps pane failure messages visible with multiple windows"
    (let* ((pane-1 (nerimux/pane:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/pane:make-pane :id 2 :fd -1))
           (pane-3 (nerimux/pane:make-pane :id 3 :fd -1))
           (window-1 (nerimux/window:make-window
                      :id 1 :name "feature/beta" :panes (list pane-1 pane-2)))
           (window-2 (nerimux/window:make-window
                      :id 2 :name "feature/beta (2)" :panes (list pane-3)))
           (worktree (nerimux/workspace-model:make-worktree
                      :id "wt-notification-width"
                      :path "/repo/wt"
                      :branch "feature/beta"
                      :status :fetched))
           (repository (nerimux/workspace-model:make-repository
                        :id "repo-notification-width"
                        :specification "example.test/org/bare-repo"
                        :local-path "/repo"
                        :worktrees (list worktree))))
      (setf (nerimux/pane:pane-window pane-1) window-1
            (nerimux/pane:pane-window pane-2) window-1
            (nerimux/pane:pane-window pane-3) window-2
            (nerimux/workspace-model:worktree-repository worktree) repository)
      (nerimux/pane:worktree-add-pane worktree pane-1)
      (nerimux/pane:worktree-add-pane worktree pane-2)
      (nerimux/pane:worktree-add-pane worktree pane-3)
      (let ((line
              (strip-sgr
               (nerimux/renderer::%compose-workspace-status-line
                pane-3 (list "no previous pane") 120))))
        (expect (search "no previous pane" line))
        (expect (not (search "win 1:" line)))
        (expect (search "example.test/org/bare-repo · feature/beta" line)))))

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

  (it "renders no chip for the retired :normal mode"
    (expect (null (nerimux/renderer::%status-mode-chip :normal)))
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (expect (not (search "NORMAL"
                           (strip-sgr
                            (nerimux/renderer::%compose-workspace-status-line
                             pane nil 200 :mode :normal)))))))

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
