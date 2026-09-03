(defpackage #:nerimux/pty-test
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
