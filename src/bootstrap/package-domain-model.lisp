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
   #:pane-dead-status
   #:pane-dead-signal
   #:pane-dead-time
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
   #:organization-key #:organization-repository-count
   #:organization-add-repository #:organization-recompute-counts
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

;; No :import-from for #:nerimux/model: the :use here was inert. All 44 model
;; references in src/domain/format/ are already written nerimux/model:-qualified,
;; which for this package is the more honest form anyway — the format language is
;; a read-only projection of a model it does not belong to.
(defpackage #:nerimux/format
  (:use #:cl)
  (:documentation
   "DOMAIN layer: the tmux format mini-language.  Expands #{pane_id}, #{window_name},
    #{session_attached} and the rest against a context built from a session, window,
    or pane, including the conditional and regex-substitution modifiers.  This is the
    read-only projection of the model that status lines, list-* commands, and
    display-message all render through.")
  (:export #:expand-format #:expand-format-safe
           #:format-context-from-session #:format-context-from-window))

(defpackage #:nerimux/buffer
  (:use #:cl)
  (:documentation
   "DOMAIN layer: the paste-buffer ring.  Holds the most-recent-first stack of named
    and auto-named (buffer0, buffer1, ...) buffers behind copy-mode yanks, set-buffer,
    and paste-buffer, bounded by the configured buffer-limit.  Also owns the OSC 52
    handler, which is where a program running inside a pane reaches the same store.")
  (:export #:+default-buffer-limit+
           #:*paste-buffers* #:*buffer-auto-index*
           #:add-paste-buffer #:rename-paste-buffer #:get-paste-buffer #:set-named-buffer
           #:get-named-buffer #:buffer-names
           #:initialize-osc52-handler
           #:list-paste-buffers #:list-paste-buffers-with-names
           #:delete-paste-buffer #:delete-buffer-by-name #:clear-paste-buffers))

(defpackage #:nerimux/options
  (:use #:cl)
  (:documentation
   "DOMAIN layer: the option store and its scope rules.  tmux options are not a flat
    table — server, global, session, window, and pane each hold their own overrides,
    and a lookup walks outward until one is present.  This package owns that
    resolution, the option-spec registry that gives each name a type and a default,
    and the show-options projection that reports which scope a value actually came
    from.")
  (:export #:*global-options* #:*option-registry*
           #:option-spec #:make-option-spec
           #:option-spec-name #:option-spec-type #:option-spec-default
           #:define-option-table
           #:define-tmux-options
           #:get-option #:set-option
           #:option-defined-p #:all-options
           #:option-scope-from-name
           #:user-option-name-p
           #:style-option-p #:append-option-value
           #:*server-options* #:*server-option-registry*
           #:define-server-options
           #:get-server-option #:set-server-option
           #:get-option-for-window #:set-option-for-window
           #:get-option-for-pane   #:set-option-for-pane
          ;; Status-bar row count: the single source of truth for how many rows
          ;; the bar occupies, used by BOTH the renderer (paint) and the pane
          ;; layout (reserve).  See options-api.lisp for why it lives here.
          #:status-line-count     #:+max-status-lines+
           #:get-option-for-context
           #:option-present-for-scope-p
           #:option-present-for-display-p
           #:show-options #:show-option
           #:show-window-options #:show-window-option
           #:window-option-present-for-display-p))
