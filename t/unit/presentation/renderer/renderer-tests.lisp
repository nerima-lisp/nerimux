(in-package #:nerimux/test)

;;;; render-status-bar, render-session, clear-display, and status-pane indicators
;;;;
;;;; status-format[0] (domain/options + domain/format, deleted R2.2/R2.3) is
;;;; gone: the status bar is now always composed procedurally (left/window-
;;;; list/right), never expanded from a template — see renderer-statusbar.lisp.

;;; ── Test fixtures ───────────────────────────────────────────────────────────
;;;
;;; make-renderer-test-session is defined in t/helpers-renderer-fixtures.lisp
;;; and shared across renderer-tests.lisp and renderer-pane-tests.lisp.

(defun make-split-session (w h orient)
  "A 1-window session split into two panes (fd -1, no PTY).
   ORIENT is :h (side-by-side left|right) or :v (stacked top/bottom).
   The FIRST pane is active."
  (let* ((s0 (make-screen w h))
         (s1 (make-screen w h))
         (p0 (make-pane :id 1 :x 0 :y 0 :width w :height h :fd -1 :screen s0))
         (p1 (if (eq orient :h)
                 (make-pane :id 2 :x (1+ w) :y 0     :width w :height h :fd -1 :screen s1)
                 (make-pane :id 2 :x 0       :y (1+ h) :width w :height h :fd -1 :screen s1)))
         (total-w (if (eq orient :h) (+ (* 2 w) 1) w))
         (total-h (if (eq orient :h) h (+ (* 2 h) 1)))
         (win (make-window :id 1 :name "1"
                           :width  total-w
                           :height total-h
                           :tree (make-layout-split orient
                                    (make-layout-leaf p0)
                                    (make-layout-leaf p1)
                                    1/2)
                           :panes (list p0 p1)))
         (sess (make-session :id 1 :name "0" :windows (list win))))
    (window-select-pane win p0)
    (session-select-window sess win)
    sess))

(defun make-renderer-picker-items ()
  (let* ((organization
           (nerimux/model:make-organization
            :id "org" :host "github.com" :name "team"))
         (repository
           (nerimux/model:make-repository
            :id "repo"
            :organization organization
            :specification "github.com/team/repo"))
         (worktree
           (nerimux/model:make-worktree
            :id "feature"
            :repository repository
            :path "/tmp/feature"
            :branch "feature/picker"
            :dirty-p t))
         (pane
           (nerimux/model:make-pane
            :id 7
            :title "editor"
            :start-command "nvim"
            :start-path "/tmp/feature")))
    (nerimux/model:organization-add-repository organization repository)
    (nerimux/model:repository-add-worktree repository worktree)
    (nerimux/model:worktree-add-pane worktree pane)
    (nerimux/picker:build-global-picker-items (list organization))))

(describe "renderer-suite"

  ;;; ── render-status-bar ───────────────────────────────────────────────────────

  ;; render-status-bar draws something for a session with no worktree (R6.5:
  ;; the middle block's window/pane tabs only appear for a focus pane that
  ;; has one — make-renderer-test-session's pane does not, so this only
  ;; checks the bar renders at all, not any window-index:name text).
  (it "render-status-bar-shows-names"
    (let* ((sess (make-renderer-test-session 40 10 :content ""))
           (out  (render-status-bar-output sess 10 40)))
      (expect (search "0" out))))

  ;; %compose-aligned-line places #[align=right] content flush-right and
  ;; #[align=centre] content centred, filling to the requested width.
  (it "compose-aligned-line-positions-regions"
    ;; cl-regex-kit:replace-all takes a COMPILED regex (there is no string
    ;; overload), so the pattern is compiled once outside the flet rather than
    ;; per call as cl-ppcre's string-accepting regex-replace-all allowed.
    (let ((sgr (cl-regex-kit:compile-regex (format nil "~C\\[[0-9;]*m" #\Escape))))
      (flet ((vis (s) (cl-regex-kit:replace-all sgr s ""))
             (compose (spec) (nerimux/renderer::%compose-aligned-line spec "" 10)))
        (expect (string= "AB      CD" (vis (compose "AB#[align=right]CD"))))
        (expect (string= "    XX    " (vis (compose "#[align=centre]XX"))))
        (expect (= 10 (nerimux/renderer::%visible-length
                       (compose "L#[align=centre]C#[align=right]R")))))))

  ;; The status bar does not show a COPY/offset indicator when a pane is in copy mode.
  (it "render-status-bar-copy-mode-has-no-indicator"
    (let* ((sess   (make-renderer-test-session 60 10 :content ""))
           (ap     (session-active-pane sess))
           (screen (pane-screen ap)))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-offset screen) 3)
      (let ((out (render-status-bar-output sess 10 60)))
        (expect (null (search "COPY" out)))
        (expect (null (search "+3" out))))))

  ;; The status bar never shows a COPY indicator for a pane that is not in copy mode.
  (it "render-status-bar-no-copy-indicator-live"
    (let* ((sess (make-renderer-test-session 60 10 :content ""))
           (out  (render-status-bar-output sess 10 60)))
      (expect (not (search "COPY" out)))))

  ;; On a narrow terminal, the status bar's visible content is clamped to the terminal width.
  (it "render-status-bar-truncates-long-line"
    ;; A very narrow terminal forces the status line to be truncated.
    ;; The bar is: move-to, ESC[<base>m, <status content + padding>, ESC[0m.
    ;; The content between the base SGR and the trailing reset may embed
    ;; further zero-width SGR wraps (branch/state colouring), so it is
    ;; measured in VISIBLE cells: truncation plus background padding fill the
    ;; row to exactly the terminal width, never past it.
    (let* ((width  8)
           (sess   (make-renderer-test-session width 10 :content ""))
           (out    (render-status-bar-output sess 10 width))
           (color  (format nil "~C[~Am" #\Escape
                           nerimux/renderer::+sgr-default-status+))
           (reset  (format nil "~C[0m" #\Escape))
           (start  (+ (search color out) (length color)))
           (end    (search reset out :start2 start))
           (content (subseq out start end)))
      (expect (= width (nerimux/renderer::%visible-length content)))))

  ;;; ── render-session-to-string (full frame) ───────────────────────────────────

  ;; render-session-to-string emits pane content plus cursor-hide/show sequences and the status bar.
  (it "render-session-to-string-full-frame"
    (let* ((sess (make-renderer-test-session 20 5 :content "hi"))
           (out  (render-session-to-string sess 6 20)))
      (expect (find #\h out))
      (expect (find #\i out))
      (expect (search (format nil "~C[?25l" #\Escape) out))
      (expect (search (format nil "~C[?25h" #\Escape) out))))

  ;; A side-by-side split renders a vertical separator, highlights the active pane's border, and shows both panes' content.
  (it "render-session-vertical-split-emits-separators"
    (let* ((sess  (make-split-session 5 3 :h))
           (win   (session-active-window sess))
           (panes (window-panes win))
           (accent (format nil "~C[~Am" #\Escape
                           nerimux/renderer::+sgr-active-border+)))
      (feed (pane-screen (first  panes)) "AAA")
      (feed (pane-screen (second panes)) "BBB")
      (let ((out (render-session-to-string sess 3 11)))   ; full width = 2*5+1
        (expect (find (code-char #x2502) out))
        ;; pane 0 is active and non-last, so its right border is highlighted.
        (expect (search accent out))
        (expect (find #\A out))
        (expect (find #\B out)))))

  ;; A stacked (top/bottom) split renders a horizontal separator and shows both panes' content.
  (it "render-session-horizontal-split-emits-separators"
    (let* ((sess  (make-split-session 5 3 :v))
           (win   (session-active-window sess))
           (panes (window-panes win)))
      (feed (pane-screen (first  panes)) "AAA")
      (feed (pane-screen (second panes)) "BBB")
      (let ((out (render-session-to-string sess 7 5)))    ; full height = 2*3+1
        (expect (find (code-char #x2500) out))
        (expect (find #\A out))
        (expect (find #\B out)))))

  ;; In render-session-to-string the vertical separator is drawn only when the
  ;; border column is strictly inside the terminal width.  A split whose first
  ;; pane's right edge lands exactly at terminal-cols suppresses the │ bar.
  (it "render-session-vertical-border-suppressed-at-edge"
    (let* ((sess  (make-split-session 5 3 :h))
           (win   (session-active-window sess))
           (panes (window-panes win)))
      (feed (pane-screen (first  panes)) "AAA")
      (feed (pane-screen (second panes)) "BBB")
      ;; First pane is x=0 width=5, so its border column is 5.  Render with
      ;; terminal-cols=5 → (< 5 5) is false → the vertical border is suppressed.
      (let ((out (render-session-to-string sess 3 5)))
        (expect (null (find (code-char #x2502) out))))))

  (it "render-session-picker-overlay-renders-hierarchy-and-attention"
    (let* ((items (make-renderer-picker-items))
           (out (render-session-to-string
                 (make-renderer-test-session 40 8)
                 12 60
                 :mode :picker
                 :picker-items items
                 :picker-query "team"
                 :picker-index 1
                 :picker-regex-p t)))
      (expect (search "regex query: team" out))
      (expect (search "github.com/team" out))
      (expect (search "github.com/team/repo" out))
      (expect (search "feature/picker" out))
      (expect (search "pane/7 editor" out))
      (expect (search (format nil "~C[7m" #\Escape) out))
      (expect (search (format nil "~C[33m" #\Escape) out))))

  (it "render-session-picker-overlay-shows-empty-results"
    (let ((out (render-session-to-string
                (make-renderer-test-session 20 5)
                10 40
                :mode :picker
                :picker-query "missing")))
      (expect (search "no matches" out))))

  (it "render-client-picker-skips-an-undisplayable-terminal"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-client-picker
       stream 4 11 (make-renderer-picker-items) "" 0)
      (expect (string= "" (get-output-stream-string stream)))))

  (it "render-session-command-overlay-renders-and-clips-the-tail"
    (let ((out (render-session-to-string
                (make-renderer-test-session 20 5)
                8 24
                :mode :command
                :command-buffer "status")))
      ;; The `:` prompt carries its own accent SGR, so the visible text is
      ;; checked with escapes stripped.
      (expect (search ":status" (strip-sgr out))))
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-client-command-line
       stream 3 8 "abcdefghij")
      (let ((out (get-output-stream-string stream)))
        (expect (search "cdefghij" out)))))

  (it "render-client-command-line-rejects-invalid-dimensions-and-input"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-client-command-line stream 0 10 "x")
      (nerimux/renderer::%render-client-command-line stream 5 0 "x")
      (nerimux/renderer::%render-client-command-line stream 5 10 nil)
      (expect (string= "" (get-output-stream-string stream)))))

  ;;; ── clear-display ───────────────────────────────────────────────────────────

  ;; clear-display writes the ANSI erase-screen (ESC[2J) and cursor-home (ESC[H) sequences.
  (it "clear-display-emits-clear-and-home"
    (let ((out (let ((*standard-output* (make-string-output-stream)))
                 (clear-display)
                 (get-output-stream-string *standard-output*))))
      (expect (search (format nil "~C[2J" #\Escape) out))
      (expect (search (format nil "~C[H" #\Escape) out)))))
