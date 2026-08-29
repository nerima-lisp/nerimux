;;; Application command and public facade packages.

(defpackage #:nerimux/commands
  (:use #:cl
        #:nerimux/terminal
        #:nerimux/pane)
  ;; NOT #:nerimux/pty.  That is infrastructure, and this is application: the one
  ;; PTY operation left here (close on pane exit) goes through nerimux/ports
  ;; instead, the same indirection domain/model/pane-spawn already uses for the
  ;; symmetric spawn side.  The ports are bound to exactly these functions by
  ;; nerimux/pty:install-pty-port, so this is the same call with one hop -- what
  ;; changes is that the dependency now points downward.
  (:documentation
   "APPLICATION layer: operations on the domain model, as plain functions taking
    model objects.  Three clusters remain: copy mode, the command-line tokenizer,
    and close-pane-pty.  The pane and window lifecycle commands this package was
    built around (kill, resize, swap, break, join, respawn) went with the
    dispatcher that called them.  Nothing here parses argv or knows a client
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
   #:tokenize-command-string #:retire-pane-pty))

(defpackage #:nerimux
  (:use #:cl
        #:nerimux/ports
        #:nerimux/pty
        #:nerimux/terminal
        #:nerimux/workspace-model #:nerimux/pane
        #:nerimux/window #:nerimux/session
        #:nerimux/renderer
        #:nerimux/input
        #:nerimux/commands
        #:nerimux/protocol
        #:nerimux/transport
        #:nerimux/net)
  ;; The reader thread machinery in runtime*.lisp, and the wait-for channel lock
  ;; (runtime.lisp).  runtime.lisp calls sb-thread:join-thread directly for its
  ;; :TIMEOUT argument, so no join/alive-p name is imported here.
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
    handling; the server and client halves of detach-attach, with the single-session
    registry and the per-pane reader threads; the event loop that turns keystrokes
    into commands; and the command dispatcher that resolves -t targets and argv into
    calls on nerimux/commands.  Nothing depends on this package — it is the top of
    the graph, which is why it may see everything.")
  (:export
   #:main
   #:*server-sessions*
   #:server-add-session
   #:server-find-session
   #:find-session-by-target
   #:find-window-by-target
   #:find-pane-by-target
   #:*wait-channels*
   #:%ensure-channel
   #:wait-for-channel
   #:signal-channel
   #:lock-channel
   #:unlock-channel
   #:stop-reader-threads))
