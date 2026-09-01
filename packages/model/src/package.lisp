;;; Domain model and domain service packages.
;;;
;;; Split into five sub-packages by concern (workspace-model, pane, layout,
;;; window, session), each named after the future packages/<name>/ directory
;;; it will become in Phase 2 (W4). A facade package, nerimux/model, briefly
;;; :USEd all five and re-exported their combined 207 symbols so every
;;; external caller (picker, renderer, bootstrap) could keep working
;;; unqualified while Wave B moved each of those callers onto the real
;;; sub-package a symbol actually lives in; once that migration finished
;;; (W5-z) the facade was deleted, since nothing referenced it anymore.
;;;
;;; Dependency direction between the five, verified by W4-prep's analysis and
;;; confirmed by compilation (no :USE cycle is possible in Common Lisp, so an
;;; apparent one means a file needs reassigning, not a workaround):
;;;   pane -> workspace-model   (worktree-add-pane needs worktree-panes;
;;;                              attention.lisp needs worktree/organization
;;;                              accessors)
;;;   layout -> pane            (layout-geometry needs pane-x/y/w/h and
;;;                              %update-pane-geometry)
;;;   window -> layout, pane    (window-core/tree/operations need layout's
;;;                              tree helpers; %fork-pane/%make-input-pane)
;;; layout's one reference the other way (layout->string, in
;;; layout-persistence.lisp, needs window-tree) is written package-qualified
;;; (nerimux/window:window-tree) rather than moving the file to "window":
;;; define-layout-fold/define-layout-visitor (layout-visitor.lisp) are
;;; non-hygienic macros whose LEAF-PANE/SPLIT-FIRST/SPLIT-SECOND/SPLIT-ORIENT
;;; bindings are symbols interned in nerimux/layout at macro-definition time:
;;; a file using those macros from any other package reads its own on-leaf/
;;; on-split forms into ITS package instead, producing a different symbol the
;;; macro's LET never binds (confirmed by compilation: moving
;;; layout-persistence.lisp to "window" broke with undefined-variable errors
;;; on exactly those four names). window-neighbor.lisp's
;;; pane-neighbor/pane-at-position avoid this because they don't use either
;;; macro, so they were free to move to "window" for their window-tree need.
;;;   session -> window, layout, pane, nerimux/ports
;;;                             (session-new-window builds windows/panes;
;;;                              %attach-full-screen-pane calls %fork-pane)
;;; workspace-model depends on nothing else in domain/model. pane's one
;;; dependency back toward session (%spawn-shell-for-pane needs
;;; session-child-environment) is written package-qualified
;;; (nerimux/session:session-child-environment) rather than via :USE,
;;; since :USE cannot go both ways between pane and session.
(defpackage #:nerimux/workspace-model
            (:use #:cl)
            (:documentation
             "DOMAIN layer: the ghq-backed organization/repository/worktree hierarchy —
    what the global picker and workspace overview show. No dependency on any
    other domain sub-package; pane and session depend on this one, not the
    other way around.")
            (:export #:make-organization
                     #:make-repository
                     #:make-worktree
                     #:organization
                     #:organization-active-worktree-count
                     #:organization-add-repository
                     #:organization-attention-count
                     #:organization-counts-derived-p
                     #:organization-host
                     #:organization-id
                     #:organization-key
                     #:organization-missing-p
                     #:organization-name
                     #:organization-p
                     #:organization-repositories
                     #:repository
                     #:repository-add-worktree
                     #:repository-ahead
                     #:repository-backend
                     #:repository-behind
                     #:repository-conflict-p
                     #:repository-dirty-p
                     #:repository-id
                     #:repository-key
                     #:repository-local-path
                     #:repository-main-worktree
                     #:repository-missing-p
                     #:repository-organization
                     #:repository-p
                     #:repository-path
                     #:repository-recompute-status
                     #:repository-remote
                     #:repository-specification
                     #:repository-worktree-by-path
                     #:repository-worktrees
                     #:worktree
                     #:worktree-ahead
                     #:worktree-attention-p
                     #:worktree-bare-p
                     #:worktree-behind
                     #:worktree-branch
                     #:worktree-changed-files
                     #:worktree-commits-state
                     #:worktree-conflict-p
                     #:worktree-dirty-p
                     #:worktree-head
                     #:worktree-id
                     #:worktree-key
                     #:worktree-locked-p
                     #:worktree-missing-p
                     #:worktree-p
                     #:worktree-panes
                     #:worktree-path
                     #:worktree-prunable-p
                     #:worktree-recent-commits
                     #:worktree-repository
                     #:worktree-staged-files
                     #:worktree-stashes
                     #:worktree-stashes-state
                     #:worktree-status
                     #:worktree-unmerged-files
                     #:worktree-unstaged-files
                     #:worktree-untracked-files))

(defpackage #:nerimux/pane
            (:use #:cl
                  #:nerimux/ports
                  #:nerimux/terminal
                  #:nerimux/workspace-model)
            (:import-from #:cl-concurrent-kit #:with-lock-held)
            (:documentation
             "DOMAIN layer: one terminal pane — a PTY fd, a virtual screen, and its
    position within a window — plus the attention state composed from a
    worktree's and organization's panes (attention.lisp). Reaches the
    operating system only through nerimux/ports. Needs
    nerimux/session:session-child-environment for %spawn-shell-for-pane;
    written package-qualified rather than :USEd, since session depends on
    this package for %fork-pane and a :USE cycle is impossible.")
            (:export #:%fork-pane
                     #:%make-input-pane
                     #:%update-pane-geometry
                     #:*pane-extra-env*
                     #:make-pane
                     #:organization-attention-worktrees
                     #:organization-recompute-counts
                     #:pane
                     #:pane-attention-p
                     #:pane-attention-reasons
                     #:pane-bell-p
                     #:pane-clear-unread-output
                     #:pane-fd
                     #:pane-feed
                     #:pane-height
                     #:pane-id
                     #:pane-input-disabled
                     #:pane-last-focused-time
                     #:pane-last-output
                     #:pane-last-output-time
                     #:pane-live-p
                     #:pane-local-options
                     #:pane-mark-bell
                     #:pane-mark-focused
                     #:pane-mark-output
                     #:pane-mark-process-exit
                     #:pane-mark-startup-failure
                     #:pane-marked
                     #:pane-non-zero-exit-p
                     #:pane-notification
                     #:pane-notify
                     #:pane-pid
                     #:pane-process-exited-p
                     #:pane-reposition
                     #:pane-screen
                     #:pane-start-command
                     #:pane-start-path
                     #:pane-startup-failed-p
                     #:pane-title
                     #:pane-tty
                     #:pane-unread-output-p
                     #:pane-width
                     #:pane-window
                     #:pane-worktree
                     #:pane-x
                     #:pane-y
                     #:respawn-pane
                     #:worktree-add-pane
                     #:worktree-attention-reasons))

(defpackage #:nerimux/layout
            (:use #:cl #:nerimux/pane)
            (:documentation
             "DOMAIN layer: the binary split-tree layout — geometry solver, resize,
    zoom, and string serialization of the tree shape (layout->string). Needs
    pane's geometry accessors and %update-pane-geometry to assign rectangles
    to leaves. layout->string alone reaches into nerimux/window
    (package-qualified, not :USEd — see the file header above) for
    window-tree.")
            (:export #:%axis-floor
                     #:+pane-min-height+
                     #:+pane-min-width+
                     #:define-layout-fold
                     #:layout-assign
                     #:layout-find-leaf
                     #:layout-find-parent
                     #:layout-leaf
                     #:layout-leaf-p
                     #:layout-leaf-pane
                     #:layout-leaves
                     #:layout-min-extent
                     #:layout-node-bounding-box
                     #:layout-split
                     #:layout-split-axis-extent
                     #:layout-split-first
                     #:layout-split-orientation
                     #:layout-split-p
                     #:layout-split-ratio
                     #:layout-split-second
                     #:layout->string
                     #:make-layout-leaf
                     #:make-layout-split
                     #:orient-case
                     #:resize-direction-orientation
                     #:resize-find-split
                     #:split-child-geometry))

(defpackage #:nerimux/window
            (:use #:cl #:nerimux/layout #:nerimux/pane)
            (:import-from #:cl-concurrent-kit #:make-lock #:with-lock-held)
            (:documentation
             "DOMAIN layer: a named collection of panes arranged over one layout tree,
    with split/select/resize/zoom operations and directional pane
    navigation. window-neighbor.lisp's pane-neighbor/pane-at-position live
    here rather than in layout because they need window-tree.")
            (:export #:%assign-window-tree
                     #:+pane-base-index+
                     #:ensure-window-fits
                     #:make-window
                     #:next-pane-id
                     #:pane-at-position
                     #:pane-neighbor
                     #:window
                     #:window-active
                     #:window-active-pane
                     #:window-automatic-rename-p
                     #:window-height
                     #:window-id
                     #:window-last-active
                     #:window-last-active-time
                     #:window-layout-cycle-index
                     #:window-local-options
                     #:window-lock
                     #:window-name
                     #:window-panes
                     #:window-refresh-panes
                     #:window-relayout
                     #:window-relayout-current
                     #:window-remove-pane
                     #:window-resize-active
                     #:window-select-pane
                     #:window-split
                     #:window-tree
                     #:window-width
                     #:window-zoom-p
                     #:window-zoom-toggle
                     #:window-zoom-tree))

(defpackage #:nerimux/session
            (:use #:cl
                  #:nerimux/ports
                  #:nerimux/layout
                  #:nerimux/window
                  #:nerimux/pane)
            (:documentation
             "DOMAIN layer: a named set of windows with one active, the process
    environment overlay a session hands to the shells it spawns, and
    session-level window bookkeeping (MRU stack, per-session index
    overrides). session-new-window/%attach-full-screen-pane build windows
    and panes directly, hence the dependency on window and pane.")
            (:export #:*global-hidden-environment-names*
                     #:*session-id-counter*
                     #:*suppress-update-environment*
                     #:*update-environment*
                     #:+default-update-environment+
                     #:all-panes
                     #:create-initial-session
                     #:get-update-environment-vars
                     #:make-session
                     #:process-environment-names
                     #:process-environment-value
                     #:process-set-environment
                     #:process-unset-environment
                     #:session-active
                     #:session-active-pane
                     #:session-active-window
                     #:session-child-environment
                     #:session-clients
                     #:session-created
                     #:session-environment
                     #:session-environment-hidden
                     #:session-environment-names
                     #:session-environment-value
                     #:session-id
                     #:session-insert-window
                     #:session-last-active
                     #:session-last-window
                     #:session-move-window
                     #:session-name
                     #:session-new-window
                     #:session-remove-window
                     #:session-select-window
                     #:session-set-environment
                     #:session-start-directory
                     #:session-swap-windows
                     #:session-touch
                     #:session-unset-environment
                     #:session-window-index
                     #:session-window-index-map
                     #:session-window-stack
                     #:session-windows
                     #:session-windows-in-index-order
                     #:set-session-window-index))
