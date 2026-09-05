(in-package #:nerimux/test)

(describe "renderer-copy-mode-frame-suite"

  (it "copy-mode-search-matches-highlighted-in-frame"
    (with-fake-session (s)
      (feed (active-screen s) "hello world hello")
      (nerimux/commands::copy-mode-enter (active-screen s))
      (setf (nerimux/terminal/types:screen-copy-search-term (active-screen s)) "hello")
      (let ((frame (nerimux/renderer:render-session-to-string s 24 81)))
        (expect frame :to-contain-sgr nerimux/renderer::+sgr-copy-mode-match+))))

  (it "copy-mode-no-search-term-no-highlight"
    (with-fake-session (s)
      (feed (active-screen s) "hello world")
      (nerimux/commands::copy-mode-enter (active-screen s))
      (setf (nerimux/terminal/types:screen-copy-search-term (active-screen s)) nil)
      (let ((frame (nerimux/renderer:render-session-to-string s 24 81)))
        (expect frame :not :to-contain-sgr nerimux/renderer::+sgr-copy-mode-match+)))))
