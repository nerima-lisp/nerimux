(in-package #:nerimux/test/renderer)

(describe "renderer-suite/tui-kit-help"

  (it "renders every section heading and a sample of keys, Dracula-styled"
    (let* ((output (nerimux/renderer:render-help-view-to-tui-string 40 110))
           (visible (strip-sgr output)))
      (expect (search "Navigate" visible))
      (expect (search "Status" visible))
      (expect (search "Menus" visible))
      (expect (search "Worktree menu" visible))
      (expect (search "Prefix C-q" visible))
      (expect (search "n/p move" visible))
      (expect (search "Right/Left expand/collapse" visible))
      (expect (search "v status" visible))
      (expect (search "prune all" visible))
      (expect (search "new shell window" visible))
      (expect (search "w repolist" visible))
      (expect (null (search "workspace overview" visible)))
      (expect (null (search "create+assign" visible)))
      (expect (search "Scrollback" visible))
      (expect (search "Panes" visible))
      (expect (search "detail level" visible))
      (expect (search "process log" visible))
      (expect (search "quit server" visible))
      (expect (search "scrollback" visible))
      (expect (search "half page" visible))
      (expect (null (search "new worktree" visible)))
      (expect (null (search "no key exit of its own" visible)))
      (expect (null (search "enter: i" visible)))
      (expect (search "HELP" visible))
      (expect (search "close" visible))
      (expect output :to-contain-sgr
              (%expected-sgr-params (nerimux/renderer::%help-view-heading-style)))
      (expect output :to-contain-sgr
              (%expected-sgr-params (nerimux/renderer::%help-view-key-style)))))

  (it "clips rather than errors when the terminal is too short for every section"
    (let ((output (nerimux/renderer:render-help-view-to-tui-string 8 40)))
      (expect (stringp output))
      (expect (search "HELP" (strip-sgr output))))))
