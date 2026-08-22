(in-package #:nerimux/test)

;;;; renderer-pane tests — part C: copy-mode position overlay, copy-mode
;;;; gutter (deleted), in-sel branch coverage.
;;;;
;;;; R2.4 deleted %apply-border-style along with parse-style-string/
;;;; style-to-sgr (pane-border-style/pane-active-border-style/mode-style are
;;;; now fixed constants — see renderer-borders.lisp).  R6.8 replaced the
;;;; copy-mode-position-format template with a fixed "[POS/LIMIT]" string
;;;; (renderer-pane-copy-mode-overlay.lisp:%copy-mode-position-overlay-text).
;;;; copy-mode-line-numbers is fixed "off" (§1.4): the gutter this used to
;;;; draw is gone outright — renderer-pane-copy-mode-line-number.lisp is now
;;;; an empty file, and %render-pane-body always uses the pane's full width.

(describe "renderer-suite"

  ;; render-pane draws the copy-mode position banner in the fixed
  ;; "[POS/LIMIT]" form when copy mode is active.
  (it "render-pane-copy-mode-position-overlay"
    (let* ((sess   (make-renderer-test-session 20 6 :content ""))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-offset screen) 3)
      (let ((out (render-pane-output sess pane)))
        (expect (search (format nil "[3/~D]" (length (screen-scrollback screen))) out)))))

  ;; copy-mode -H (screen-copy-hide-position) suppresses the position banner
  ;; entirely.
  (it "render-pane-copy-mode-position-overlay-suppressed-when-hidden"
    (let* ((sess   (make-renderer-test-session 20 6 :content ""))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-offset screen) 3
            (nerimux/terminal/types:screen-copy-hide-position screen) t)
      (let ((out (render-pane-output sess pane)))
        (expect (null (search "[3/" out))))))

  ;;; -- copy-mode line-number gutter (deleted, §1.4) ----------------------------

  (defun %strip-csi-sequences (out)
    "Remove CSI escape sequences from OUT so the visible pane text can be compared."
    (cl-regex-kit:replace-all (cl-regex-kit:compile-regex
                               (format nil "~C\\[[0-9;?]*[A-Za-z]" #\Escape))
                              out
                              ""))

  ;; copy-mode-line-numbers is always off: no gutter is ever drawn, so the
  ;; pane's visible content is exactly the fed content, unchanged. The
  ;; position overlay (R6.8, unrelated to the gutter) is suppressed here so it
  ;; does not show up as unaccounted-for trailing text in the comparison.
  (it "copy-mode-never-draws-a-line-number-gutter"
    (let* ((sess   (make-renderer-test-session 8 2 :content "ABCDEFGH"))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-cursor screen) (cons 1 0)
            (nerimux/terminal/types:screen-copy-hide-position screen) t)
      (let ((vis (%strip-csi-sequences (render-pane-output sess pane))))
        (expect (string= "ABCDEFGH" vis)))))

  ;;; -- in-sel branch coverage via render-pane ----------------------------------

  (defun %reverse-video-p (out)
    "True when OUT contains the SGR reverse-video code (;7)."
    (not (null (search ";7" out))))

  ;; When copy-selecting is NIL the sel-active gate is false.
  (it "in-sel-branch-not-selecting"
    (with-copy-mode-selection-fixture (sess pane screen 8 4
                                          :content "ABCDEFGH"
                                          :copy-mode-p nil
                                          :selecting-p nil)
      (let ((baseline (render-pane-output sess pane)))
        (setf (screen-copy-selecting screen) nil
              (screen-copy-mark screen) nil
              (screen-copy-cursor screen) nil)
        (let ((out (render-pane-output sess pane)))
          (expect (string= baseline out))))))

  ;; Single-row selection: only cells in [sel-start-c, sel-end-c) are highlighted.
  (it "in-sel-branch-single-row"
    (with-copy-mode-selection-fixture (sess pane screen 8 4
                                          :content "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234567"
                                          :mark-row 0
                                          :mark-col 2
                                          :cursor-row 0
                                          :cursor-col 5)
      (let ((out (render-pane-output sess pane)))
        (expect (%reverse-video-p out)))))

  ;; First row of a multi-row selection: cols >= sel-start-c are highlighted.
  (it "in-sel-branch-first-row"
    (with-copy-mode-selection-fixture (sess pane screen 8 4
                                          :content "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234567"
                                          :mark-row 0
                                          :mark-col 3
                                          :cursor-row 2
                                          :cursor-col 0)
      (let ((out (render-pane-output sess pane)))
        (expect (%reverse-video-p out)))))

  ;; Last row of a multi-row selection: cols < sel-end-c are highlighted.
  (it "in-sel-branch-last-row"
    (with-copy-mode-selection-fixture (sess pane screen 8 4
                                          :content "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234567"
                                          :mark-row 0
                                          :mark-col 0
                                          :cursor-row 2
                                          :cursor-col 5)
      (let ((out (render-pane-output sess pane)))
        (expect (%reverse-video-p out)))))

  ;; Middle rows of a multi-row selection are fully highlighted.
  (it "in-sel-branch-middle-row"
    (with-copy-mode-selection-fixture (sess pane screen 8 4
                                          :content "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234567"
                                          :mark-row 0
                                          :mark-col 0
                                          :cursor-row 3
                                          :cursor-col 0)
      (let ((out (render-pane-output sess pane)))
        (expect (%reverse-video-p out)))))

  ;; When copy-selecting is T but mark is NIL, sel-active is false. Both
  ;; renders keep copy-mode-p T so the (unrelated) position overlay is
  ;; present in both and cancels out of the comparison; only the
  ;; selecting/mark/cursor state under test changes between them.
  (it "in-sel-branch-selecting-but-no-mark"
    (let* ((sess   (make-renderer-test-session 8 4 :content "ABCDEFGH"))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (setf (screen-copy-mode-p    screen) t
            (screen-copy-selecting screen) nil
            (screen-copy-mark      screen) nil
            (screen-copy-cursor    screen) nil)
      (let ((baseline (render-pane-output sess pane)))
        (setf (screen-copy-selecting screen) t
              (screen-copy-mark      screen) nil
              (screen-copy-cursor    screen) (cons 0 3))
        (let ((out (render-pane-output sess pane)))
          (expect (string= baseline out)))))))
