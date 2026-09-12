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
   #:resolve-directory-organizations
   #:merge-workspace-organizations
   #:ghq-root-directory
   #:create-worktree
   #:delete-worktree
   #:create-worktree-async
   #:create-detached-worktree-async
   #:detached-worktree-result
   #:detached-worktree-result-path
   #:detached-worktree-result-head
   #:detached-worktree-result-worktree
   #:detached-worktree-result-refresh-error
   #:detached-worktree-result-fetch-error
   #:refreshed-worktree-successor
   #:worktree-parent-directory
   #:delete-worktree-async
   #:read-worktree-prune-snapshot-async
   #:validate-worktree-prune-snapshot
   #:worktree-prune-snapshot-changed-files
   #:worktree-delete-result
   #:worktree-delete-result-removed-p
   #:worktree-delete-result-error
   #:worktree-delete-result-refresh-error
   #:lock-worktree
   #:unlock-worktree
   #:prune-worktrees
   #:lock-worktree-async
   #:unlock-worktree-async
   #:prune-worktrees-async
   #:fetch-repository-async
   #:fetch-organization-async
   #:refresh-worktree-commits-async
   #:refresh-worktree-file-diff-async
   #:read-worktree-log-async
   #:read-worktree-diff-async
   #:read-worktree-branches-async
   #:read-worktree-tags-async
   #:worktree-upstream
   #:git-write-operation
   #:git-write-operation-async
   #:list-worktree-stashes))
