(in-package #:nerimux/test/renderer)

;;;; The `?` full-screen help view (FR-005).
(describe "renderer-suite/tui-kit-help"

  (it "renders every section heading and a sample of keys, Dracula-styled"
    (let* ((output (nerimux/renderer:render-help-view-to-tui-string 40 110))
           (visible (strip-sgr output)))
      ;; Section headings.
      (expect (search "Navigate" visible))
      (expect (search "Status" visible))
      (expect (search "Menus" visible))
      (expect (search "Prefix C-q" visible))
      (expect (search "Scrollback" visible))
      (expect (search "Panes" visible))
      ;; A sample of keys from each section, and their descriptions.
      (expect (search "detail level" visible))
      (expect (search "process log" visible))
      (expect (search "quit server" visible))
      (expect (search "scrollback" visible))
      (expect (search "half page" visible))
      ;; The retired keymap must not come back. These are the descriptions the
      ;; pre-magit help carried; each names a key that no longer exists, and a
      ;; help screen advertising one is the specific bug this guards.
      (expect (null (search "new worktree" visible)))
      (expect (null (search "no key exit of its own" visible)))
      (expect (null (search "enter: i" visible)))
      ;; The title chip and the close hint.
      (expect (search "HELP" visible))
      (expect (search "close" visible))
      ;; Section headings carry +SGR-SECTION+'s Dracula purple/bold, keys
      ;; carry +SGR-ACCENT+'s Dracula cyan -- derived from the real style
      ;; objects the view builds (%EXPECTED-SGR-PARAMS,
      ;; renderer-tui-kit-tests.lisp) rather than hand-computed, so this stays
      ;; honest about what CL-TUI-KIT actually emits.
      (expect output :to-contain-sgr
              (%expected-sgr-params (nerimux/renderer::%help-view-heading-style)))
      (expect output :to-contain-sgr
              (%expected-sgr-params (nerimux/renderer::%help-view-key-style)))))

  ;; The help text is hand-written strings, so it drifts from the dispatch
  ;; tables silently -- it already did once, surviving the whole magit keymap
  (it "clips rather than errors when the terminal is too short for every section"
    (let ((output (nerimux/renderer:render-help-view-to-tui-string 8 40)))
      (expect (stringp output))
      (expect (search "HELP" (strip-sgr output))))))
