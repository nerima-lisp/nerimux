;;; Application command and public facade packages.

(defpackage #:nerimux/commands
  (:use #:cl
        #:nerimux/config
        #:nerimux/pty
        #:nerimux/terminal
        #:nerimux/model
        #:nerimux/hooks)
  ;; cl-concurrent-kit's WITH-TIMEOUT / OPERATION-TIMED-OUT in commands-shell.lisp
  ;; and commands-pipe-pane.lisp stay qualified, next to the TIMEOUT-SECONDS
  ;; parameter they bound.  Under bordeaux-threads they HAD to: the condition was
  ;; named TIMEOUT, which collided with the ordinary parameter name in both files.
  ;; OPERATION-TIMED-OUT no longer collides, so this is now a readability choice
  ;; rather than a forced one.
  (:import-from #:cl-concurrent-kit #:with-lock-held)
  (:documentation
   "APPLICATION layer: the tmux commands themselves, as operations on the domain
    model.  Pane and window lifecycle (kill, resize, swap, break, join, respawn), the
    whole of copy mode (motion, selection, search, jump, yank and its pipe variants),
    capture-pane, pipe-pane, send-keys, and run-shell/if-shell.  Each is a plain
    function taking model objects; nothing here parses argv or knows a client
    exists — that is the dispatch layer in the nerimux package.")
  (:export
   #:kill-pane
   #:close-pane-pty
   #:kill-window
   #:resize-pane
   #:rename-window
   #:select-window-by-number
   #:copy-mode-enter
   #:copy-mode-exit
   #:copy-mode-copy-selection-no-cancel
   #:copy-mode-copy-selection-no-clear
   #:copy-mode-pipe-no-cancel #:copy-mode-pipe-no-clear #:copy-mode-pipe-and-cancel
   #:copy-mode-copy-pipe-no-clear #:copy-mode-copy-pipe-line
   #:copy-mode-copy-pipe-line-and-cancel
   #:copy-mode-rectangle-on #:copy-mode-rectangle-off
   #:copy-mode-cursor-centre-vertical #:copy-mode-cursor-centre-horizontal
   #:copy-mode-scroll
   #:copy-mode-move-cursor
   #:copy-mode-set-cursor
   #:copy-mode-begin-selection
   #:copy-mode-cancel-selection
   #:copy-mode-other-end
   #:copy-mode-jump-to-mark
   #:copy-mode-clear-selection
   #:copy-mode-select-word
   #:copy-mode-yank
   #:copy-mode-word-forward
   #:copy-mode-word-backward
   #:copy-mode-word-end
   #:copy-mode-space-forward
   #:copy-mode-space-backward
   #:copy-mode-space-end
   #:copy-mode-line-start
   #:copy-mode-back-to-indentation
   #:copy-mode-line-end
   #:copy-mode-top
   #:copy-mode-bottom
   #:copy-mode-high
   #:copy-mode-middle
   #:copy-mode-low
   #:copy-mode-page-up
   #:copy-mode-page-down
   #:copy-mode-half-page-up
   #:copy-mode-half-page-down
   #:copy-mode-scroll-up-line
   #:copy-mode-scroll-down-line
   #:copy-mode-scroll-middle
   #:copy-mode-scroll-down-and-cancel
   #:copy-mode-page-down-and-cancel
   #:copy-mode-cursor-down-and-cancel
   #:copy-mode-selection-mode
   #:copy-mode-scroll-to-mouse
   #:copy-mode-previous-paragraph
   #:copy-mode-next-paragraph
   #:copy-mode-begin-line-selection
   #:copy-mode-goto-line
   #:copy-mode-copy-end-of-line
   #:copy-mode-copy-end-of-line-and-cancel
   #:copy-mode-copy-line
   #:copy-mode-copy-line-and-cancel
   #:copy-mode-jump-forward
   #:copy-mode-jump-backward
   #:copy-mode-jump-to
   #:copy-mode-jump-to-backward
   #:copy-mode-jump-again
   #:copy-mode-jump-reverse
   #:*copy-mode-last-jump*
   #:copy-mode-search-forward
   #:copy-mode-search-backward
   #:copy-mode-search-next
   #:copy-mode-search-prev
   #:copy-mode-search-forward-incremental
   #:copy-mode-search-backward-incremental
   #:copy-mode-next-matching-bracket
   #:copy-mode-previous-matching-bracket
   #:copy-mode-toggle-rectangle
   #:copy-mode-set-mark
   #:copy-mode-stop-selection
   #:copy-mode-toggle-position
   #:copy-mode-previous-prompt
   #:copy-mode-next-prompt
   #:copy-mode-half-page-down-and-cancel
   #:copy-mode-copy-pipe-end-of-line-no-cancel
   #:copy-mode-append-selection
   #:copy-mode-append-selection-and-cancel
   #:copy-mode-copy-pipe
   #:copy-mode-copy-pipe-no-cancel
   #:copy-mode-copy-pipe-end-of-line
   #:rename-session
   #:run-shell
   #:if-shell
   #:swap-pane
   #:swap-two-panes
   #:capture-pane
   #:break-pane
   #:join-pane
   #:pipe-pane-open
   #:pipe-pane-close
   #:pipe-pane-write
   #:send-keys-to-pane
   #:tokenize-command-string))

(defpackage #:nerimux
  (:use #:cl
        #:nerimux/config
        #:nerimux/pty
        #:nerimux/terminal
        #:nerimux/model
        #:nerimux/renderer
        #:nerimux/input
        #:nerimux/commands
        #:nerimux/prompt
        #:nerimux/protocol
        #:nerimux/transport
        #:nerimux/net)
  ;; The reader/timer thread machinery in runtime*.lisp, and the wait-for
  ;; channel lock (runtime.lisp).  runtime.lisp calls sb-thread:join-thread
  ;; directly for its :TIMEOUT argument, so no join/alive-p name is imported
  ;; here.
  (:import-from #:cl-concurrent-kit
                #:make-thread
                #:make-lock
                #:with-lock-held
                #:make-condition-variable
                #:condition-wait
                #:condition-notify)
  (:documentation
   "BOOTSTRAP layer: the assembled program, and the widest package in the system.
    Four things live here because each one needs the whole stack below it and none of
    them can be reached from the domain: the binary entry point and startup flag
    handling; the server and client halves of detach-attach, with the session
    registry that implements nerimux/repository and the per-pane reader and status
    timer threads; the event loop that turns keystrokes and mouse reports into
    commands; and the command dispatcher that resolves -t targets and argv into calls
    on nerimux/commands.  Nothing depends on this package — it is the top of the
    graph, which is why it may see everything.")
  (:export
   #:main
   #:*server-sessions*
   #:*server-marked-pane*
   #:*client-read-only*
   #:server-add-session
   #:server-find-session
   #:server-remove-session
   #:server-all-sessions
   #:server-current-session
   #:in-memory-session-store
   #:*session-groups*
   #:*group-id-counter*
   #:server-new-session-in-group
   #:new-session
   #:resolve-target
   #:resolve-target-context
   #:find-session-by-target
   #:find-window-by-target
   #:find-pane-by-target
   #:*wait-channels*
   #:%ensure-channel
   #:wait-for-channel
   #:signal-channel
   #:lock-channel
   #:unlock-channel
   #:*message-log*
   #:add-message-log
   #:*prompt-history*
   #:add-prompt-history
   #:save-prompt-history
   #:load-prompt-history
   #:*clock-mode-pane-id*
   #:stop-reader-threads
   #:start-status-timer
   #:*runtime-restore-report*
   #:*runtime-save-report*
   #:+max-message-log-entries+
   #:+max-prompt-history+))
