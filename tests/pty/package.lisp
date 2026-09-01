;;;; Package for nerimux/pty-test, the real-PTY suite split out of nerimux/test.
;;;;
;;;; R9.2 of docs/notes/workspace-requirements.md: `nix flake check` runs only
;;;; nerimux/test, whose sandboxed builder has no /dev/ptmx.  Every case
;;;; registered under this package spawns (or once spawned) a real PTY-backed
;;;; shell via forkpty-with-shell -- directly, through WITH-PTY-SHELL /
;;;; WITH-PTY-AVAILABLE, or through WITH-SESSION (which wraps
;;;; create-initial-session).  The sandbox-safe argument-assembly, port-stub,
;;;; and pipe-fd cases that used to share a file with them stayed behind in
;;;; nerimux/test; only the genuinely PTY-spawning cases moved here.
;;;;
;;;; The import list mirrors tests/package.lisp's on purpose: every case below is a
;;;; relocation of code that uses the same public surface.  Keeping the import
;;;; shape aligned lets ASDF compile this system independently of the normal
;;;; sandbox-safe test system.
(defpackage #:nerimux/pty-test
  ;; The test framework is cl-weave, used natively: every file registers its
  ;; own top-level (describe "name" (it "case" ...) ...) block directly with
  ;; cl-weave's global registry.  Because this system loads only its own test
  ;; components, RUN-PTY-TESTS's cl-weave:run-all sees only the suites this
  ;; package registers.
  (:use #:cl)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave
                #:it #:it-only #:it-concurrent #:it-sequential
                #:it-each #:describe-each
                #:describe-only #:describe-concurrent #:describe-sequential
                #:expect #:expect-not
                #:signals #:finishes #:fail #:skip
                #:before-each #:after-each #:before-all #:after-all #:around-each)
  (:import-from #:nerimux/terminal
                #:make-screen
                #:screen-resize
                #:screen-process-bytes
                #:screen-cell
                #:screen-display-cell
                #:screen-cursor-x
                #:screen-cursor-y
                #:screen-width
                #:screen-height
                #:screen-clear-dirty
                #:cell-char
                #:cell-fg
                #:cell-bg
                #:cell-attrs
                #:cell-width)
  (:import-from #:nerimux/terminal/types
                #:screen-copy-mode-p
                #:screen-copy-offset
                #:screen-scrollback
                #:screen-copy-selecting
                #:screen-copy-mark
                #:screen-copy-mark-offset
                #:screen-copy-cursor
                #:screen-title
                #:screen-copy-line-selection-p
                #:screen-copy-rect-select-p
                #:screen-app-cursor-keys
                #:screen-dirty-p
                #:char-width
                #:screen-p)
  (:import-from #:nerimux/pane
                #:make-pane
                #:pane-feed
                #:pane-screen
                #:pane-id
                #:pane-x #:pane-y #:pane-width #:pane-height #:pane-fd #:pane-pid
                #:pane-live-p
                #:respawn-pane
                #:pane-window
                #:pane-marked
                #:pane-title
                #:pane-local-options
                #:pane-reposition
                #:pane-live-p)
  (:import-from #:nerimux/layout
                #:make-layout-leaf
                #:make-layout-split
                #:layout-leaf-pane
                #:layout-leaves
                #:layout-node-bounding-box
                #:layout-find-leaf
                #:layout-find-parent
                #:layout->string)
  (:import-from #:nerimux/window
                #:window-panes
                #:window-active-pane
                #:window-select-pane
                #:window-split
                #:window-relayout
                #:window-relayout-current
                #:window-remove-pane
                #:window-resize-active
                #:window-refresh-panes
                #:window-tree
                #:make-window
                #:window-id
                #:window-name
                #:window-width #:window-height
                #:pane-neighbor
                #:pane-at-position
                #:window-lock
                #:window-last-active-time
                #:window-automatic-rename-p
                #:window-last-active
                #:window-local-options
                #:window-layout-cycle-index)
  (:import-from #:nerimux/session
                #:create-initial-session
                #:session-windows
                #:session-active-window
                #:session-select-window
                #:session-new-window
                #:session-active-pane
                #:session-environment
                #:session-environment-value
                #:session-environment-names
                #:session-set-environment
                #:session-unset-environment
                #:session-child-environment
                #:all-panes
                #:make-session
                #:session-name
                #:session-last-window
                #:session-move-window
                #:session-swap-windows
                #:session-clients
                #:*update-environment*
                #:get-update-environment-vars
                #:session-id
                #:session-last-active
                #:session-touch
                #:session-insert-window)
  (:import-from #:nerimux
                #:*server-sessions*)
  (:import-from #:nerimux/protocol
                #:+msg-attach+ #:+msg-key+ #:+msg-resize+
                #:+msg-detach+ #:+msg-frame+ #:+msg-bye+ #:+msg-command+ #:+msg-reply+
                #:+header-size+
                #:encode-frame #:decode-frame
                #:msg-attach #:msg-key #:msg-resize #:msg-detach #:msg-frame #:msg-bye
                #:msg-command #:msg-reply
                #:encode-command-payload #:decode-command-payload
                #:u16-octets-pair
                #:decode-size #:decode-text #:to-octets)
  (:import-from #:nerimux/transport
                #:send-frame #:read-frame #:with-incoming-frame)
  (:import-from #:nerimux/net
                #:make-listener #:accept-connection #:connect-to
                #:socket-stream #:socket-fd #:close-socket
                #:unix-socket-available-p)
  (:import-from #:nerimux/pty
                #:forkpty-with-shell
                #:pty-write
                #:pty-read-blocking-into
                #:pty-close
                #:pty-child-exit-status
                #:select-fds
                #:set-pty-size
                #:terminal-size
                #:install-pty-port
                #:+default-term-rows+
                #:+default-term-cols+)
  (:export #:run-pty-tests))
