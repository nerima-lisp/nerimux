(in-package #:nerimux/test/renderer)

(describe "renderer-suite/workspace-command-completions"

  (it "offers every command name for an empty buffer"
    (expect (equal nerimux/renderer::+workspace-command-names+
                   (nerimux/renderer::%workspace-command-completions ""))))

  (it "filters to the wt- family for a wt- prefix"
    (expect (equal '("wt-create" "wt-delete" "wt-lock" "wt-unlock"
                     "wt-prune" "wt-prune-confirm")
                   (nerimux/renderer::%workspace-command-completions "wt-"))))

  (it "matches a single command by its unique prefix"
    (expect (equal '("refresh")
                   (nerimux/renderer::%workspace-command-completions "ref"))))

  (it "still completes when the buffer is already a full command name"
    (expect (equal '("refresh")
                   (nerimux/renderer::%workspace-command-completions "refresh"))))

  (it "stops completing once a space has been typed"
    (expect (null (nerimux/renderer::%workspace-command-completions "wt-create ")))
    (expect (null (nerimux/renderer::%workspace-command-completions
                   "wt-create feat/new-branch"))))

  (it "returns nothing for a prefix matching no command"
    (expect (null (nerimux/renderer::%workspace-command-completions "zzz"))))

  (it "trims leading whitespace before matching the prefix"
    (expect (equal '("overview")
                   (nerimux/renderer::%workspace-command-completions "  over")))))

(describe "renderer-suite/workspace-command-line-rendering"

  (it "shows the colon and the full candidate list right after typing :"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-command-line stream 0 200 "")
      (let ((line (get-output-stream-string stream)))
        (expect (search ":" line))
        (dolist (name nerimux/renderer::+workspace-command-names+)
          (expect (search name line))))))

  (it "never truncates the typed prefix itself, only the completion suffix"
    (let* ((long-buffer (make-string 50 :initial-element #\z))
           (stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-command-line stream 0 20 long-buffer)
      (let ((line (get-output-stream-string stream)))
        (expect (search (make-string 19 :initial-element #\z) line))
        (dolist (name nerimux/renderer::+workspace-command-names+)
          (expect (not (search name line)))))))

  (it "renders no candidates once a space has been typed, even with room to spare"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-command-line
       stream 0 200 "wt-create feat/x")
      (let ((line (strip-sgr (get-output-stream-string stream))))
        (expect (search ":wt-create feat/x" line))
        (expect (not (search "wt-delete" line)))))))

(describe "renderer-suite/workspace-tree-filter-line-rendering"

  (it "shows a bold slash followed by the typed query"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-tree-filter-line stream 0 40 "feat")
      (let ((line (strip-sgr (get-output-stream-string stream))))
        (expect (search "/feat" line)))))

  (it "shows the bare slash prompt for an empty query"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-tree-filter-line stream 0 40 nil)
      (let ((line (strip-sgr (get-output-stream-string stream))))
        (expect (search "/" line))
        (expect (not (search "/f" line))))))

  (it "keeps the tail of an overlong tree-filter query visible"
    (let ((stream (make-string-output-stream)))
      (nerimux/renderer::%render-workspace-tree-filter-line
       stream 0 8 "abcdefghijk")
      (let ((line (strip-sgr (get-output-stream-string stream))))
        (expect (equal "defghijk" line)))))

  (it "keeps the /query chip in the ordinary key panel once back to ordinary navigation"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 200 :mode :repolist :tree-filter "feat")))
      (let ((plain (strip-sgr frame)))
        (expect (search "/feat" plain))
        (expect (search "detach" plain))
        (expect (search "shell" plain)))))

  (it "replaces the whole key panel with the /query input line when mode is :filter"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 200 :mode :filter :tree-filter "feat")))
      (let ((plain (strip-sgr frame)))
        (expect (search "/feat" plain))
        (expect (not (search "detach" plain)))
        (expect (not (search "shell" plain)))))))
