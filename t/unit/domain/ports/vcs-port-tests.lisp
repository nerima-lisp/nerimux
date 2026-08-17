(in-package #:cl-tmux/test)

(describe "vcs-port"
  (it "delegates repository discovery to the installed adapter"
    (let (calls)
      (let ((cl-tmux/ports:*vcs-list-repositories*
              (lambda (&rest arguments)
                (push arguments calls)
                '(:repository))))
        (expect (equal '(:repository)
                       (cl-tmux/ports:vcs-list-repositories :query "cl-tmux")))
        (expect (equal '((:query "cl-tmux")) calls)))))

  (it "raises an error when a required adapter operation is absent"
    (let ((cl-tmux/ports:*vcs-status* nil))
      (signals error (cl-tmux/ports:vcs-status :worktree))))

  (it "keeps the canonical worktree status name and its compatibility alias aligned"
    (let ((cl-tmux/ports:*vcs-status*
            (lambda (worktree)
              (list :updated worktree))))
      (expect (equal '(:updated :worktree)
                     (cl-tmux/ports:vcs-worktree-status :worktree)))
      (expect (equal '(:updated :worktree)
                     (cl-tmux/ports:vcs-status :worktree)))))

  (it "preserves pane associations when the catalog is refreshed"
    (let* ((previous (cl-tmux/vcs:workspace-organizations))
           (pane (cl-tmux/model:make-pane :id 31 :title "editor"))
           (old-organization
             (cl-tmux/model:make-organization
              :host "vcs-host"
              :name "workspace-owner"))
           (old-repository
             (cl-tmux/model:make-repository
              :specification "workspace-owner/project"
              :local-path "work/project"))
           (old-worktree
             (cl-tmux/model:make-worktree
              :path "work/project/wt"
              :branch "feature/ui"
              :head "old-head"))
           (new-organization
             (cl-tmux/model:make-organization
              :host "vcs-host"
              :name "workspace-owner"))
           (new-repository
             (cl-tmux/model:make-repository
              :specification "workspace-owner/project"
              :local-path "work/project"))
           (new-worktree
             (cl-tmux/model:make-worktree
              :path "work/project/wt"
              :branch "feature/ui"
              :head "new-head")))
      (unwind-protect
           (progn
             (cl-tmux/model:organization-add-repository
              old-organization old-repository)
             (cl-tmux/model:repository-add-worktree
              old-repository old-worktree)
             (cl-tmux/model:worktree-add-pane old-worktree pane)
             (cl-tmux/model:organization-add-repository
              new-organization new-repository)
             (cl-tmux/model:repository-add-worktree
              new-repository new-worktree)
             (cl-tmux/vcs:set-workspace-organizations
              (list old-organization))
             (cl-tmux/vcs:set-workspace-organizations
              (list new-organization))
             (expect (eq new-worktree
                         (cl-tmux/model:pane-worktree pane)))
             (expect (member pane
                             (cl-tmux/model:worktree-panes new-worktree)
                             :test #'eq)))
        (cl-tmux/vcs:set-workspace-organizations previous)))))
