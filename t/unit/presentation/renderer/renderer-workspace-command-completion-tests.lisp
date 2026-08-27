(in-package #:nerimux/test)

;;;; Direct unit tests for %WORKSPACE-COMMAND-COMPLETIONS /
;;;; %RENDER-WORKSPACE-COMMAND-LINE (renderer-workspace.lisp), the R6.12
;;;; `:` command-line completion: since no action menu is implemented
;;;; (§11's action-menu requirement is rewritten by R6.12), the `:` prompt
;;;; itself lists matching command names right after the colon as its only
;;;; affordance beyond plain text entry.

(describe "renderer-suite/workspace-command-completions"

  ;; Right after typing `:` (empty buffer), every command name is offered.
  (it "offers every command name for an empty buffer"
    (expect (equal nerimux/renderer::+workspace-command-names+
                   (nerimux/renderer::%workspace-command-completions ""))))

  ;; A "wt-" prefix filters to only the wt-* family, in the declared order.
  (it "filters to the wt- family for a wt- prefix"
    (expect (equal '("wt-create" "wt-delete" "wt-lock" "wt-unlock"
                     "wt-prune" "wt-prune-confirm")
                   (nerimux/renderer::%workspace-command-completions "wt-"))))

  ;; A prefix matching exactly one command still returns that one command
  ;; (prefix match is <=, not <).
  (it "matches a single command by its unique prefix"
    (expect (equal '("refresh")
                   (nerimux/renderer::%workspace-command-completions "ref"))))

  ;; The complete command name itself is still "a prefix of itself".
  (it "still completes when the buffer is already a full command name"
    (expect (equal '("refresh")
                   (nerimux/renderer::%workspace-command-completions "refresh"))))

  ;; Once a space appears, the user is typing an argument, not a command name
  ;; -- completion has nothing to add.
  (it "stops completing once a space has been typed"
    (expect (null (nerimux/renderer::%workspace-command-completions "wt-create ")))
    (expect (null (nerimux/renderer::%workspace-command-completions
                   "wt-create feat/new-branch"))))

  ;; A prefix matching no command name returns an empty list, not an error.
  (it "returns nothing for a prefix matching no command"
    (expect (null (nerimux/renderer::%workspace-command-completions "zzz"))))

  ;; Leading whitespace before the token is trimmed before matching.
  (it "trims leading whitespace before matching the prefix"
    (expect (equal '("overview")
                   (nerimux/renderer::%workspace-command-completions "  over")))))

(describe "renderer-suite/workspace-command-line-rendering"

  ;; Right after `:`, the rendered line shows the colon and every candidate.
  (it "shows the colon and the full candidate list right after typing :"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-command-line stream 0 200 "")
      (let ((line (get-output-stream-string stream)))
        (expect (search ":" line))
        (dolist (name nerimux/renderer::+workspace-command-names+)
          (expect (search name line))))))

  ;; What has been typed so far is never truncated, even when the row is too
  ;; narrow for it plus any candidates -- only the candidate suffix is
  ;; clipped, and once TYPED alone reaches COLS, the tail (where the cursor
  ;; lives) is what stays visible, not the head.
  (it "never truncates the typed prefix itself, only the completion suffix"
    (let* ((long-buffer (make-string 50 :initial-element #\z))
           (stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-command-line stream 0 20 long-buffer)
      (let ((line (get-output-stream-string stream)))
        ;; Row is far too narrow for ":" + 50 "z"s (51 columns) at 20 cols,
        ;; so the tail-keeping fallback applies: the last characters of the
        ;; buffer (where the cursor sits) must still be visible.
        (expect (search (make-string 19 :initial-element #\z) line))
        ;; No completion candidate can appear -- there is no room, and "zzz"
        ;; matches no command name anyway.
        (dolist (name nerimux/renderer::+workspace-command-names+)
          (expect (not (search name line)))))))

  ;; A buffer with a space (typing an argument) shows no candidates in the
  ;; rendered line, matching %WORKSPACE-COMMAND-COMPLETIONS returning NIL.
  (it "renders no candidates once a space has been typed, even with room to spare"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-command-line
       stream 0 200 "wt-create feat/x")
      ;; The prompt's `:` is wrapped in its own accent SGR, so the visible
      ;; text is compared with the escapes stripped.
      (let ((line (strip-sgr (get-output-stream-string stream))))
        (expect (search ":wt-create feat/x" line))
        (expect (not (search "wt-delete" line)))))))

;;; PR2's `/` tree-filter mode: %RENDER-WORKSPACE-TREE-FILTER-LINE is the
;;; `:` command-line's sibling for the overview's text filter, and
;;; %WORKSPACE-FOOTER-LINE grows a muted "/query" chip so an active filter
;;; stays visible once the user leaves :tree-filter mode and returns to
;;; ordinary :normal navigation.

(describe "renderer-suite/workspace-tree-filter-line-rendering"

  ;; Direct unit coverage of %RENDER-WORKSPACE-TREE-FILTER-LINE: the typed
  ;; query follows a bold-accent `/`.
  (it "shows a bold slash followed by the typed query"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-tree-filter-line stream 0 40 "feat")
      (let ((line (strip-sgr (get-output-stream-string stream))))
        (expect (search "/feat" line)))))

  ;; An empty query still shows the bare `/` prompt -- the mode the user is
  ;; in, not just what they have typed so far.
  (it "shows the bare slash prompt for an empty query"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-tree-filter-line stream 0 40 nil)
      (let ((line (strip-sgr (get-output-stream-string stream))))
        (expect (search "/" line))
        (expect (not (search "/f" line))))))

  ;; End to end through RENDER-WORKSPACE-OVERVIEW-TO-STRING: :NORMAL mode with
  ;; a non-empty TREE-FILTER still shows the ordinary key-hint footer, plus
  ;; the "/query" chip prepended -- the filter stays visible after Enter
  ;; returns the user to :normal (see %TRANSITION-CLIENT-UI-MODE's :accept
  ;; handling in server-multi-dispatch-command-workspace.lisp).
  (it "keeps the /query chip in the ordinary footer once back in :normal mode"
    ;; Wide enough (200 cols) that the whole footer -- chip, mode, and every
    ;; hint -- survives %VISIBLE-TRUNCATE uncut; at 80 columns the hint list
    ;; alone already overflows and the tail ("detach") would be clipped,
    ;; which is a rendering-budget fact unrelated to what this test checks.
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 200 :mode :normal :tree-filter "feat")))
      (let ((plain (strip-sgr frame)))
        (expect (search "/feat" plain))
        ;; The ordinary footer hints are still there -- :tree-filter mode did
        ;; not silently steal the footer's normal-mode content. "detach" and
        ;; "C-p" are footer-only strings; "select" is not used here because
        ;; ORGANIZATIONS being empty also puts "(no selection)" in the
        ;; detail panel, which would make that check pass for the wrong
        ;; reason.
        (expect (search "detach" plain))
        (expect (search "C-p" plain)))))

  ;; :TREE-FILTER mode replaces the whole footer with the /query input line
  ;; instead -- no ordinary key hints while the user is actively typing a
  ;; query.
  (it "replaces the footer with the /query input line in :tree-filter mode"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :mode :tree-filter :tree-filter "feat")))
      (let ((plain (strip-sgr frame)))
        (expect (search "/feat" plain))
        ;; "detach"/"C-p" are footer-only strings -- unlike "select", neither
        ;; collides with the detail panel's "(no selection)" text (ORGANIZA-
        ;; TIONS is empty here too), so their absence is a real signal that
        ;; the ordinary footer never rendered.
        (expect (not (search "detach" plain)))
        (expect (not (search "C-p" plain)))))))
