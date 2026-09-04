(in-package #:nerimux/test/vcs)

(describe "vcs worktree status"
  (it "marks an absent worktree without querying VCS"
    (let* ((path
             (namestring
              (merge-pathnames
               (format nil "nerimux-missing-worktree-~D/" (random 1000000))
               (host-kit:temporary-directory))))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path path))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository
              :path path
              :branch "feature/ui"
              :status :stale
              :dirty-p t
              :conflict-p t
              :ahead 3
              :behind 2)))
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (expect (null (probe-file path)))
      (nerimux/vcs:worktree-status worktree)
      (expect (nerimux/workspace-model:worktree-missing-p worktree))
      (expect (null (nerimux/workspace-model:worktree-status worktree)))
      (expect (not (nerimux/workspace-model:worktree-dirty-p worktree)))
      (expect (not (nerimux/workspace-model:worktree-conflict-p worktree)))
      (expect (zerop (nerimux/workspace-model:worktree-ahead worktree)))
      (expect (zerop (nerimux/workspace-model:worktree-behind worktree)))
      (expect (not (nerimux/workspace-model:repository-dirty-p repository)))
      (expect
       (not (nerimux/workspace-model:repository-conflict-p repository))))))
