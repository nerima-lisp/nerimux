(in-package #:nerimux/test)

;;;; renderer-pane tests — part C: %apply-border-style branch coverage,
;;;; in-sel-branch.

(describe "renderer-suite"

  ;;; -- %apply-border-style branch coverage -------------------------------------
  ;;;
  ;;; %apply-border-style (stream style-string) has four reachable branches:
  ;;;   1. NIL style        -> reset-attrs (no colour code)
  ;;;   2. "default" style  -> reset-attrs (no colour code)
  ;;;   3. "fg=COLOR" style -> reset-attrs then ESC[Nm for the named colour
  ;;;   4. t (fallback)     -> reset-attrs (no colour code)

  (defun %border-style-output (style)
    "Return the string emitted by %apply-border-style for STYLE."
    (with-output-to-string (s)
      (nerimux/renderer::%apply-border-style s style)))

  ;; NIL and "default" styles emit only the reset SGR (ESC[0m).
  (it "apply-border-style-resets-table"
    (dolist (c '((nil       "nil style")
                 ("default" "\"default\" style")))
      (destructuring-bind (style desc) c
        (declare (ignore desc))
        (let ((out (%border-style-output style)))
          (expect (search (format nil "~C[0m" #\Escape) out))))))

  ;; pane-border-style and pane-active-border-style are read directly from global options.
  (it "pane-border-style-applied-directly"
    (with-isolated-options ("pane-border-style" "fg=red"
                            "pane-active-border-style" "fg=green,bg=black")
      (let ((normal (nerimux/options:get-option "pane-border-style" ""))
            (active (nerimux/options:get-option "pane-active-border-style" "")))
        (expect (search "fg=red" normal))
        (expect (search "fg=green" active))
        (expect (search "bg=black" active)))))

  ;; mode-style is read directly from the global option (no deprecated-option fold-in).
  (it "mode-style-applied-directly"
    (with-isolated-options ("mode-style" "fg=black,bg=yellow,bold")
      (let ((eff (nerimux/options:get-option "mode-style" "")))
        (expect (search "fg=black" eff))
        (expect (search "bg=yellow" eff))
        (expect (search "bold" eff)))))

  ;; fg=COLOR style emits the named colour's SGR code.
  (it "apply-border-style-fg-table"
    (dolist (c '(("fg=green"  "~C[32m" "green → ESC[32m")
                 ("fg=red"    "~C[31m" "red → ESC[31m")
                 ("fg=blue"   "~C[34m" "blue → ESC[34m")
                 ("fg=yellow" "~C[33m" "yellow → ESC[33m")))
      (destructuring-bind (style fmt desc) c
        (declare (ignore desc))
        (let ((out (%border-style-output style)))
          (expect (search (format nil fmt #\Escape) out))))))

  ;; An unrecognised non-fg= style falls through to the reset-attrs fallback.
  (it "apply-border-style-unknown-falls-back-to-reset"
    (let ((out (%border-style-output "bold")))
      (expect (search (format nil "~C[0m" #\Escape) out))))

  ;; When copy mode is active, render-pane draws the copy-mode position banner.
  (it "render-pane-copy-mode-position-overlay"
    (with-copy-mode-render-fixture (sess pane screen 20 6
                                    :position-format "COPY-BANNER")
      (setf (screen-copy-mode-p screen) t)
      (let ((out (render-pane-output sess pane)))
        (expect (search "COPY-BANNER" out)))))

  ;; copy-mode -H (screen-copy-hide-position) suppresses the position banner
  ;; even with a non-empty copy-mode-position-format — previously only
  ;; tested at the dispatch layer (does -H set the flag), never at the
  ;; renderer layer (does the renderer actually honour it).
  (it "render-pane-copy-mode-position-overlay-suppressed-when-hidden"
    (with-copy-mode-render-fixture (sess pane screen 20 6
                                    :position-format "COPY-BANNER")
      (setf (screen-copy-mode-p screen) t
            (nerimux/terminal/types:screen-copy-hide-position screen) t)
      (let ((out (render-pane-output sess pane)))
        (expect (null (search "COPY-BANNER" out))))))

  ;;; -- copy-mode line numbers --------------------------------------------------

  (defun %strip-csi-sequences (out)
    "Remove CSI escape sequences from OUT so the visible pane text can be compared."
    (cl-regex-kit:replace-all (cl-regex-kit:compile-regex
                               (format nil "~C\\[[0-9;?]*[A-Za-z]" #\Escape))
                              out
                              ""))

  ;; copy-mode-line-numbers off leaves the pane content unchanged.
  (it "copy-mode-line-numbers-off-suppresses-gutter"
    (with-copy-mode-render-fixture (sess pane screen 4 2
                                    :content "ABCDEFGH"
                                    :options '("copy-mode-line-numbers" "off"))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-cursor screen) (cons 1 0))
      (let ((vis (%strip-csi-sequences (render-pane-output sess pane))))
        (expect (string= "ABCDEFGH" vis)))))

  ;; relative copy-mode line numbers render a gutter with the cursor row at 0.
  (it "copy-mode-line-numbers-relative-renders-gutter"
    (with-copy-mode-render-fixture (sess pane screen 4 2
                                    :content "ABCDEFGH"
                                    :options '("copy-mode-line-numbers" "relative"))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-cursor screen) (cons 1 0))
      (let ((vis (%strip-csi-sequences (render-pane-output sess pane))))
        (expect (string= " 1AB 0EF" vis)))))

  ;; default copy-mode line numbers use the viewport row index.
  (it "copy-mode-line-numbers-default-renders-zero-based-gutter"
    (with-copy-mode-render-fixture (sess pane screen 4 2
                                    :content "ABCDEFGH"
                                    :options '("copy-mode-line-numbers" "default"))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-cursor screen) (cons 0 0))
      (let ((vis (%strip-csi-sequences (render-pane-output sess pane))))
        (expect (string= " 0AB 1EF" vis)))))

  ;; absolute copy-mode line numbers use the absolute pane history index.
  (it "copy-mode-line-numbers-absolute-renders-one-based-gutter"
    (with-copy-mode-render-fixture (sess pane screen 4 2
                                    :content "ABCDEFGH"
                                    :options '("copy-mode-line-numbers" "absolute"))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-cursor screen) (cons 0 0))
      (let ((vis (%strip-csi-sequences (render-pane-output sess pane))))
        (expect (string= " 1AB 2EF" vis)))))

  ;; hybrid copy-mode line numbers render absolute numbering on the cursor row and relative elsewhere.
  (it "copy-mode-line-numbers-hybrid-renders-absolute-on-cursor-row"
    (with-copy-mode-render-fixture (sess pane screen 4 2
                                    :content "ABCDEFGH"
                                    :options '("copy-mode-line-numbers" "hybrid"))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-cursor screen) (cons 0 0))
      (let ((vis (%strip-csi-sequences (render-pane-output sess pane))))
        (expect (string= " 1AB 1EF" vis)))))

  ;; copy-mode-entered-by-mouse-p suppresses line numbers, matching tmux mouse enter behaviour.
  (it "copy-mode-line-numbers-mouse-enter-suppresses-gutter"
    (with-copy-mode-render-fixture (sess pane screen 4 2
                                    :content "ABCDEFGH"
                                    :options '("copy-mode-line-numbers" "absolute"))
      (setf (screen-copy-mode-p screen) t
            (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p screen) t)
      (let ((vis (%strip-csi-sequences (render-pane-output sess pane))))
        (expect (string= "ABCDEFGH" vis)))))

  ;; copy-mode-current-line-number-style overrides the base line-number style on the cursor row.
  (it "copy-mode-current-line-number-style-applies-to-cursor-row"
    (with-copy-mode-render-fixture (sess pane screen 4 2
                                    :content "ABCDEFGH"
                                    :options '("copy-mode-line-numbers" "absolute"
                                               "copy-mode-line-number-style" "fg=green"
                                               "copy-mode-current-line-number-style" "fg=red"))
      (setf (screen-copy-mode-p screen) t
            (screen-copy-cursor screen) (cons 1 0))
      (let ((out (render-pane-output sess pane)))
        (expect (= 1 (%count-substring (format nil "~C[32m" #\Escape) out)))
        (expect (= 1 (%count-substring (format nil "~C[31m" #\Escape) out))))))

  ;;; -- in-sel branch coverage via render-pane ----------------------------------

  (defun %reverse-video-p (out)
    "True when OUT contains the SGR reverse-video code (;7)."
    (not (null (search ";7" out))))

  (defun %count-substring (needle haystack)
    "Count non-overlapping occurrences of NEEDLE in HAYSTACK."
    (loop with start = 0
          for pos = (search needle haystack :start2 start)
          while pos
          do (setf start (+ pos (length needle)))
          count 1))

  ;; When copy-selecting is NIL the sel-active gate is false.
  (it "in-sel-branch-not-selecting"
    (with-isolated-options ("copy-mode-position-style" "default"
                            "copy-mode-position-format" "")
      (with-copy-mode-selection-fixture (sess pane screen 8 4
                                            :content "ABCDEFGH"
                                            :copy-mode-p nil
                                            :selecting-p nil)
        (let ((baseline (render-pane-output sess pane)))
          (setf (screen-copy-selecting screen) nil
                (screen-copy-mark screen) nil
                (screen-copy-cursor screen) nil)
          (let ((out (render-pane-output sess pane)))
            (expect (string= baseline out)))))))

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

  ;; copy-mode-selection-style recolours selected cells, and mode-style no longer feeds selection highlighting.
  (it "copy-mode-selection-style-drives-selection-colour"
    (with-isolated-config
      (with-isolated-options ("mode-style" "bg=colour99"
                              "copy-mode-selection-style" "bg=colour172"
                              "copy-mode-position-style" "default"
                              "copy-mode-position-format" ""
                              "copy-mode-mark-style" "default")
        (with-copy-mode-selection-fixture (sess pane screen 8 4
                                              :content "ABCDEFGHIJKLMNOP"
                                              :mark-row 0
                                              :mark-col 2
                                              :cursor-row 0
                                              :cursor-col 5)
          (let ((out (render-pane-output sess pane)))
            (expect (search "48;5;172" out))
            (expect (null (search "48;5;99" out))))))))

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

  ;; When copy-selecting is T but mark is NIL, sel-active is false.
  (it "in-sel-branch-selecting-but-no-mark"
    (with-isolated-options ("copy-mode-position-style" "default"
                            "copy-mode-position-format" "")
      (let* ((sess   (make-renderer-test-session 8 4 :content "ABCDEFGH"))
             (pane   (first (window-panes (session-active-window sess))))
             (screen (pane-screen pane)))
        (let ((baseline (render-pane-output sess pane)))
        (setf (screen-copy-mode-p    screen) t
              (screen-copy-selecting screen) t
              (screen-copy-mark      screen) nil
              (screen-copy-cursor    screen) (cons 0 3))
          (let ((out (render-pane-output sess pane)))
            (expect (string= baseline out))))))))
