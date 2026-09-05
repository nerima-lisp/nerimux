(in-package #:nerimux/test/renderer)

(defun make-split-session (w h orient)
  "A 1-window session split into two panes (fd -1, no PTY).
   ORIENT is :h (side-by-side left|right) or :v (stacked top/bottom).
   The FIRST pane is active."
  (let* ((s0 (make-screen w h))
         (s1 (make-screen w h))
         (p0 (make-pane :id 1 :x 0 :y 0 :width w :height h :fd -1 :screen s0))
         (p1
          (if (eq orient :h)
              (make-pane :id
                         2
                         :x
                         (1+ w)
                         :y
                         0
                         :width
                         w
                         :height
                         h
                         :fd
                         -1
                         :screen
                         s1)
              (make-pane :id
                         2
                         :x
                         0
                         :y
                         (1+ h)
                         :width
                         w
                         :height
                         h
                         :fd
                         -1
                         :screen
                         s1)))
         (total-w
          (if (eq orient :h)
              (+ (* 2 w) 1)
              w))
         (total-h
          (if (eq orient :h)
              h
              (+ (* 2 h) 1)))
         (win
          (make-window :id
                       1
                       :name
                       "1"
                       :width
                       total-w
                       :height
                       total-h
                       :tree
                       (make-layout-split orient
                                          (make-layout-leaf p0)
                                          (make-layout-leaf p1)
                                          1/2)
                       :panes
                       (list p0 p1)))
         (sess (make-session :id 1 :name "0" :windows (list win))))
    (window-select-pane win p0)
    (session-select-window sess win)
    sess))

(defun make-renderer-picker-items ()
  (let* ((organization
          (nerimux/workspace-model:make-organization :id
                                                     "org"
                                                     :host
                                                     "github.com"
                                                     :name
                                                     "team"))
         (repository
          (nerimux/workspace-model:make-repository :id
                                                   "repo"
                                                   :organization
                                                   organization
                                                   :specification
                                                   "github.com/team/repo"))
         (worktree
          (nerimux/workspace-model:make-worktree :id
                                                 "feature"
                                                 :repository
                                                 repository
                                                 :path
                                                 "/tmp/feature"
                                                 :branch
                                                 "feature/picker"
                                                 :dirty-p
                                                 t))
         (pane
          (nerimux/pane:make-pane :id
                                  7
                                  :title
                                  "editor"
                                  :start-command
                                  "nvim"
                                  :start-path
                                  "/tmp/feature")))
    (nerimux/workspace-model:organization-add-repository organization
                                                         repository)
    (nerimux/workspace-model:repository-add-worktree repository worktree)
    (nerimux/pane:worktree-add-pane worktree pane)
    (nerimux/picker:build-global-picker-items (list organization))))

(describe "renderer-suite"


  (it "render-status-bar-shows-names"
    (let* ((sess (make-renderer-test-session 40 10 :content ""))
           (out  (render-status-bar-output sess 10 40)))
      (expect (search "0" out))))

  (it "compose-aligned-line-positions-regions"
    (let ((sgr (cl-regex-kit:compile-regex (format nil "~C\\[[0-9;]*m" #\Escape))))
      (flet ((vis (s) (cl-regex-kit:replace-all sgr s ""))
             (compose (spec) (nerimux/renderer::%compose-aligned-line spec "" 10)))
        (expect (string= "AB      CD" (vis (compose "AB#[align=right]CD"))))
        (expect (string= "    XX    " (vis (compose "#[align=centre]XX"))))
        (expect (= 10 (nerimux/renderer::%visible-length
                       (compose "L#[align=centre]C#[align=right]R")))))))

  (it "render-status-bar-copy-mode-has-no-indicator"
    (let* ((sess   (make-renderer-test-session 60 10 :content ""))
           (ap     (session-active-pane sess))
           (screen (pane-screen ap)))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-offset screen) 3)
      (let ((out (render-status-bar-output sess 10 60)))
        (expect (null (search "COPY" out)))
        (expect (null (search "+3" out))))))

  (it "render-status-bar-no-copy-indicator-live"
    (let* ((sess (make-renderer-test-session 60 10 :content ""))
           (out  (render-status-bar-output sess 10 60)))
      (expect (not (search "COPY" out)))))

  (it "render-status-bar-truncates-long-line"
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


  (it "render-session-to-string-full-frame"
    (let* ((sess (make-renderer-test-session 20 5 :content "hi"))
           (out  (render-session-to-string sess 6 20)))
      (expect (find #\h out))
      (expect (find #\i out))
      (expect (search (format nil "~C[?25l" #\Escape) out))
      (expect (search (format nil "~C[?25h" #\Escape) out))))

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
        (expect (search accent out))
        (expect (find #\A out))
        (expect (find #\B out)))))

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

  (it "render-session-vertical-border-suppressed-at-edge"
    (let* ((sess  (make-split-session 5 3 :h))
           (win   (session-active-window sess))
           (panes (window-panes win)))
      (feed (pane-screen (first  panes)) "AAA")
      (feed (pane-screen (second panes)) "BBB")
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


  (it "clear-display-emits-clear-and-home"
    (let ((out (let ((*standard-output* (make-string-output-stream)))
                 (clear-display)
                 (get-output-stream-string *standard-output*))))
      (expect (search (format nil "~C[2J" #\Escape) out))
      (expect (search (format nil "~C[H" #\Escape) out)))))
