;;; Domain abstraction packages.

(defpackage #:nerimux/ports
  (:use #:cl)
  (:documentation
   "DOMAIN layer: the PTY port, one half of the dependency inversion that keeps the
    model free of the operating system.  Holds the *spawn-pty* / *write-pty* /
    *resize-pty* / *close-pty* function cells that nerimux/model calls, and that the
    INFRASTRUCTURE package nerimux/pty fills in via install-pty-port at server or
    test setup time.")
  (:export
   ;; POSIX symbol lookup, used by domain and application alike.
   #:find-posix-function
   ;; Process environment / cwd, named here so domain code does not scatter raw
   ;; SB-EXT calls.  Wrappers, not port variables -- see posix-port.lisp.
   #:environment-value
   #:environment-entries
   #:working-directory
   #:*spawn-pty*
   #:*write-pty*
   #:*resize-pty*
   #:*close-pty*
   #:spawn-pty
   #:write-pty
   #:resize-pty
   #:close-pty
   #:*vcs-list-repositories*
   #:*vcs-list-worktrees*
   #:*vcs-status*
   #:*vcs-scan-async*
   #:*vcs-create-worktree*
   #:*vcs-delete-worktree*
   #:vcs-list-repositories
   #:vcs-list-worktrees
   #:vcs-worktree-status
   #:vcs-status
   #:vcs-scan-async
   #:vcs-create-worktree
   #:vcs-delete-worktree))

(defpackage #:nerimux/repository
  (:use #:cl)
  (:documentation
   "DOMAIN layer: the session-persistence protocol, the other half of the dependency
    inversion.  Session is the aggregate root — windows and panes are reachable only
    through their owning session — so this is the complete set of operations a store
    must offer.  The in-memory implementation over *server-sessions* lives in the
    BOOTSTRAP layer (bootstrap/session-registry.lisp).")
  (:export
   #:repo-find-session
   #:repo-add-session
   #:repo-remove-session
   #:repo-all-sessions
   #:repo-current-session))
