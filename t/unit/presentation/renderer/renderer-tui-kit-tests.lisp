(in-package #:nerimux/test)

(describe "renderer-suite/tui-kit"

  (it "covers ANSI frame-grid state transitions"
    (let* ((escape (code-char 27))
           (grid (nerimux/renderer::%make-frame-grid 3 6)))
      (expect (equal '(2 0 0)
                     (nerimux/renderer::%frame-grid-params "?2;;bad")))
      (expect (= 9 (nerimux/renderer::%frame-grid-param '(nil 7) 0 9)))
      (expect (= 7 (nerimux/renderer::%frame-grid-param '(2 7) 1 9)))
      (setf (char (aref grid 0) 0) #\x
            (char (aref grid 0) 1) #\x
            (char (aref grid 0) 2) #\x)
      (nerimux/renderer::%frame-grid-clear-line (aref grid 0) 1 1)
      (expect (string= "  x   " (aref grid 0)))
      (nerimux/renderer::%frame-grid-clear-line (aref grid 0) 0 2)
      (expect (string= "      " (aref grid 0)))
      (setf (char (aref grid 0) 0) #\x
            (char (aref grid 0) 1) #\x
            (char (aref grid 0) 2) #\x)
      (nerimux/renderer::%frame-grid-clear-line (aref grid 0) 2 2)
      (expect (string= "      " (aref grid 0)))
      (multiple-value-bind (row col saved-row saved-col)
          (nerimux/renderer::%frame-grid-apply-csi
           grid 1 2 1 3 '(0) #\A)
        (expect (= 0 row))
        (expect (= 2 col))
        (expect (= 1 saved-row))
        (expect (= 3 saved-col)))
      (nerimux/renderer::%frame-grid-apply-csi grid 0 0 0 0 '(0) #\B)
      (nerimux/renderer::%frame-grid-apply-csi grid 2 2 0 0 '(2) #\A)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(0) #\C)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(2) #\D)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(3) #\G)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(2) #\d)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(2 3) #\H)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(1 2) #\f)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(1) #\J)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(2) #\J)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(1) #\K)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(2) #\K)
      (nerimux/renderer::%frame-grid-apply-csi grid 1 1 0 0 '(0) #\K)
      (multiple-value-bind (row col saved-row saved-col)
          (nerimux/renderer::%frame-grid-apply-csi
           grid 2 4 0 0 nil #\s)
        (multiple-value-bind (restored-row restored-col)
            (nerimux/renderer::%frame-grid-apply-csi
             grid 0 0 saved-row saved-col nil #\u)
          (expect (= 2 row))
          (expect (= 4 col))
          (expect (= 2 restored-row))
          (expect (= 4 restored-col))))
      (expect (= 1 (nerimux/renderer::%frame-grid-put-char grid 0 0 #\A)))
      (expect (char= #\A (char (aref grid 0) 0)))
      (expect (= 0 (nerimux/renderer::%frame-grid-put-char grid 0 5 #\B)))
      (expect (= 0 (nerimux/renderer::%frame-grid-put-char grid 0 6 #\C)))
      (expect (= 1 (nerimux/renderer::%frame-grid-put-char grid -1 0 #\D)))
      (multiple-value-bind (index row col saved-row saved-col)
          (nerimux/renderer::%frame-grid-parse-csi
           "2;3Htail" 0 grid 0 0 0 0)
        (expect (= 4 index))
        (expect (= 1 row))
        (expect (= 2 col))
        (expect (= 0 saved-row))
        (expect (= 0 saved-col)))
      (multiple-value-bind (index row col saved-row saved-col)
          (nerimux/renderer::%frame-grid-parse-csi
           "2" 0 grid 0 0 0 0)
        (expect (= 1 index))
        (expect (= 0 row))
        (expect (= 0 col))
        (expect (= 0 saved-row))
        (expect (= 0 saved-col)))
      (expect (= 6 (nerimux/renderer::%frame-grid-skip-osc
                    (format nil "title~C" (code-char 7)) 0)))
      (expect (= 7 (nerimux/renderer::%frame-grid-skip-osc
                    (format nil "title~C\\" escape) 0)))
      (expect (= 5 (nerimux/renderer::%frame-grid-skip-osc "title" 0)))
      (let ((frame
              (concatenate
               'string
               "A"
               (string #\Newline)
               "B"
               (string #\Return)
               (string #\Backspace)
               (string #\Tab)
               (string (code-char 1))
               (string escape) "[2J"
               (string escape) "]title" (string (code-char 7))
               (string escape) "]st" (string escape) "\\"
               (string escape) "x"
               (string escape))))
        (expect (not (search "A" (nerimux/renderer::%frame-grid-text
                                   (nerimux/renderer::%ansi-frame-grid frame 3 6))))))
      (nerimux/renderer::%clear-frame-grid grid)
      (expect (string= "      " (nerimux/renderer::%frame-grid-row grid 0)))))

  (it "renders terminal-size and confirm-view boundaries"
    (expect (nerimux/renderer::%terminal-too-small-p 9 40))
    (expect (nerimux/renderer::%terminal-too-small-p 10 39))
    (expect (not (nerimux/renderer::%terminal-too-small-p 10 40)))
    (let* ((warning
             (nerimux/renderer::%render-terminal-too-small-surface 10 40))
           (warning-text (cl-tui-kit/core:surface-string warning))
           (confirm
             (nerimux/renderer::make-confirm-view
              :operation "WORKTREE DELETE"
              :fields '(("repository" . "team/repo")
                        ("worktree" . "feature/ui"))
              :prompt-p t))
           (failure
             (nerimux/renderer::make-confirm-view
              :operation "OPERATION FAILED"
              :fields '(("reason" . "not found"))
              :prompt-p nil))
           (confirm-text
             (nerimux/renderer::render-confirm-view-to-tui-string
              confirm 10 40))
           (failure-text
             (nerimux/renderer::render-confirm-view-to-tui-string
              failure 10 40)))
      (expect (search "terminal too small" warning-text))
      (expect (search "WORKTREE DELETE" confirm-text))
      (expect (search "repository: team/repo" confirm-text))
      (expect (search "y execute" confirm-text))
      (expect (search "OPERATION FAILED" failure-text))
      (expect (search "press any key to continue" failure-text))))

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

  ;; 40x10 is the minimum the frame renderer will draw content at (R6.10);
  ;; below it every frame is the too-small warning, so a smaller size here
  ;; would test the guard instead of the backend round-trip.
  (it "presents a complete frame through a fresh ANSI backend"
    (let ((output
            (nerimux/renderer::%render-ansi-frame-with-tui-kit
             "hello"
             10
             40)))
      (expect (search "hello" output))
      (expect (search (string (code-char 27)) output))))

  ;; R6.3 collapse-by-default: the tree's default state shows only
  ;; organization rows (see renderer-workspace-tree-tests.lisp for the direct
  ;; unit coverage of that contract), so this widget-level smoke test must
  ;; pass EXPANDED-NODE-IDS with the organization and repository rows marked
  ;; expanded to see the worktree's branch label at all -- otherwise this
  ;; would silently stop testing the tree widget's worktree rendering the
  ;; moment collapse-by-default shipped, while still nominally passing on
  ;; the header text alone.
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
           (expanded (make-hash-table :test #'equal)))
      (setf (gethash (list :organization "github.com/team") expanded) t)
      (setf (gethash (list :repository "repo-tree") expanded) t)
      (let ((output
              (nerimux/renderer:render-workspace-overview-to-tui-string
               (list organization)
               12
               100
               :selected-tree-object worktree
               :expanded-node-ids expanded)))
        (expect (search "org" output))
        (expect (search "repo" output))
        (expect (search "feature/tree" output)))))

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

  (it "joins frame rows with CR+LF so a raw-mode tty never sees a bare LF"
    ;; The client's tty runs with OPOST off, so the terminal receives the
    ;; frame bytes verbatim: a bare #\Newline moves down without returning
    ;; the column, staircasing every full-width row and scrolling the top of
    ;; the frame off the screen.  Every emulator in the test stack (pyte
    ;; drivers, %ansi-frame-grid) implicitly treats LF as CR+LF, which is
    ;; how the defect shipped invisibly -- so assert on the raw bytes here,
    ;; not through any screen model.
    (let* ((surface (cl-tui-kit/core:make-surface 10 3))
           (output (nerimux/renderer::%surface-to-ansi-frame surface))
           (newlines 0))
      (loop for index from 0 below (length output)
            when (char= (char output index) #\Newline)
              do (incf newlines)
                 (expect (and (plusp index)
                              (char= (char output (1- index)) #\Return))))
      (expect (= 2 newlines))))

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
      (expect (search "output: ok" output)))))
