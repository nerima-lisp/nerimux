(defpackage #:nerimux/renderer
  (:use #:cl
        #:nerimux/workspace-model #:nerimux/pane #:nerimux/layout
        #:nerimux/window #:nerimux/session #:nerimux/terminal)
  (:import-from #:cl-concurrent-kit #:with-lock-held)
  (:documentation
   "PRESENTATION layer: the only package that writes to the real terminal.  Composites
    every pane's emulator screen, the borders between them, and the status bar into
    one full repaint, emitted as raw ANSI/VT100 escapes with no curses dependency and
    flushed as a single write to avoid tearing.  Also owns the true-colour downsampling
    used when the outer terminal cannot show 24-bit colour.")
  (:export
   #:render-session-to-string
   #:render-session-to-tui-string
   #:render-workspace-overview-to-string
   #:render-workspace-overview-to-tui-string
   ;; The visible tree rows, in display order (R6.3). Key dispatch selects by
   ;; index into these, so it must read the same list the frame is drawn from.
   #:workspace-tree-objects
   ;; Rows available to the tree list in the one-column overview layout
   ;; (workspace redesign PR2); the bootstrap scroll-clamp math calls this so
   ;; it can't drift from the layout's own row budget.
   #:workspace-tree-view-rows
   ;; Full-screen confirmation / failure view (R6.4). The dispatcher builds the
   ;; struct and reads the y/n answer; this package only draws it.
   #:confirm-view #:make-confirm-view #:confirm-view-p
   #:confirm-view-operation #:confirm-view-fields #:confirm-view-prompt-p
   #:render-confirm-view-to-tui-string
   #:render-help-view-to-tui-string
   ;; magit-style per-worktree status view (FR-003). WORKSPACE-STATUS-OBJECTS is
   ;; to this view what WORKSPACE-TREE-OBJECTS is to the repolist: key dispatch
   ;; selects by index into it, so it has to be the same list the frame is drawn
   ;; from or the cursor and the highlight disagree.
   #:workspace-status-entries
   #:workspace-status-objects
   #:workspace-status-view-rows
   #:render-workspace-status-to-tui-string
   ;; magit transient (FR-010). Same split as CONFIRM-VIEW above: bootstrap
   ;; builds the struct and owns the action closures, this package only draws it.
   #:transient-view #:make-transient-view #:transient-view-p
   #:transient-view-title #:transient-view-subtitle
   #:transient-view-arguments #:transient-view-actions
   #:transient-view-height
   #:render-transient-panel
   #:render-transient-full-screen-to-tui-string
   ;; `$` process log (FR-011).
   #:render-process-log-to-tui-string
   #:clear-display
   ;; Terminal colour-capability downsampling hook; see renderer-format.lisp.
   ;; Nothing installs it now that the startup flag that did was removed, so it
   ;; stays NIL and the renderer emits 24-bit colour unconditionally.
   #:*color-downsample-fn*
   #:%rgb-int-to-256))
