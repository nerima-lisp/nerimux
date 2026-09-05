(in-package #:nerimux/test)

(describe "renderer-suite/pane-search"

  (it "copy-search-current-match-uses-current-style"
    (with-fake-session (s)
      (feed (active-screen s) "hello world hello")
      (nerimux/commands::copy-mode-enter (active-screen s))
      (setf (nerimux/terminal/types:screen-copy-search-term (active-screen s)) "hello")
      (setf (nerimux/terminal/types:screen-copy-cursor (active-screen s)) (cons 0 13))
      (let ((frame (nerimux/renderer:render-session-to-string s 24 81)))
        (expect frame :to-contain-sgr nerimux/renderer::+sgr-copy-mode-match+)
        (expect frame :to-contain-sgr nerimux/renderer::+sgr-copy-mode-current-match+))))

  (it "copy-search-cursor-off-match-uses-only-plain-style"
    (with-fake-session (s)
      (feed (active-screen s) "hello world hello")
      (nerimux/commands::copy-mode-enter (active-screen s))
      (setf (nerimux/terminal/types:screen-copy-search-term (active-screen s)) "hello")
      (setf (nerimux/terminal/types:screen-copy-cursor (active-screen s)) (cons 0 7))
      (let ((frame (nerimux/renderer:render-session-to-string s 24 81)))
        (expect frame :to-contain-sgr nerimux/renderer::+sgr-copy-mode-match+)
        (expect frame :not :to-contain-sgr nerimux/renderer::+sgr-copy-mode-current-match+)))))
