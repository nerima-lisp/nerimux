;;;; The top-level bootstrap package.
;;;;
;;;; W6: this file used to also load every other package-*.lisp fragment at
;;;; runtime (each now lives beside its own code as a real ASDF component,
;;;; see nerimux.asd) and define four server-dispatch macros and one declaim
;;;; that had nothing to do with declaring a package (see
;;;; server-dispatch-macros.lisp and domain/model/window-definitions.lisp).

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

(declaim (special +transient-definitions+))
