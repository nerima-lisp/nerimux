(in-package #:nerimux/test/renderer)

;;;; Direct unit tests for the R6.5/R6.7 status line (renderer-statusbar.lisp):
;;;; three blocks (left: attention+repository+worktree+state, middle: window/
;;;; pane tabs, right: latest notification), unselected fields show the
;;;; em-dash placeholder rather than carrying the previous frame's value
;;;; forward, width-driven degradation drops notification -> tabs ->
;;;; repository name in that order while branch and state token are never
;;;; dropped, and no clock is ever composed in.
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

  ;; The composed line is EXACTLY the mode chip followed by the three blocks,
  ;; joined by a two-space separator, in chip/left/middle/right order --
  ;; nothing else (in particular, no clock, which R6.5 explicitly drops:
  ;; "時計を含まない"). Deriving the expected value from the same
  ;; building-block functions (%STATUS-MODE-CHIP/%STATUS-LEFT-TEXT/
  ;; %STATUS-MIDDLE-TEXT/%STATUS-RIGHT-TEXT) the composer itself calls,
  ;; rather than a hand-typed literal, is what makes this a real "no 5th
  ;; segment was silently added" check: if a clock block were spliced in,
  ;; this equality would break.  FR-003 added the mode chip as the always-
  ;; kept leading segment; the default :mode of :normal is what
  ;; %compose-workspace-status-line uses when the caller (here) passes none.
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

  ;; R6.7: an unread pane's tab token uses `!` in place of the usual leading
  ;; space; an unattended-but-not-unread pane keeps the space; the active
  ;; pane also carries `*`. This is the exact "[w1: 1 2*!3]" shape from the
  ;; requirement, built from three panes so all three markers appear at once.
  (it "marks only the unread pane's tab with ! in [w1: 1 2*!3]"
    (let* ((pane-1 (nerimux/pane:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/pane:make-pane :id 2 :fd -1))
           (pane-3 (nerimux/pane:make-pane :id 3 :fd -1 :unread-output-p t))
           (window (nerimux/window:make-window
                    :id 1 :name "w" :panes (list pane-1 pane-2 pane-3)))
           (tab (nerimux/renderer::%status-window-tab window pane-2)))
      ;; The visible shape is the requirement's exact "[w1: 1 2*!3]"; the
      ;; theme adds zero-width SGR around the unread mark (amber) and the
      ;; focused pane's "2*" (bold accent) without changing it.
      (expect (string= "[w1: 1 2*!3]" (strip-sgr tab)))
      (expect tab :to-contain-sgr nerimux/renderer::+sgr-warn+)
      (expect tab :to-contain-sgr nerimux/renderer::+sgr-accent-bold+)))

  ;; The per-pane token in isolation, both branches: unread -> "!", read ->
  ;; " " as the leading marker; active -> trailing "*", inactive -> none.
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

  ;; The middle block strings together every window under the focused pane's
  ;; worktree (%WORKTREE-TREE-WINDOWS, R5.8 id order), not just the focused
  ;; pane's own window.
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
        (expect (<= (nerimux/renderer::%visible-length composed) 5)))))

  ;; Coverage gap flagged by test/security review: %compose-workspace-
  ;; status-line's docstring asserts the mode chip is "never dropped ... it
  ;; must survive as far into a narrow terminal as the fields design doc
  ;; §11 already protects", but nothing exercised that claim with a non-
  ;; default MODE threaded through the same shrink-by-one-column ladder as
  ;; the drops-notification-then-tabs-then-repository-name test above, nor
  ;; at the R6.10 40-column floor its own comment cites. :SCROLLBACK is used
  ;; (rather than the default :normal) -- a real modal CLIENT-CONN-MODAL
  ;; takes today (copy mode, server-multi-dispatch-command-input.lisp),
  ;; unlike the retired :input/:normal command-name spellings -- so this
  ;; cannot be satisfied by accident via some unrelated "NORMAL" substring
  ;; appearing elsewhere in the assembled left/middle/right blocks.
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

  ;; FR-003/FR-007: the mode chip is the status line's leftmost,
  ;; always-kept segment, naming whatever modal has taken the keyboard away
  ;; from the shell. MODE is NIL in the ordinary case -- %RENDER-PANE-FRAME
  ;; (server-multi-render.lisp) passes CLIENT-CONN-MODAL straight through,
  ;; and a pane with no modal takes typing directly since FR-007 -- and the
  ;; chip must then render nothing at all, not the literal text "NIL" that
  ;; (format nil "~:@(~A~)" nil) produces with no guard. This is the bug
  ;; this test pins: %status-mode-chip used to compare MODE against the
  ;; retired :NORMAL modal, which NIL never equals, so NIL fell through to
  ;; the formatting branch unguarded.
  (it "renders no chip and no literal NIL text when mode is nil"
    (expect (null (nerimux/renderer::%status-mode-chip nil)))
    (multiple-value-bind (pane) (%fixture-pane-with-worktree)
      (let ((line (strip-sgr
                   (nerimux/renderer::%compose-workspace-status-line
                    pane (list "build ok") 200 :mode nil))))
        (expect (not (search "NIL" line))))))

  ;; A real modal value (:SCROLLBACK/:COMMAND, the current CLIENT-CONN-
  ;; MODAL keywords a pane frame's status bar actually sees --
  ;; server-multi-dispatch-command-input.lisp -- rather than the retired
  ;; :NORMAL/:INPUT command-name spellings) shows the chip alone: there is
  ;; no hint text for any modal now that FR-007 retired the old :NORMAL
  ;; "swallows keys" distinction the " i to type" hint used to name.
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

  ;; The same contract holds through render-status-bar, the entry point
  ;; %compose-workspace-status-line's only production caller
  ;; (renderer-compose.lisp) actually threads MODE through.
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

  ;; The same NIL-mode contract holds through render-status-bar -- the
  ;; production entry point %render-pane-frame actually calls -- not just
  ;; through %compose-workspace-status-line directly.
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
