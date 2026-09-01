(in-package #:nerimux/test/renderer)

;;;; Direct unit tests for the R6.10 terminal-too-small guard
;;;; (renderer-tui-kit.lisp:397-436): a terminal smaller than 40x10 shows
;;;; ONLY "terminal too small (need 40x10)", centred, full-screen, replacing
;;;; the ordinary layout entirely. +MIN-TERMINAL-COLS+ / +MIN-TERMINAL-ROWS+
;;;; are the exact floor (40, 10). The guard is placed in
;;;; %RENDER-ANSI-FRAME-WITH-TUI-KIT, the single funnel both
;;;; RENDER-SESSION-TO-TUI-STRING (pane view) and
;;;; RENDER-WORKSPACE-OVERVIEW-TO-TUI-STRING (workspace view) pass through,
;;;; so testing through either public entry point exercises the same guard;
;;;; these tests use the workspace overview entry point since that is this
;;;; agent's assigned surface.
;;;;
;;;; ROWS/COLS are read fresh on every call (the server passes the client's
;;;; current size each frame) rather than cached, so "resize recovers
;;;; automatically" reduces to: two independent calls at two different sizes
;;;; produce independent, size-correct output -- exercised directly below by
;;;; calling at a too-small size then again at a valid size in the same test.
(describe "renderer-suite/tui-kit-min-size-boundary"

  ;; Exactly at the floor (40x10): NOT too small -- the ordinary layout
  ;; renders, not the warning.
  (it "renders normally at exactly 40x10, the floor itself"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-tui-string
             nil 10 40)))
      (expect (search " nerimux " frame))
      (expect (not (search "terminal too small" frame)))))

  ;; One column short of the floor (39x10): too small.
  (it "shows only the too-small warning at 39x10, one column short"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-tui-string
             nil 10 39)))
      (expect (search "terminal too small (need 40x10)" frame))
      (expect (not (search " nerimux " frame)))))

  ;; One row short of the floor (40x9): too small.
  (it "shows only the too-small warning at 40x9, one row short"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-tui-string
             nil 9 40)))
      (expect (search "terminal too small (need 40x10)" frame))
      (expect (not (search " nerimux " frame)))))

  ;; Both dimensions short at once: still just the warning, not two.
  ;; 39x5 is short in both dimensions and still wide enough to print the
  ;; warning. At 20 columns the message itself is clipped, so searching for it
  ;; tests the clipper rather than the guard.
  (it "shows the too-small warning exactly once when both dimensions are short"
    (let* ((frame
             (nerimux/renderer:render-workspace-overview-to-tui-string
              nil 5 39))
           (first-hit (search "terminal too small" frame)))
      (expect first-hit)
      (expect (not (search "terminal too small"
                           frame :start2 (1+ first-hit))))))

  ;; Resize recovery: a too-small call followed by a valid-size call is not
  ;; sticky -- each call is independently evaluated against the size it was
  ;; given, with no leftover "was too small" state from the previous call.
  (it "recovers to the ordinary layout on the very next call after resizing up"
    (let ((too-small
            (nerimux/renderer:render-workspace-overview-to-tui-string
             nil 8 30))
          (recovered
            (nerimux/renderer:render-workspace-overview-to-tui-string
             nil 24 80)))
      (expect (search "terminal too small" too-small))
      (expect (not (search "terminal too small" recovered)))
      (expect (search " nerimux " recovered))))

  ;; The direct predicate, since it is the one branch condition the whole
  ;; guard turns on: exact boundary values on both sides.
  (it "treats %terminal-too-small-p's boundary as documented: 40x10 is fine, anything under is not"
    (expect (not (nerimux/renderer::%terminal-too-small-p 10 40)))
    (expect (nerimux/renderer::%terminal-too-small-p 9 40))
    (expect (nerimux/renderer::%terminal-too-small-p 10 39))
    (expect (nerimux/renderer::%terminal-too-small-p 9 39))))
