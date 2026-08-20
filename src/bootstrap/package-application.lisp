;;; Application command and public facade packages.

(defpackage #:nerimux/commands
  (:use #:cl
        #:nerimux/config
        #:nerimux/pty
        #:nerimux/terminal
        #:nerimux/model)
  ;; cl-concurrent-kit's WITH-TIMEOUT / OPERATION-TIMED-OUT in
  ;; commands-pipe-pane.lisp stay qualified, next to the TIMEOUT-SECONDS
  ;; parameter they bound.  Under bordeaux-threads they HAD to: the condition was
  ;; named TIMEOUT, which collided with the ordinary parameter name.
  ;; OPERATION-TIMED-OUT no longer collides, so this is now a readability choice
  ;; rather than a forced one.
  (:documentation
   "APPLICATION layer: operations on the domain model, as plain functions taking
    model objects.  What is left after the tmux command table was removed: copy
    mode, the command-line tokenizer, pipe-pane, and close-pane-pty.  The pane and
    window lifecycle commands this package was built around (kill, resize, swap,
    break, join, respawn) went with the dispatcher that called them, or are dead
    code awaiting a further pass.  Nothing here parses argv or knows a client
    exists.")
  (:export
   #:close-pane-pty
   #:copy-mode-enter
   #:copy-mode-exit
   #:copy-mode-scroll
   #:copy-mode-move-cursor
   #:copy-mode-begin-selection
   #:copy-mode-cancel-selection
   #:copy-mode-yank
   #:copy-mode-search-forward
   #:copy-mode-search-backward
   #:copy-mode-search-next
   #:copy-mode-search-prev
   #:pipe-pane-open
   #:pipe-pane-close
   #:pipe-pane-write
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
