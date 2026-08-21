(in-package #:nerimux/test)

;;;; Direct unit tests for the R6.5/R6.7 status line (renderer-statusbar.lisp):
;;;; three blocks (left: attention+repository+worktree+state, middle: window/
;;;; pane tabs, right: latest notification), unselected fields show the
;;;; em-dash placeholder rather than carrying the previous frame's value
;;;; forward, width-driven degradation drops notification -> tabs ->
;;;; repository name in that order while branch and state token are never
;;;; dropped, and no clock is ever composed in.

(defun %fixture-pane-with-worktree (&key (branch "feature/x") (ahead 0)
                                          (unread-1 nil) (unread-2 nil))
  "A pane attached to a worktree/repository, with its window carrying a
   second pane so the middle block has more than one tab to show. Returns
   (VALUES FOCUS-PANE WORKTREE)."
  (let* ((pane-1 (nerimux/model:make-pane :id 1 :fd -1
                                          :unread-output-p unread-1))
         (pane-2 (nerimux/model:make-pane :id 2 :fd -1
                                          :unread-output-p unread-2))
         (window (nerimux/model:make-window :id 1 :name (format nil "~A" branch)
                                            :panes (list pane-1 pane-2)))
         (worktree (nerimux/model:make-worktree
                    :id "wt-status" :path "/repo/wt" :branch branch
                    :status :fetched :ahead ahead))
         (repository (nerimux/model:make-repository
                      :id "repo-status" :specification "github.com/team/status"
                      :local-path "/repo" :worktrees (list worktree))))
    (setf (nerimux/model:pane-window pane-1) window
          (nerimux/model:pane-window pane-2) window)
    (nerimux/model:worktree-add-pane worktree pane-1)
    (nerimux/model:worktree-add-pane worktree pane-2)
    (setf (nerimux/model:worktree-repository worktree) repository)
    (values pane-1 worktree)))

(describe "renderer-suite/statusbar-workspace-unselected"

  ;; No focus pane: every field in the left block that would otherwise name a
  ;; repository/worktree/state shows the em-dash placeholder -- never a blank
  ;; and never the previous frame's value (design doc §2/§3.3), since this is
  ;; a pure function of its FOCUS-PANE argument with nothing else to carry
  ;; anything forward from.
  (it "shows the em-dash placeholder for repository, worktree, and state when nothing is focused"
    (multiple-value-bind (attention repository worktree state)
        (nerimux/renderer::%status-left-fields nil)
      (expect (string= " " attention))
      (expect (string= repository worktree))
      (expect (string= worktree state))
      (expect (= 1 (length repository)))
      (expect (= #x2014 (char-code (char repository 0))))))

  ;; The middle block with no focus pane (no worktree, so no windows to list)
  ;; also falls back to the em-dash.
  (it "shows the em-dash placeholder for the middle block when nothing is focused"
    (expect (string= (string (code-char #x2014))
                     (nerimux/renderer::%status-middle-text nil))))

  ;; The right block with no messages shows the em-dash too.
  (it "shows the em-dash placeholder for the right block when there are no messages"
    (expect (string= (string (code-char #x2014))
                     (nerimux/renderer::%status-right-text nil)))))

(describe "renderer-suite/statusbar-workspace-three-blocks"

  ;; The composed line is EXACTLY the three blocks joined by a two-space
  ;; separator, in left/middle/right order -- nothing else (in particular, no
  ;; clock, which R6.5 explicitly drops: "時計を含まない"). Deriving the
  ;; expected value from the same building-block functions
  ;; (%STATUS-LEFT-TEXT/%STATUS-MIDDLE-TEXT/%STATUS-RIGHT-TEXT) the composer
  ;; itself calls, rather than a hand-typed literal, is what makes this a
  ;; real "no 4th segment was silently added" check: if a clock block were
  ;; spliced in, this equality would break.
  (it "composes exactly left+middle+right, with no clock or other segment, when it all fits"
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
        (expect (string= expected composed))))))

(describe "renderer-suite/statusbar-workspace-pane-tabs"

  ;; R6.7: an unread pane's tab token uses `!` in place of the usual leading
  ;; space; an unattended-but-not-unread pane keeps the space; the active
  ;; pane also carries `*`. This is the exact "[w1: 1 2*!3]" shape from the
  ;; requirement, built from three panes so all three markers appear at once.
  (it "marks only the unread pane's tab with ! in [w1: 1 2*!3]"
    (let* ((pane-1 (nerimux/model:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/model:make-pane :id 2 :fd -1))
           (pane-3 (nerimux/model:make-pane :id 3 :fd -1 :unread-output-p t))
           (window (nerimux/model:make-window
                    :id 1 :name "w" :panes (list pane-1 pane-2 pane-3))))
      (expect (string= "[w1: 1 2*!3]"
                       (nerimux/renderer::%status-window-tab window pane-2)))))

  ;; The per-pane token in isolation, both branches: unread -> "!", read ->
  ;; " " as the leading marker; active -> trailing "*", inactive -> none.
  (it "composes each pane's own tab token from its unread/active state"
    (let* ((pane-unread-active (nerimux/model:make-pane :id 5 :fd -1 :unread-output-p t))
           (pane-read-inactive (nerimux/model:make-pane :id 6 :fd -1)))
      (expect (string= "!5*"
                       (nerimux/renderer::%status-pane-tab-token
                        pane-unread-active pane-unread-active)))
      (expect (string= " 6"
                       (nerimux/renderer::%status-pane-tab-token
                        pane-read-inactive pane-unread-active)))))

  ;; The middle block strings together every window under the focused pane's
  ;; worktree (%WORKTREE-TREE-WINDOWS, R5.8 id order), not just the focused
  ;; pane's own window.
  (it "lists every window of the focused pane's worktree in the middle block, not just its own"
    (let* ((pane-1 (nerimux/model:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/model:make-pane :id 2 :fd -1))
           (window-1 (nerimux/model:make-window :id 1 :name "w1" :panes (list pane-1)))
           (window-2 (nerimux/model:make-window :id 2 :name "w2" :panes (list pane-2)))
           (worktree (nerimux/model:make-worktree
                      :id "wt-multi-window" :path "/repo/wt" :branch "main")))
      (setf (nerimux/model:pane-window pane-1) window-1
            (nerimux/model:pane-window pane-2) window-2)
      (nerimux/model:worktree-add-pane worktree pane-1)
      (nerimux/model:worktree-add-pane worktree pane-2)
      (expect (string= "[w1: 1*][w2: 2]"
                       (nerimux/renderer::%status-middle-text pane-1))))))

(describe "renderer-suite/statusbar-workspace-degradation"

  ;; R6.5/design doc §11: as the terminal narrows, blocks drop in the order
  ;; notification -> tabs -> repository name; branch and state token are
  ;; never dropped. All three drop thresholds are derived from
  ;; %VISIBLE-LENGTH on the SAME assembled strings %COMPOSE-WORKSPACE-STATUS-
  ;; LINE itself builds, so this exercises the real degradation ladder rather
  ;; than a hand-guessed column count.
  (it "drops notification, then tabs, then the repository name, in that order as cols shrink"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree :branch "feature/wide-enough-branch")
      (let* ((messages (list "a very long notification that will not fit once things get tight"))
             (full (nerimux/renderer::%compose-workspace-status-line pane messages 500))
             (full-width (nerimux/renderer::%visible-length full))
             ;; One column short of the full composition: notification must drop.
             (stage-1 (nerimux/renderer::%compose-workspace-status-line
                       pane messages (1- full-width)))
             (stage-1-width (nerimux/renderer::%visible-length stage-1)))
        (expect (not (search "a very long notification" stage-1)))
        (expect (search "[w1:" stage-1))
        (expect (search "feature/wide-enough-branch" stage-1))
        ;; One column short of stage-1: the window/pane tabs must drop too.
        (let* ((stage-2 (nerimux/renderer::%compose-workspace-status-line
                          pane messages (1- stage-1-width)))
               (stage-2-width (nerimux/renderer::%visible-length stage-2)))
          (expect (not (search "[w1:" stage-2)))
          (expect (search "feature/wide-enough-branch" stage-2))
          ;; One column short of stage-2: the repository name must drop, but
          ;; branch and state token survive even this far.
          (let ((stage-3 (nerimux/renderer::%compose-workspace-status-line
                          pane messages (1- stage-2-width))))
            (expect (not (search "github.com/team/status" stage-3)))
            (expect (search "feature/wide-enough-branch" stage-3))
            (expect (search "CLEAN" stage-3)))))))

  ;; Below even the branch-only width, the final safety net (%VISIBLE-
  ;; TRUNCATE) still returns a result no wider than COLS -- it does not
  ;; overflow the terminal even at the pathological single-digit width R6.10
  ;; already refuses to reach in practice.
  (it "never overflows COLS even at a pathologically narrow width"
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (let ((composed
              (nerimux/renderer::%compose-workspace-status-line
               pane (list "notification") 5)))
        (expect (<= (nerimux/renderer::%visible-length composed) 5))))))
