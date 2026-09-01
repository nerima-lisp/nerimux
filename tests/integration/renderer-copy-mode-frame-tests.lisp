(in-package #:nerimux/test)

;;;; Copy-mode search highlighting in a rendered frame.
;;;;
;;;; Moved out of packages/renderer/tests/renderer-pane-tests-b.lisp when
;;;; presentation/renderer became nerimux-renderer. Both cases put the screen
;;;; into copy mode with nerimux/commands::copy-mode-enter and build the session
;;;; with WITH-FAKE-SESSION, which binds nerimux:: server state -- neither is
;;;; reachable from a renderer test system, because nerimux-renderer depends on
;;;; neither nerimux-commands nor the bootstrap core.
(describe "renderer-copy-mode-frame-suite"

  ;; When copy mode has a search term, render-session-to-string overdraws matches in
  ;; +sgr-copy-mode-match+ (copy-mode-match-style's fixed "bg=green" → SGR 42).
  (it "copy-mode-search-matches-highlighted-in-frame"
    (with-fake-session (s)
      (feed (active-screen s) "hello world hello")
      (nerimux/commands::copy-mode-enter (active-screen s))
      (setf (nerimux/terminal/types:screen-copy-search-term (active-screen s)) "hello")
      (let ((frame (nerimux/renderer:render-session-to-string s 24 81)))
        (expect frame :to-contain-sgr nerimux/renderer::+sgr-copy-mode-match+))))

  ;; With copy mode active but no search term, no match-style SGR is emitted.
  (it "copy-mode-no-search-term-no-highlight"
    (with-fake-session (s)
      (feed (active-screen s) "hello world")
      (nerimux/commands::copy-mode-enter (active-screen s))
      (setf (nerimux/terminal/types:screen-copy-search-term (active-screen s)) nil)
      (let ((frame (nerimux/renderer:render-session-to-string s 24 81)))
        (expect frame :not :to-contain-sgr nerimux/renderer::+sgr-copy-mode-match+)))))
