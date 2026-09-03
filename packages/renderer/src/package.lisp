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
   #:workspace-tree-objects
   #:workspace-tree-view-rows
   #:confirm-view #:make-confirm-view #:confirm-view-p
   #:confirm-view-operation #:confirm-view-fields #:confirm-view-prompt-p
   #:render-confirm-view-to-tui-string
   #:render-help-view-to-tui-string
   #:workspace-status-entries
   #:workspace-status-objects
   #:workspace-status-view-rows
   #:render-workspace-status-to-tui-string
   #:transient-view #:make-transient-view #:transient-view-p
   #:transient-view-title #:transient-view-subtitle
   #:transient-view-arguments #:transient-view-actions
   #:transient-view-height
   #:render-transient-panel
   #:render-transient-full-screen-to-tui-string
   #:render-process-log-to-tui-string
   #:clear-display
   #:*color-downsample-fn*
   #:%rgb-int-to-256))
