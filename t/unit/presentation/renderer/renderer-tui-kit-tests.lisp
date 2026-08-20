(in-package #:nerimux/test)

(describe "renderer-suite/tui-kit"

  (it "maps ANSI cursor movement into a headless surface"
    (let* ((escape (string (code-char 27)))
           (surface
             (nerimux/renderer::%surface-from-ansi-frame
              (format nil "alpha~A[2;3Hxy" escape)
              3
              10))
           (visible (cl-tui-kit/core:surface-string surface)))
      (expect (search "alpha" visible))
      (expect (search "xy" visible))))

  (it "applies the client viewport through the widget path"
    (let* ((top
             (nerimux/renderer::%surface-from-ansi-frame
              (format nil "line-0~%line-1~%line-2")
              2
              10
              :viewport 0))
           (scrolled
             (nerimux/renderer::%surface-from-ansi-frame
              (format nil "line-0~%line-1~%line-2")
              2
              10
              :viewport 1))
           (top-visible (cl-tui-kit/core:surface-string top))
           (scrolled-visible (cl-tui-kit/core:surface-string scrolled)))
      (expect (search "line-0" top-visible))
      (expect (search "line-1" scrolled-visible))
      (expect (not (search "line-0" scrolled-visible)))))

  (it "presents a complete frame through a fresh ANSI backend"
    (let ((output
            (nerimux/renderer::%render-ansi-frame-with-tui-kit
             "hello"
             2
             8)))
      (expect (search "hello" output))
      (expect (search (string (code-char 27)) output))))

  (it "renders the workspace hierarchy through the tree widget"
    (let* ((worktree
             (nerimux/model:make-worktree
              :id "wt-tree"
              :path "/repo/work"
              :branch "feature/tree"))
           (repository
             (nerimux/model:make-repository
              :id "repo-tree"
              :specification "github.com/team/tree"
              :local-path "/repo"
              :worktrees (list worktree)))
           (organization
             (nerimux/model:make-organization
              :id "github.com/team"
              :host "github.com"
              :name "team"
              :repositories (list repository)))
           (output
             (nerimux/renderer:render-workspace-overview-to-tui-string
              (list organization)
              12
              100
              :selected-tree-object worktree)))
      (expect (search "org" output))
      (expect (search "repo" output))
      (expect (search "feature/tree" output))))

  (it "renders the picker through input, list, form, and modal widgets"
    (let* ((worktree
             (nerimux/model:make-worktree
              :id "wt-picker-widget"
              :path "/repo/work"
              :branch "feature/picker-widget"))
           (repository
             (nerimux/model:make-repository
              :id "repo-picker-widget"
              :specification "github.com/team/picker-widget"
              :local-path "/repo"
              :worktrees (list worktree)))
           (organization
             (nerimux/model:make-organization
              :id "github.com/team"
              :host "github.com"
              :name "team"
              :repositories (list repository)))
           (items
             (remove-if-not
              (lambda (item)
                (eq :worktree (nerimux/picker:picker-item-kind item)))
              (nerimux/picker:build-global-picker-items
               (list organization))))
           (surface
             (nerimux/renderer::%surface-from-ansi-frame "" 16 80)))
      (nerimux/renderer::%render-picker-widget
       surface 16 80 items "feature" 0 nil)
      (let ((output (cl-tui-kit/core:surface-string surface)))
        (expect (search "GLOBAL PICKER" output))
        (expect (search "feature/picker-widget" output))
        (expect (search "search workspace" output)))))

  (it "routes client picker mode through the public tui renderer"
    (let ((output
            (nerimux/renderer:render-session-to-tui-string
             (nerimux/model:make-session :id 22 :name "picker")
             16
             80
             :mode :picker
             :picker-query "missing")))
      (expect (search "GLOBAL PICKER" output))
      (expect (search "no matches" output))))

  (it "renders the bare repository overview with pane attention and preview"
    (let* ((pane (nerimux/model:make-pane :id 7 :title "editor"))
           (worktree
             (nerimux/model:make-worktree
              :id "wt"
              :path "/repo/work"
              :branch "feature/ui"
              :panes (list pane)))
           (repository
             (nerimux/model:make-repository
              :id "repo"
              :specification "github.com/team/repo"
              :local-path "/repo"
              :worktrees (list worktree)))
           (organization
             (nerimux/model:make-organization
              :id "github.com/team"
              :host "github.com"
              :name "team"
              :repositories (list repository)))
           (output
             (progn
               (nerimux/model:worktree-add-pane worktree pane)
               (nerimux/model:pane-mark-output pane #(111 107))
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization)
                12
                100
                :focus-pane pane))))
      (expect (search "WORKSPACES" output))
      (expect (search "github.com/team" output))
      (expect (search "feature/ui" output))
      (expect (search "PANES branch dirty exit unread" output))
      (expect (search "u:!" output))
      (expect (search "pane/7 editor" output))
      (expect (search "output: ok" output))))

  (it "renders a selectable attention cursor"
    (let* ((pane (nerimux/model:make-pane :id 8 :title "shell"))
           (worktree
             (nerimux/model:make-worktree
              :id "wt-attention"
              :path "/repo/work"
              :branch "feature/attention"
              :dirty-p t
              :panes (list pane)))
           (repository
             (nerimux/model:make-repository
              :id "repo-attention"
              :specification "github.com/team/attention"
              :local-path "/repo"
              :worktrees (list worktree)))
           (organization
             (nerimux/model:make-organization
              :id "github.com/team"
              :host "github.com"
              :name "team"
              :repositories (list repository)))
           (output
             (progn
               (nerimux/model:worktree-add-pane worktree pane)
               (nerimux/model:pane-mark-output pane #(111 107))
               (nerimux/renderer:render-workspace-attention-to-tui-string
                (list organization)
                10
                100
                :selected-object pane))))
      (expect (search "ATTENTION" output))
      (expect (search "pane/8 shell" output))
      (expect (search "unread-output" output))
      (expect (search "j/k select Enter open" output))))

  (it "renders runtime recovery candidates as selectable attention items"
    (let* ((recovery-item
             (list :runtime-recovery-p t
                   :kind :orphan-pane
                   :label "runtime orphan-pane pane/8 shell"
                   :reasons '(:runtime-recovery :orphan-pane)))
           (output
             (nerimux/renderer:render-workspace-attention-to-tui-string
              nil
              10
              100
              :selected-object recovery-item
              :recovery-items (list recovery-item))))
      (expect (search "runtime orphan-pane pane/8 shell" output))
      (expect (search "runtime-recovery,orphan-pane" output))
      (expect (search ">! runtime orphan-pane" output))))

  ;; The estimator's own contract, at a scale small enough that this test is not
  ;; itself load-sensitive: SAMPLES is honoured and the reported figure is a
  ;; median over that many measured runs, taken after a discarded warm-up.
  (it "benchmark-workspace-overview-medians-over-the-requested-sample-count"
    (let ((result (nerimux/renderer:benchmark-workspace-overview
                   :organization-count 2
                   :repository-count 2
                   :worktree-count 4
                   :pane-count 4
                   :samples 3)))
      (expect (= 3 (getf result :sample-count)))
      (expect (integerp (getf result :initial-frame-ms)))
      (expect (integerp (getf result :scroll-frame-ms)))
      (expect (getf result :initial-frame-nonempty-p))
      (expect (getf result :scroll-frame-nonempty-p))))

  ;; The budget itself is unchanged at 100ms.  What changed is how the figure
  ;; reaching it is produced -- see benchmark-workspace-overview's docstring for
  ;; why a single unwarmed sample made this check report machine load.
  (it "keeps the mandatory overview scale within the initial and scroll budgets"
    (let ((result
            (nerimux/renderer:benchmark-workspace-overview
             :organization-count 1000
             :repository-count 1000
             :worktree-count 5000
             :pane-count 5000)))
      (expect (= 1000 (getf result :organization-count)))
      (expect (= 1000 (getf result :repository-count)))
      (expect (= 5000 (getf result :worktree-count)))
      (expect (= 5000 (getf result :pane-count)))
      (expect (= 7000 (getf result :tree-node-count)))
      (expect (= 12000 (getf result :item-count)))
      (expect (getf result :initial-frame-nonempty-p))
      (expect (getf result :scroll-frame-nonempty-p))
      (expect (<= (getf result :initial-frame-ms) 100))
      (expect (<= (getf result :scroll-frame-ms) 100)))))
