;;; Domain model and domain service packages.

(defpackage #:nerimux/model
  ;; NOT #:nerimux/config.  That package is the APPLICATION layer and this is
  ;; DOMAIN, the bottom of the stack -- the dependency would point upward.  It
  ;; used to be here, which made such references unqualified and therefore
  ;; invisible: three symbols had accumulated (*status-height*, *default-shell*,
  ;; find-posix-function) and none showed up in a search for "nerimux/config:".
  ;; With the clause gone, a future reach across that boundary has to be written
  ;; qualified, and a package that does not export it fails to compile.
  (:use #:cl
        #:nerimux/ports #:nerimux/terminal)
  (:import-from #:cl-concurrent-kit #:make-lock #:with-lock-held)
  (:documentation
   "DOMAIN layer: the aggregate every other package is ultimately about — session
    holds windows, a window holds panes, and a pane owns one PTY and one emulator
    screen.  Also owns the layout tree (the binary split tree, its geometry solver,
    resize and zoom) and the process environment that a session hands to the shells
    it spawns.  Reaches the operating system only through nerimux/ports, so the model
    can be exercised without forking anything.")
  (:export
   #:pane
   #:make-pane
   #:pane-id
   #:pane-x #:pane-y
   #:pane-width #:pane-height
   #:pane-screen
   #:pane-fd
   #:pane-pid
   #:pane-feed
   #:pane-live-p
   #:pane-window
   #:pane-worktree
   #:pane-marked
   #:pane-title
   #:pane-tty
   #:pane-start-command
   #:pane-start-path
   #:pane-unread-output-p
   #:pane-bell-p
   #:pane-process-exited-p
   #:pane-non-zero-exit-p
   #:pane-startup-failed-p
   #:pane-last-output-time
   #:pane-last-focused-time
   #:pane-last-output
   #:pane-notification
   #:pane-mark-output
   #:pane-mark-bell
   #:pane-mark-process-exit
   #:pane-mark-startup-failure
   #:pane-notify
   #:pane-clear-unread-output
   #:pane-mark-focused
   #:pane-attention-p
   #:pane-attention-reasons
   #:pane-input-disabled
   #:pane-local-options
   #:respawn-pane
   #:window
   #:make-window
   #:window-id
   #:window-name
   #:window-width #:window-height
   #:window-panes
   #:window-tree
   #:window-active-pane
   #:window-active
   #:window-select-pane
   #:window-split
   #:window-relayout
   #:window-relayout-current
   #:%assign-window-tree
   #:%status-top-offset
   #:window-remove-pane
   #:window-resize-active
   #:window-refresh-panes
   #:ensure-window-fits
   #:pane-reposition
   #:+pane-min-width+ #:+pane-min-height+
   #:layout-leaf #:make-layout-leaf #:layout-leaf-p #:layout-leaf-pane
   #:layout-split #:make-layout-split #:layout-split-p
   #:layout-split-orientation #:layout-split-first #:layout-split-second
   #:layout-split-ratio
   #:layout-leaves #:layout-find-leaf #:layout-find-parent
   #:layout-min-extent #:layout-assign #:layout-split-axis-extent
   #:resize-find-split #:resize-direction-orientation
   #:split-child-geometry #:next-pane-id
   #:pane-neighbor
   #:layout->string
   #:window-zoom-p
   #:window-zoom-tree
   #:window-zoom-toggle
   #:window-lock
   #:window-last-active
   #:window-last-active-time
   #:window-local-options
   #:window-automatic-rename-p
   #:*pane-extra-env*
   #:window-layout-cycle-index
   #:make-session
   #:*session-id-counter*
   #:session-id
   #:session-name
   #:session-windows
   #:session-active-window
   #:session-active
   #:session-select-window
   #:session-insert-window
   #:session-new-window
   #:session-remove-window
   #:session-active-pane
   #:session-last-active
   #:session-created
   #:session-window-stack
   #:session-window-index
   #:set-session-window-index
   #:session-window-index-map
   #:session-windows-in-index-order
   #:session-clients
   #:session-start-directory
   #:session-touch
   #:pane-at-position
   #:session-move-window
   #:session-swap-windows
   #:session-last-window
   #:create-initial-session
   #:all-panes
   #:process-environment-value
   #:process-environment-names
   #:process-set-environment
   #:process-unset-environment
   #:session-environment
   #:session-environment-value
   #:session-environment-names
   #:session-set-environment
   #:session-unset-environment
   #:session-environment-hidden
   #:*global-hidden-environment-names*
   #:session-child-environment
   #:*suppress-update-environment*
   #:+default-update-environment+
   #:*update-environment*
   #:get-update-environment-vars
   #:layout-node-bounding-box
   ;; Repository/worktree hierarchy used by the ghq-backed overview.
   #:organization #:organization-p #:make-organization
   #:organization-id #:organization-host #:organization-name
   #:organization-repositories #:organization-active-worktree-count
   #:organization-attention-count #:organization-missing-p
   #:organization-key #:organization-add-repository #:organization-recompute-counts
   #:repository #:repository-p #:make-repository
   #:repository-id #:repository-organization #:repository-specification
   #:repository-path #:repository-local-path #:repository-remote
   #:repository-backend #:repository-worktrees #:repository-main-worktree
   #:repository-dirty-p #:repository-conflict-p
   #:repository-ahead #:repository-behind #:repository-missing-p
   #:repository-key #:repository-add-worktree
   #:repository-worktree-by-path #:repository-recompute-status
   #:worktree #:worktree-p #:make-worktree
   #:worktree-id #:worktree-repository #:worktree-path
   #:worktree-branch #:worktree-head #:worktree-status
   #:worktree-panes #:worktree-dirty-p #:worktree-conflict-p
   #:worktree-ahead #:worktree-behind #:worktree-bare-p
   #:worktree-locked-p #:worktree-prunable-p #:worktree-missing-p
   #:worktree-key #:worktree-attention-p #:worktree-attention-reasons
   #:organization-attention-worktrees
   #:worktree-add-pane))

