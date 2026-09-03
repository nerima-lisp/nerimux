(defpackage #:nerimux/commands
  (:use #:cl
        #:nerimux/terminal
        #:nerimux/pane)
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
