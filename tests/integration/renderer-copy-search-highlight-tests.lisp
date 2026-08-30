(in-package #:nerimux/test)

;;;; Direct unit tests for renderer-pane-search.lisp's %render-copy-search-matches.
;;;;
;;;; copy-mode-match-style / copy-mode-current-match-style (domain/options,
;;;; deleted R2.2) are fixed at their registry defaults "bg=green" /
;;;; "bg=magenta" — SGR 42 / 45, which renderer-pane-search.lisp now holds as
;;;; the constants +sgr-copy-mode-match+ / +sgr-copy-mode-current-match+
;;;; (R2.4 deleted parse-style-string/style-to-sgr, the parser that used to
;;;; resolve those option strings to these same codes).

(describe "renderer-suite/pane-search"

  ;; When the copy-mode cursor sits inside a match span, that span uses
  ;; +sgr-copy-mode-current-match+; other matches still use +sgr-copy-mode-match+.
  (it "copy-search-current-match-uses-current-style"
    (with-fake-session (s)
      (feed (active-screen s) "hello world hello")
      (nerimux/commands::copy-mode-enter (active-screen s))
      (setf (nerimux/terminal/types:screen-copy-search-term (active-screen s)) "hello")
      ;; "hello world hello" -> matches at columns [0,5) and [12,17); put the
      ;; cursor inside the second match.
      (setf (nerimux/terminal/types:screen-copy-cursor (active-screen s)) (cons 0 13))
      (let ((frame (nerimux/renderer:render-session-to-string s 24 81)))
        (expect frame :to-contain-sgr nerimux/renderer::+sgr-copy-mode-match+)
        (expect frame :to-contain-sgr nerimux/renderer::+sgr-copy-mode-current-match+))))

  ;; When the copy-mode cursor is outside every match span, all matches use
  ;; +sgr-copy-mode-match+ and +sgr-copy-mode-current-match+ never appears.
  (it "copy-search-cursor-off-match-uses-only-plain-style"
    (with-fake-session (s)
      (feed (active-screen s) "hello world hello")
      (nerimux/commands::copy-mode-enter (active-screen s))
      (setf (nerimux/terminal/types:screen-copy-search-term (active-screen s)) "hello")
      ;; Column 7 is inside "world", not a match.
      (setf (nerimux/terminal/types:screen-copy-cursor (active-screen s)) (cons 0 7))
      (let ((frame (nerimux/renderer:render-session-to-string s 24 81)))
        (expect frame :to-contain-sgr nerimux/renderer::+sgr-copy-mode-match+)
        (expect frame :not :to-contain-sgr nerimux/renderer::+sgr-copy-mode-current-match+)))))
