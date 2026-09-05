(in-package #:nerimux/test/renderer)

(describe "renderer-suite"

  (it "render-pane-copy-mode-position-overlay"
    (let* ((sess   (make-renderer-test-session 20 6 :content ""))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-offset screen) 3)
      (let ((out (render-pane-output sess pane)))
        (expect (search (format nil "[3/~D]" (length (screen-scrollback screen))) out)))))

  (it "render-pane-copy-mode-position-overlay-suppressed-when-hidden"
    (let* ((sess   (make-renderer-test-session 20 6 :content ""))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-offset screen) 3
            (nerimux/terminal/types:screen-copy-hide-position screen) t)
      (let ((out (render-pane-output sess pane)))
        (expect (null (search "[3/" out))))))


  (defun %strip-csi-sequences (out)
    "Remove CSI escape sequences from OUT so the visible pane text can be compared."
    (cl-regex-kit:replace-all (cl-regex-kit:compile-regex
                               (format nil "~C\\[[0-9;?]*[A-Za-z]" #\Escape))
                              out
                              ""))

  (it "copy-mode-never-draws-a-line-number-gutter"
    (let* ((sess   (make-renderer-test-session 8 2 :content "ABCDEFGH"))
           (pane   (first (window-panes (session-active-window sess))))
           (screen (pane-screen pane)))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-cursor screen) (cons 1 0)
            (nerimux/terminal/types:screen-copy-hide-position screen) t)
      (let ((vis (%strip-csi-sequences (render-pane-output sess pane))))
        (expect (eql 0 (search "ABCDEFGH" vis))))))


  (defun %reverse-video-p (out)
    "True when OUT contains the SGR reverse-video code (;7)."
    (not (null (search ";7" out))))

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

  (it "in-sel-branch-single-row"
    (with-copy-mode-selection-fixture (sess pane screen 8 4
                                          :content "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234567"
                                          :mark-row 0
                                          :mark-col 2
                                          :cursor-row 0
                                          :cursor-col 5)
      (let ((out (render-pane-output sess pane)))
        (expect (%reverse-video-p out)))))

  (it "in-sel-branch-first-row"
    (with-copy-mode-selection-fixture (sess pane screen 8 4
                                          :content "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234567"
                                          :mark-row 0
                                          :mark-col 3
                                          :cursor-row 2
                                          :cursor-col 0)
      (let ((out (render-pane-output sess pane)))
        (expect (%reverse-video-p out)))))

  (it "in-sel-branch-last-row"
    (with-copy-mode-selection-fixture (sess pane screen 8 4
                                          :content "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234567"
                                          :mark-row 0
                                          :mark-col 0
                                          :cursor-row 2
                                          :cursor-col 5)
      (let ((out (render-pane-output sess pane)))
        (expect (%reverse-video-p out)))))

  (it "in-sel-branch-middle-row"
    (with-copy-mode-selection-fixture (sess pane screen 8 4
                                          :content "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234567"
                                          :mark-row 0
                                          :mark-col 0
                                          :cursor-row 3
                                          :cursor-col 0)
      (let ((out (render-pane-output sess pane)))
        (expect (%reverse-video-p out)))))

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
