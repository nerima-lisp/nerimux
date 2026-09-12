(in-package #:nerimux/test/renderer)

(defun %snippet-around (text needle &optional (radius 24))
  "TEXT around NEEDLE, RADIUS characters each side.  The SGR sequence that
   styles a cell is emitted before its character, so a snippet that started at
   NEEDLE would miss the very attributes it is being searched for."
  (let ((pos (position needle text)))
    (and pos (subseq text (max 0 (- pos radius))
                     (min (length text) (+ pos radius))))))

(describe "renderer-suite"


  (it "render-pane-content-and-positioning"
    (let* ((sess (make-renderer-test-session 5 2 :content "hi"))
           (pane (first (window-panes (session-active-window sess))))
           (out  (render-pane-output sess pane)))
      (expect (find #\h out))
      (expect (find #\i out))
      (expect (search (format nil "~C[1;1H" #\Escape) out))))

  (it "render-pane-decscnm-reverses-output"
    (let* ((sess   (make-renderer-test-session 2 1))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (setf (screen-cell screen 0 0)
            (nerimux/terminal/types:make-cell :char #\A))
      (setf (nerimux/terminal/types:screen-reverse-screen screen) nil)
      (let ((normal (render-pane-output sess pane)))
        (setf (nerimux/terminal/types:screen-reverse-screen screen) t)
        (let ((reversed (render-pane-output sess pane)))
          (let ((normal-snippet (%snippet-around normal #\A))
                (reversed-snippet (%snippet-around reversed #\A)))
            (expect (not (string= normal reversed)))
            (expect (and reversed-snippet (search ";7" reversed-snippet)))
            (expect (and normal-snippet (null (search ";7" normal-snippet)))))))))


  (it "render-pane-double-width-not-duplicated"
    (let* ((sess   (make-renderer-test-session 5 2))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (utf8-feed screen "あ")
      (let ((out (render-pane-output sess pane)))
        (expect (= 1 (count #\あ out))))))


  (it "render-pane-emits-osc-8-hyperlink"
    (let* ((sess   (make-renderer-test-session 10 2))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (feed screen (format nil "~C]8;;https://x~C\\X" #\Escape #\Escape))
      (let ((out (render-pane-output sess pane)))
        (expect (search (format nil "~C]8;;https://x~C\\" #\Escape #\Escape) out))
        (expect (search (format nil "~C]8;;~C\\" #\Escape #\Escape) out)))))

  (it "render-pane-highlights-the-copy-cursor-row-before-any-selection"
    (let* ((sess   (make-renderer-test-session 4 3))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (feed screen "ab")
      (let ((live (render-pane-output sess pane)))
        (setf (screen-copy-mode-p screen) t
              (screen-copy-cursor screen) (cons 1 0))
        (let ((copy (render-pane-output sess pane)))
          (expect (null (search ";7" live)))
          (expect (search ";7" copy))))))

  (it "render-pane-leaves-no-mark-cell-outside-copy-mode"
    (let* ((sess   (make-renderer-test-session 4 3))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (feed screen "ab")
      (expect (null (search ";7" (render-pane-output sess pane))))))

  (it "render-pane-marks-the-drawn-pane-read"
    (let* ((sess (make-renderer-test-session 4 3))
           (pane (first (window-panes (session-active-window sess)))))
      (nerimux/pane:pane-mark-focused pane)
      (nerimux/pane:pane-mark-output pane #(111 107))
      (expect (nerimux/pane:pane-unread-output-p pane))
      (render-pane-output sess pane)
      (expect (null (nerimux/pane:pane-unread-output-p pane)))))

  (it "render-pane-no-osc-8-without-hyperlink"
    (let* ((sess   (make-renderer-test-session 10 2))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (feed screen "plain")
      (let ((out (render-pane-output sess pane)))
        (expect (null (search (format nil "~C]8;" #\Escape) out))))))


  (it "pane-cell-base-colors-preserves-explicit-background"
    (let ((cell (nerimux/terminal/types:make-cell :char #\X :fg nerimux/terminal/types:+default-color+ :bg 200)))
      (multiple-value-bind (fg bg)
          (nerimux/renderer::%pane-cell-base-colors cell 31 52)
        (expect (= 31 fg))
        (expect (= 200 bg)))))

  (it "pane-cell-base-colors-recolours-only-default-sentinel"
    (let ((cell (nerimux/terminal/types:make-cell
                 :char #\X
                 :fg nerimux/terminal/types:+default-color+
                 :bg nerimux/terminal/types:+default-color+)))
      (multiple-value-bind (fg bg)
          (nerimux/renderer::%pane-cell-base-colors cell 31 52)
        (expect (= 31 fg))
        (expect (= 52 bg))))
    (let ((cell (nerimux/terminal/types:make-cell :char #\X :fg 7 :bg 0)))
      (multiple-value-bind (fg bg)
          (nerimux/renderer::%pane-cell-base-colors cell 31 52)
        (expect (= 7 fg))
        (expect (= 0 bg)))))

  (it "resolve-pane-style-colours-never-recolours-defaults"
    (let* ((sess (make-renderer-test-session 5 2 :content "hi"))
           (pane (first (window-panes (session-active-window sess))))
           (colours (nerimux/renderer::%resolve-pane-style-colours pane)))
      (expect (null (nerimux/renderer::pane-style-def-fg colours)))
      (expect (null (nerimux/renderer::pane-style-def-bg colours)))))


  (it "layout-subtree-rect-bounding-box"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (nerimux/layout::layout-assign tree 0 0 81 24)
      (let ((rect (nerimux/renderer::layout-subtree-rect tree)))
        (expect (= 0  (getf rect :x)))
        (expect (= 0  (getf rect :y)))
        (expect (= 81 (getf rect :w)))
        (expect (= 24 (getf rect :h))))))

  (it "subtree-contains-p-detects-membership"
    (let* ((l0 (tl-leaf 1 1 1))
           (l1 (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1))
           (p0  (layout-leaf-pane l0))
           (p1  (layout-leaf-pane l1))
           (p-other (make-pane :id 99 :fd -1 :pid -1 :screen (make-screen 1 1))))
      (expect (nerimux/renderer::subtree-contains-p tree p0) :to-be-truthy)
      (expect (nerimux/renderer::subtree-contains-p tree p1) :to-be-truthy)
      (expect (nerimux/renderer::subtree-contains-p tree p-other) :to-be-falsy)
      (expect (nerimux/renderer::subtree-contains-p tree nil) :to-be-falsy)))


  (it "render-tree-borders-draws-vertical-bar"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (nerimux/layout::layout-assign tree 0 0 81 24)
      (let ((out (render-tree-borders-output tree (layout-leaf-pane l0) 81)))
        (expect (plusp (length out)))
        (expect (find #\│ out)))))

  (it "render-tree-borders-active-pane-always-coloured"
    (let* ((l0   (tl-leaf 1 1 1))
           (l1   (tl-leaf 2 1 1))
           (tree (make-layout-split :h l0 l1)))
      (nerimux/layout::layout-assign tree 0 0 81 24)
      (let ((active-out (render-tree-borders-output tree (layout-leaf-pane l0) 81))
            (inactive-out (render-tree-borders-output tree nil 81)))
        (expect active-out
                :to-contain-sgr nerimux/renderer::+sgr-active-border+)
        (expect inactive-out
                :not :to-contain-sgr nerimux/renderer::+sgr-active-border+)
        (expect inactive-out
                :to-contain-sgr nerimux/renderer::+sgr-line+)))))
