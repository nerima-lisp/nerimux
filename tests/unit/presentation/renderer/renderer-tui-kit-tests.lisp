(in-package #:nerimux/test)

(defun %expected-sgr-params (style)
  "The compound SGR parameter string CL-TUI-KIT/ANSI:ANSI-ENCODE-STYLE
   produces for STYLE, stripped of its ESC[ ... m envelope -- the form
   T/HELPERS-RENDER-OUTPUT.LISP's :TO-CONTAIN-SGR matcher expects.
   ANSI-ENCODE-STYLE always leads with reset code 0 and always emits both
   a foreground and a background code, so a bare code like \"31\" never
   appears in isolation in real output; deriving the expected compound
   string from the real encoder (rather than hand-computing SGR ordering)
   keeps these round-trip assertions honest about what CL-TUI-KIT actually
   emits."
  (let ((full (cl-tui-kit/ansi:ansi-encode-style style)))
    (subseq full 2 (1- (length full)))))

(describe "renderer-suite/tui-kit"

  (it "constructs the cl-tui-kit themes and frame area"
    (expect (typep
             (nerimux/renderer::%make-workspace-tree-theme)
             'cl-tui-kit/core:theme))
    (expect (typep
             (nerimux/renderer::%make-picker-panel-theme)
             'cl-tui-kit/core:theme))
    (let ((area (nerimux/renderer::%frame-area 12 40)))
      (expect (= 40 (cl-tui-kit/core:rectangle-width area)))
      (expect (= 12 (cl-tui-kit/core:rectangle-height area)))))

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

  ;; R6.9-frame-grid: %FRAME-GRID-PUT-CHAR used to advance the grid column
  ;; by 1 per CHARACTER regardless of display width, so during the
  ;; ANSI-frame round-trip every live frame goes through
  ;; (%SURFACE-FROM-ANSI-FRAME), a double-width glyph (CJK, most emoji --
  ;; NERIMUX/TERMINAL/TYPES:CHAR-WIDTH, the same measure %DISPLAY-WIDTH
  ;; uses) only consumed 1 grid column instead of 2. Anything written after
  ;; it in the same row with no intervening MOVE-TO -- e.g. the border glyph
  ;; %WRITE-PICKER-BOX-LINE appends right after a padded label -- landed one
  ;; column left of where the already-correct %DISPLAY-CLIP/%DISPLAY-WIDTH
  ;; text intended. "AA" (2 ASCII columns) and "あ" (1 character, 2 display
  ;; columns) must place a trailing "|" at the same raw grid index.
  (it "advances the frame-grid column by display width, not character count"
    (let* ((ascii-grid (nerimux/renderer::%ansi-frame-grid "AA|" 1 10))
           (wide-grid (nerimux/renderer::%ansi-frame-grid "あ|" 1 10)))
      (expect (= 2 (position #\| (nerimux/renderer::%frame-grid-row ascii-grid 0))))
      (expect (= 2 (position #\| (nerimux/renderer::%frame-grid-row wide-grid 0))))
      ;; The continuation sentinel sits between the glyph and the pipe, and
      ;; %frame-grid-text drops it so the flattened row hands the surface a
      ;; single wide character, not a synthetic filler that would double
      ;; count the column.
      (expect (char= (char (nerimux/renderer::%frame-grid-row wide-grid 0) 1)
                     nerimux/renderer::+frame-grid-continuation+))
      (expect (search "あ|" (nerimux/renderer::%frame-grid-text wide-grid)))))

  ;; Same fix, exercised through the full ANSI-frame -> surface round-trip
  ;; (%SURFACE-FROM-ANSI-FRAME) rather than the frame-grid internals
  ;; directly -- ground truth for what a client actually receives once
  ;; %SURFACE-TO-ANSI-FRAME re-serialises the surface.
  (it "keeps a trailing separator column-aligned across an ASCII and a wide-character row through the surface round-trip"
    (flet ((pipe-column (surface row cols)
             (loop for column from 0 below cols
                   when (string= "|" (cl-tui-kit/core:cell-content
                                       (cl-tui-kit/core:surface-cell
                                        surface column row)))
                     return column)))
      (let* ((ascii-surface
               (nerimux/renderer::%surface-from-ansi-frame
                (format nil "AA|~%BB|") 2 10))
             ;; #x1F468 (man) is confirmed width 2 by
             ;; tests/unit/domain/terminal/char-write-tests.lisp's
             ;; emoji-zwj-sequence-costs-no-extra-column test.
             (wide-surface
               (nerimux/renderer::%surface-from-ansi-frame
                (format nil "あ|~%~A|" (string (code-char #x1F468))) 2 10)))
        (expect (= (pipe-column ascii-surface 0 10) (pipe-column wide-surface 0 10)))
        (expect (= (pipe-column ascii-surface 1 10) (pipe-column wide-surface 1 10))))))

  ;; Regression test for the fix at the boundary every live frame crosses
  ;; (RENDER-SESSION-TO-TUI-STRING / RENDER-WORKSPACE-OVERVIEW-TO-TUI-STRING
  ;; both funnel ANSI-frame text through %SURFACE-FROM-ANSI-FRAME): a row
  ;; built the way %RENDER-CLIENT-PICKER and RENDER-WORKSPACE-OVERVIEW-TO-
  ;; STRING's `cell` helper both do it -- a label with a border glyph
  ;; appended right after via WRITE-CHAR, no MOVE-TO between them -- must
  ;; place that border in the same surface CELL column whether the label is
  ;; ASCII or a realistic mix of CJK, ASCII, and an emoji (generalizing
  ;; test 2's single-character case to a multi-character label, the shape
  ;; pane content and preview text actually take). (Note: cl-tui-kit's own
  ;; WIDGET rows -- the tree list and the C-p picker's cl-tui-kit-widget
  ;; box -- draw straight onto the surface via surface-draw-text, verified
  ;; separately as already display-width safe there; this is for the
  ;; ANSI-frame-TEXT rows that route through the frame-grid parse instead.)
  (it "keeps a border glyph cell-aligned through the surface round-trip when the preceding label mixes ASCII, CJK, and an emoji"
    (flet ((border-column (label)
             (let* ((row (format nil "~A|END" label))
                    (surface (nerimux/renderer::%surface-from-ansi-frame row 1 40)))
               (loop for column from 0 below 40
                     when (string= "|" (cl-tui-kit/core:cell-content
                                        (cl-tui-kit/core:surface-cell surface column 0)))
                       return column))))
      ;; "検証チーム" (5 CJK, 10 cols) + "main" (4 ASCII, 4 cols) +
      ;; man-emoji (1 char, 2 cols) = 16 columns before "|".
      (let ((mixed-label (format nil "検証チームmain~A" (string (code-char #x1F468)))))
        (expect (= 14 (border-column "AAAAAAAAAAAAAA")))
        (expect (= 16 (border-column mixed-label))))))

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
      ;; The label and value are drawn as separate styled spans (Dracula
      ;; accent label, default-style value) since the recolor wave, so an SGR
      ;; change now sits between them in the raw frame -- strip it first.
      (expect (search "repository: team/repo" (strip-sgr confirm-text)))
      (expect confirm-text :to-contain-sgr
              (%expected-sgr-params (nerimux/renderer::%confirm-view-key-style)))
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

  ;; Section-based overview redesign: a repository row under Repositories
  ;; defaults COLLAPSED (the opposite polarity from every other row, which
  ;; defaults expanded), so this widget-level smoke test needs REPOSITORY's
  ;; id marked in EXPANDED-NODE-IDS to see the worktree's branch label at
  ;; all -- see renderer-workspace-tree-tests.lisp for the direct unit
  ;; coverage of that contract.
  (it "renders the workspace hierarchy through the tree widget"
    (let* ((worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-tree"
              :path "/repo/work"
              :branch "feature/tree"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-tree"
              :specification "github.com/team/tree"
              :local-path "/repo"
              :worktrees (list worktree)))
           (organization
             (nerimux/workspace-model:make-organization
              :id "github.com/team"
              :host "github.com"
              :name "team"
              :repositories (list repository)))
           (expanded-node-ids
             (let ((table (make-hash-table :test #'equal)))
               (setf (gethash (list :repository "repo-tree") table) t)
               table)))
      (let ((output
              (nerimux/renderer:render-workspace-overview-to-tui-string
               (list organization)
               12
               100
               :selected-tree-object worktree
               :collapsed-node-ids nil
               :expanded-node-ids expanded-node-ids)))
        (expect (search "org" output))
        (expect (search "repo" output))
        (expect (search "feature/tree" output)))
      (let ((surface (nerimux/renderer::%surface-from-ansi-frame "" 12 100)))
        (nerimux/renderer::%render-workspace-tree-widget
         surface (list organization) 12 100 worktree 0
         :collapsed-node-ids nil
         :expanded-node-ids expanded-node-ids)
        (expect (search "feature/tree" (cl-tui-kit/core:surface-string surface))))))

  (it "renders the picker through input, list, form, and modal widgets"
    (let* ((worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-picker-widget"
              :path "/repo/work"
              :branch "feature/picker-widget"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-picker-widget"
              :specification "github.com/team/picker-widget"
              :local-path "/repo"
              :worktrees (list worktree)))
           (organization
             (nerimux/workspace-model:make-organization
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
        (expect (search "PICKER (literal)" output))
        (expect (search "feature/picker-widget" output)))
      (let ((non-string-query-surface
              (nerimux/renderer::%surface-from-ansi-frame "" 16 80)))
        (nerimux/renderer::%render-picker-widget
         non-string-query-surface 16 80 items 42 0 nil)
        (expect (search "42" (cl-tui-kit/core:surface-string
                               non-string-query-surface))))))

  (it "routes client picker mode through the public tui renderer"
    (let ((output
            (nerimux/renderer:render-session-to-tui-string
             (nerimux/session:make-session :id 22 :name "picker")
             16
             80
             :mode :picker
             :picker-query "missing")))
      (expect (search "PICKER (literal)" output))
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

  ;; PR2 one-column redesign: the WORKTREES/PANES/PREVIEW three-column layout
  ;; ("PANES" header, "u:!" per-pane status token) is gone -- the tree is now
  ;; the overview's only panel, and a selected pane's detail shows through
  ;; the 2-line detail strip below the tree instead (renderer-workspace.lisp
  ;; DETAIL-LINES). Selecting the pane directly (:selected-tree-object, not
  ;; just :focus-pane -- which only resolves down to the pane's WORKTREE, see
  ;; RENDER-WORKSPACE-OVERVIEW-TO-STRING's SELECTED-OBJECT) is what reaches
  ;; the pane branch of DETAIL-LINES rather than the worktree branch.
  (it "renders the bare repository overview with pane attention and detail"
    (let* ((pane (nerimux/pane:make-pane :id 7 :title "editor"))
           (window (nerimux/window:make-window :id 1 :name "w" :panes (list pane)))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt"
              :path "/repo/work"
              :branch "feature/ui"
              :panes (list pane)))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo"
              :specification "github.com/team/repo"
              :local-path "/repo"
              :worktrees (list worktree)))
           (organization
             (nerimux/workspace-model:make-organization
              :id "github.com/team"
              :host "github.com"
              :name "team"
              :repositories (list repository)))
           (output
             (progn
               (setf (nerimux/pane:pane-window pane) window)
               (nerimux/pane:worktree-add-pane worktree pane)
               (nerimux/pane:pane-mark-output
                pane (map 'vector #'char-code "hello-pane"))
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization)
                12
                100
                :selected-tree-object pane
                :focus-pane pane))))
      (expect (search " nerimux " output))
      (expect (search "github.com/team" output))
      ;; The overview tree no longer emits pane rows at all (a later wave
      ;; adds inline pane detail); WORKTREE's own row carries the `!`
      ;; attention mark instead -- PANE-MARK-OUTPUT set UNREAD-OUTPUT-P,
      ;; which WORKTREE-ATTENTION-REASONS rolls up via PANE-ATTENTION-P, so
      ;; the worktree itself needs attention and shows under the Attention
      ;; section with its "org/repo · branch" label, "feature/ui" included.
      (expect (search "! github.com/team/repo · feature/ui" (strip-sgr output)))
      ;; The detail strip shows the selected pane's label and its last
      ;; output text verbatim, not the old "output: " status-bar phrasing.
      (expect (search "pane: pane/7 editor" (strip-sgr output)))
      (expect (search "hello-pane" (strip-sgr output)))))

  ;; R-style-preservation: every SGR the source frame carries -- standard
  ;; and bright colors, 256-indexed and truecolor extended forms,
  ;; attributes, and their off codes -- used to be dropped by
  ;; %SURFACE-FROM-ANSI-FRAME (it parsed a characters-only grid and drew it
  ;; with %SURFACE-DRAW-TEXT's default style), so every client saw a
  ;; monochrome UI regardless of what the ANSI source frame specified.
  ;; These tests assert styles survive the ANSI-frame -> surface ->
  ;; ANSI-backend round trip.

  (it "carries a red foreground SGR through the full ANSI backend round trip"
    (let* ((escape (string (code-char 27)))
           (frame (concatenate 'string escape "[31m" "RED" escape "[0m"))
           (output (nerimux/renderer::%render-ansi-frame-with-tui-kit frame 10 40))
           (expected (%expected-sgr-params
                      (cl-tui-kit/core:make-style
                       :foreground (cl-tui-kit/core:named-color :red)))))
      (expect output :to-contain-sgr expected)))

  (it "carries 256-indexed and truecolor SGR forms through the full ANSI backend round trip"
    (let* ((escape (string (code-char 27)))
           (fg-frame (concatenate 'string escape "[38;5;111m" "X" escape "[0m"))
           (fg-output (nerimux/renderer::%render-ansi-frame-with-tui-kit fg-frame 10 40))
           (expected-fg (%expected-sgr-params
                         (cl-tui-kit/core:make-style
                          :foreground (cl-tui-kit/core:indexed-color 111))))
           (bg-frame (concatenate 'string escape "[48;2;10;20;30m" "X" escape "[0m"))
           (bg-output (nerimux/renderer::%render-ansi-frame-with-tui-kit bg-frame 10 40))
           (expected-bg (%expected-sgr-params
                         (cl-tui-kit/core:make-style
                          :background (cl-tui-kit/core:rgb-color 10 20 30)))))
      (expect fg-output :to-contain-sgr expected-fg)
      (expect bg-output :to-contain-sgr expected-bg)))

  (it "carries bright (90-97/100-107) named colors as CL-TUI-KIT indexed 8-15"
    (let* ((escape (string (code-char 27)))
           (frame (concatenate 'string escape "[91;104m" "X"))
           (surface (nerimux/renderer::%surface-from-ansi-frame frame 1 10))
           (style (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 0 0)))
           (expected (cl-tui-kit/core:make-style
                      :foreground (cl-tui-kit/core:indexed-color 9)
                      :background (cl-tui-kit/core:indexed-color 12))))
      (expect (cl-tui-kit/core:style= style expected))))

  (it "bounds a styled run at a reset code, leaving trailing text at default style"
    (let* ((escape (string (code-char 27)))
           (frame (concatenate 'string escape "[1;4;7m" "AB" escape "[0m" "CD"))
           (surface (nerimux/renderer::%surface-from-ansi-frame frame 1 10))
           (styled-a (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 0 0)))
           (styled-b (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 1 0)))
           (plain-c (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 2 0)))
           (expected-styled (cl-tui-kit/core:make-style :bold t :underline t :reverse t)))
      (expect (cl-tui-kit/core:style= styled-a expected-styled))
      (expect (cl-tui-kit/core:style= styled-b expected-styled))
      (expect (cl-tui-kit/core:style= plain-c (cl-tui-kit/core:make-style)))))

  (it "turns off bold/dim, underline, and reverse independently via SGR 22/24/27"
    (let* ((escape (string (code-char 27)))
           (frame (concatenate 'string escape "[1;4;7m" "AB" escape "[22;24;27m" "CD"))
           (surface (nerimux/renderer::%surface-from-ansi-frame frame 1 10))
           (before (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 0 0)))
           (after (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 2 0))))
      (expect (cl-tui-kit/core:style=
               before (cl-tui-kit/core:make-style :bold t :underline t :reverse t)))
      (expect (cl-tui-kit/core:style= after (cl-tui-kit/core:make-style)))))

  ;; Generalizes the existing display-width alignment tests above (line
  ;; ~111 and ~128) to a styled run: the wide character's column layout
  ;; must be unaffected by carrying a style, and the style itself must
  ;; reach both the lead cell and (indirectly, via SURFACE-PUT-CELL) the
  ;; wide glyph's continuation cell.
  (it "keeps column alignment and per-cell style intact when a styled run includes a wide character"
    (let* ((escape (string (code-char 27)))
           (frame (concatenate 'string escape "[32m" "AAあ|" escape "[0m"))
           (surface (nerimux/renderer::%surface-from-ansi-frame frame 1 10))
           (green (cl-tui-kit/core:make-style
                   :foreground (cl-tui-kit/core:named-color :green))))
      (expect (string= "|" (cl-tui-kit/core:cell-content
                             (cl-tui-kit/core:surface-cell surface 4 0))))
      (expect (cl-tui-kit/core:style=
               green (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 0 0))))
      (expect (cl-tui-kit/core:style=
               green (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 2 0))))
      (expect (cl-tui-kit/core:style=
               green (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 4 0))))))

  (it "adds no SGR beyond the default reset for unstyled input"
    (let ((surface (nerimux/renderer::%surface-from-ansi-frame "hello" 1 10))
          (default (cl-tui-kit/core:make-style)))
      (dotimes (column 10)
        (expect (cl-tui-kit/core:style=
                 default
                 (cl-tui-kit/core:cell-style
                  (cl-tui-kit/core:surface-cell surface column 0)))))))

  (it "carries the active background across an EL line erase (BCE)"
    (let* ((escape (string (code-char 27)))
           (frame (concatenate 'string escape "[44m" escape "[2K"))
           (surface (nerimux/renderer::%surface-from-ansi-frame frame 1 10))
           (style (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 0 0)))
           (expected (cl-tui-kit/core:make-style
                      :background (cl-tui-kit/core:named-color :blue))))
      (expect (cl-tui-kit/core:style= style expected))))

  (it "carries the active background across an ED display erase (BCE)"
    (let* ((escape (string (code-char 27)))
           (frame (concatenate 'string escape "[44m" escape "[2J"))
           (surface (nerimux/renderer::%surface-from-ansi-frame frame 2 10))
           (expected (cl-tui-kit/core:make-style
                      :background (cl-tui-kit/core:named-color :blue))))
      (expect (cl-tui-kit/core:style=
               expected
               (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 0 0))))
      (expect (cl-tui-kit/core:style=
               expected
               (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell surface 5 1))))))

  ;; Same fixture shape as "applies the client viewport through the widget
  ;; path" above: two colored lines plus a third that overwrites row 1 when
  ;; VIEWPORT=0 clamps the cursor row (CONTENT-HEIGHT=ROWS there), and lands
  ;; on its own row when VIEWPORT=1 gives the parse a third grid row to
  ;; write into.  Only row 0 of each result is asserted, which is
  ;; unambiguous under both behaviors.
  (it "keeps per-row style intact through the viewport window"
    (let* ((escape (string (code-char 27)))
           (frame (concatenate
                   'string
                   escape "[31m" "line-0" escape "[0m" (string #\Newline)
                   escape "[32m" "line-1" escape "[0m" (string #\Newline)
                   "line-2"))
           (top (nerimux/renderer::%surface-from-ansi-frame frame 2 10 :viewport 0))
           (scrolled (nerimux/renderer::%surface-from-ansi-frame frame 2 10 :viewport 1))
           (red (cl-tui-kit/core:make-style :foreground (cl-tui-kit/core:named-color :red)))
           (green (cl-tui-kit/core:make-style
                   :foreground (cl-tui-kit/core:named-color :green))))
      (expect (search "line-0" (cl-tui-kit/core:surface-string top)))
      (expect (cl-tui-kit/core:style=
               red (cl-tui-kit/core:cell-style (cl-tui-kit/core:surface-cell top 0 0))))
      (expect (search "line-1" (cl-tui-kit/core:surface-string scrolled)))
      (expect (not (search "line-0" (cl-tui-kit/core:surface-string scrolled))))
      (expect (cl-tui-kit/core:style=
               green (cl-tui-kit/core:cell-style
               (cl-tui-kit/core:surface-cell scrolled 0 0))))))

  (it "handles SGR extended colors and erase-background style semantics"
    (let ((default (nerimux/renderer::%default-style)))
      (multiple-value-bind (color consumed)
          (nerimux/renderer::%sgr-extended-color #(38 5 300) 0 3)
        (expect (= 3 consumed))
        (expect (cl-tui-kit/core:color= color
                                       (cl-tui-kit/core:indexed-color 255))))
      (multiple-value-bind (color consumed)
          (nerimux/renderer::%sgr-extended-color #(48 2 -1 300 7) 0 5)
        (expect (= 5 consumed))
        (expect (cl-tui-kit/core:color= color
                                       (cl-tui-kit/core:rgb-color 0 255 7))))
      (multiple-value-bind (color consumed)
          (nerimux/renderer::%sgr-extended-color #(38 5) 0 2)
        (expect (null color))
        (expect (= 2 consumed)))
      (let* ((blue (cl-tui-kit/core:make-style
                    :background (cl-tui-kit/core:named-color :blue)
                    :bold t))
             (erased (nerimux/renderer::%bce-style blue))
             (applied (nerimux/renderer::%frame-grid-apply-sgr default '(38 5 42 48 2 1 2 3))))
        (expect (cl-tui-kit/core:color=
                 (cl-tui-kit/core:style-background erased)
                 (cl-tui-kit/core:named-color :blue)))
        (expect (not (cl-tui-kit/core:style-bold erased)))
        (expect (cl-tui-kit/core:color=
                 (cl-tui-kit/core:style-foreground applied)
                 (cl-tui-kit/core:indexed-color 42)))
        (expect (cl-tui-kit/core:color=
                 (cl-tui-kit/core:style-background applied)
                 (cl-tui-kit/core:rgb-color 1 2 3)))))))
