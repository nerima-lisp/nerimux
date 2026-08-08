;;; Domain model and domain service packages.

(defpackage #:cl-tmux/model
  (:use #:cl
        #:cl-tmux/config #:cl-tmux/ports #:cl-tmux/terminal)
  (:import-from #:cl-concurrent-kit #:make-lock #:with-lock-held)
  (:documentation
   "DOMAIN layer: the aggregate every other package is ultimately about — session
    holds windows, a window holds panes, and a pane owns one PTY and one emulator
    screen.  Also owns the layout tree (the binary split tree, its geometry solver,
    resize and zoom) and the process environment that a session hands to the shells
    it spawns.  Reaches the operating system only through cl-tmux/ports, so the model
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
   #:pane-pipe-fd
   #:pane-pipe-active-p
   #:pane-live-p
   #:pane-pipe-output-stream
   #:pane-pipe-output-thread
   #:pane-pipe-process
   #:pane-window
   #:pane-marked
   #:pane-title
   #:pane-tty
   #:pane-start-command
   #:pane-start-path
   #:pane-dead-status
   #:pane-dead-signal
   #:pane-dead-time
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
   #:window-activity-flag
   #:window-bell-flag
   #:window-last-output-time
   #:window-silence-flag
   #:*pane-extra-env*
   #:window-layout-cycle-index
   #:window-last-layout-tree
   #:window-rotate
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
   #:*session-windows-sync-function*
   #:session-windows-changed
   #:session-active-pane
   #:session-last-active
   #:session-created
   #:session-window-stack
   #:session-window-index
   #:set-session-window-index
   #:session-window-index-map
   #:session-windows-in-index-order
   #:session-clients
   #:session-locked-p
   #:session-group
   #:session-start-directory
   #:session-touch
   #:pane-at-position
   #:apply-named-layout
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
   #:layout-node-bounding-box))

;; No :import-from for #:cl-tmux/model: the :use here was inert. All 44 model
;; references in src/domain/format/ are already written cl-tmux/model:-qualified,
;; which for this package is the more honest form anyway — the format language is
;; a read-only projection of a model it does not belong to.
(defpackage #:cl-tmux/format
  (:use #:cl)
  (:documentation
   "DOMAIN layer: the tmux format mini-language.  Expands #{pane_id}, #{window_name},
    #{session_attached} and the rest against a context built from a session, window,
    or pane, including the conditional and regex-substitution modifiers.  This is the
    read-only projection of the model that status lines, list-* commands, and
    display-message all render through.")
  (:export #:expand-format #:expand-format-safe
           #:format-context-from-session #:format-context-from-window))

(defpackage #:cl-tmux/buffer
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

(defpackage #:cl-tmux/control
  (:use #:cl)
  (:shadow #:control-error)
  (:documentation "tmux control mode (-C) wire-protocol line formatters.")
  (:export #:control-begin #:control-end #:control-error #:control-format-reply
           #:control-escape-output #:control-output
           #:control-session-changed #:control-session-renamed
           #:control-window-add #:control-window-close #:control-window-renamed
           #:control-layout-change #:control-unlinked-window-add
           #:control-window-pane-changed #:control-session-window-changed
           #:control-client-session-changed #:control-exit))

(defpackage #:cl-tmux/hooks
  (:use #:cl)
  (:documentation
   "DOMAIN layer: the event-hook registry, the seam through which configuration
    reacts to things the domain does.  Carries two kinds: the named lifecycle and
    alert hooks tmux defines (after-new-window, pane-exited, alert-bell, ...) and
    per-command hooks attached to a command name and scope.  Stores and orders the
    handlers; running them is delegated to an injected runner so the domain never
    calls into the command dispatcher directly.")
  (:export
   #:+hook-after-new-window+
   #:+hook-after-new-pane+
   #:+hook-pane-exited+
   #:+hook-after-rename-window+
   #:+hook-session-created+
   #:+hook-after-kill-pane+
   #:+hook-after-kill-window+
   #:+hook-after-split-window+
   #:+hook-client-attached+
   #:+hook-client-detached+
   #:+hook-alert-bell+
   #:+hook-alert-activity+
   #:+hook-alert-silence+
   #:+hook-pane-focus-in+
   #:+hook-pane-focus-out+
   #:+hook-after-select-pane+
   #:+hook-after-select-window+
   #:+hook-session-window-changed+
   #:+hook-window-pane-changed+
   #:+hook-window-renamed+
   #:+hook-session-renamed+
   #:+hook-after-resize-pane+
   #:+hook-client-resized+
   #:+hook-window-linked+
   #:+hook-window-unlinked+
   #:+hook-session-closed+
   #:+hook-pane-output+
   #:+hook-pane-died+
   #:*hook-registry*
   #:add-hook
   #:remove-hook
   #:run-hooks
   #:clear-hooks
   #:list-hooks
   #:*command-hooks*
   #:set-command-hook
   #:scoped-hook-entry-p
   #:append-command-hook
   #:command-hooks
   #:clear-command-hooks
   #:list-command-hooks
   #:describe-command-hooks
   #:*command-hook-runner*
   #:run-command-hooks-via-runner))

(defpackage #:cl-tmux/options
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
           #:get-option-for-context
           #:option-present-for-scope-p
           #:option-present-for-display-p
           #:show-options #:show-option
           #:show-window-options #:show-window-option
           #:window-option-present-for-display-p))
