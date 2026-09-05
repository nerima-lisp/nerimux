(in-package #:nerimux/test/renderer)

(describe "renderer-suite/tui-kit-min-size-boundary"

  (it "renders normally at exactly 40x10, the floor itself"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-tui-string
             nil 10 40)))
      (expect (search " nerimux " frame))
      (expect (not (search "terminal too small" frame)))))

  (it "shows only the too-small warning at 39x10, one column short"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-tui-string
             nil 10 39)))
      (expect (search "terminal too small (need 40x10)" frame))
      (expect (not (search " nerimux " frame)))))

  (it "shows only the too-small warning at 40x9, one row short"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-tui-string
             nil 9 40)))
      (expect (search "terminal too small (need 40x10)" frame))
      (expect (not (search " nerimux " frame)))))

  (it "shows the too-small warning exactly once when both dimensions are short"
    (let* ((frame
             (nerimux/renderer:render-workspace-overview-to-tui-string
              nil 5 39))
           (first-hit (search "terminal too small" frame)))
      (expect first-hit)
      (expect (not (search "terminal too small"
                           frame :start2 (1+ first-hit))))))

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

  (it "treats %terminal-too-small-p's boundary as documented: 40x10 is fine, anything under is not"
    (expect (not (nerimux/renderer::%terminal-too-small-p 10 40)))
    (expect (nerimux/renderer::%terminal-too-small-p 9 40))
    (expect (nerimux/renderer::%terminal-too-small-p 10 39))
    (expect (nerimux/renderer::%terminal-too-small-p 9 39))))
