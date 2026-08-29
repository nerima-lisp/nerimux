(defpackage #:nerimux/vcs
  (:use #:cl)
  (:documentation
   "INFRASTRUCTURE layer: the direct cl-vcs-kit integration.  Translates ghq and
    worktree observations into the pure repository hierarchy and installs the
    corresponding domain ports.  cl-vcs-kit is a required system dependency;
    the availability predicate reports whether its package is currently loaded
    for command-level error reporting.")
  (:export
   #:vcs-package-available-p
   #:scan-repositories
   #:list-repository-worktrees
   #:worktree-status
   #:refresh-repository-status
   #:scan-repositories-async
   #:refresh-repositories-async
   #:refresh-workspace-status-async
   #:workspace-organizations
   #:set-workspace-organizations
   #:refresh-workspace-organizations-async
   ;; cwd-match auto-registration (FR-002): resolve a directory's git
   ;; repository synchronously and fold it into the live catalog, for the
   ;; attach path to use before the next full scan would otherwise find it.
   #:resolve-directory-organizations
   #:merge-workspace-organizations
   #:ghq-root-directory
   #:create-worktree
   #:delete-worktree
   #:create-worktree-async
   #:delete-worktree-async
   #:lock-worktree
   #:unlock-worktree
   #:prune-worktrees
   #:lock-worktree-async
   #:unlock-worktree-async
   #:prune-worktrees-async
   ;; Explicit fetch (R7.1). AHEAD/BEHIND read the local remote-tracking ref, so
   ;; they only move when someone fetches; these are how that is asked for.
   #:fetch-repository-async
   #:fetch-organization-async
   ;; Inline tree-row expansion (Wave B): on-demand recent-commit history.
   #:refresh-worktree-commits-async
   ;; Inline tree-row expansion (Wave C): on-demand per-file diff.
   #:refresh-worktree-file-diff-async
   ;; Git write operations (FR-012). Every mutating subcommand goes through the
   ;; one pair below rather than getting an entry point each: cl-vcs-kit
   ;; generates them all with the same (repository &rest arguments) shape, so a
   ;; per-command wrapper would be fifteen copies of one function.
   #:git-write-operation
   #:git-write-operation-async
   #:list-worktree-stashes))
