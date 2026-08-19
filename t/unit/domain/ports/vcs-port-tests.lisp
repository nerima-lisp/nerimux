(in-package #:nerimux/test)

(describe "vcs-port"
  (it "delegates repository discovery to the installed adapter"
    (let (calls)
      (let ((nerimux/ports:*vcs-list-repositories*
              (lambda (&rest arguments)
                (push arguments calls)
                '(:repository))))
        (expect (equal '(:repository)
                       (nerimux/ports:vcs-list-repositories :query "nerimux")))
        (expect (equal '((:query "nerimux")) calls)))))

  (it "raises an error when a required adapter operation is absent"
    (let ((nerimux/ports:*vcs-status* nil))
      (signals error (nerimux/ports:vcs-status :worktree))))

  (it "keeps the canonical worktree status name and its compatibility alias aligned"
    (let ((nerimux/ports:*vcs-status*
            (lambda (worktree)
              (list :updated worktree))))
      (expect (equal '(:updated :worktree)
                     (nerimux/ports:vcs-worktree-status :worktree)))
      (expect (equal '(:updated :worktree)
                     (nerimux/ports:vcs-status :worktree)))))

  (it "preserves pane associations when the catalog is refreshed"
    (let* ((previous (nerimux/vcs:workspace-organizations))
           (pane (nerimux/model:make-pane :id 31 :title "editor"))
           (old-organization
             (nerimux/model:make-organization
              :host "vcs-host"
              :name "workspace-owner"))
           (old-repository
             (nerimux/model:make-repository
              :specification "workspace-owner/project"
              :local-path "work/project"))
           (old-worktree
             (nerimux/model:make-worktree
              :path "work/project/wt"
              :branch "feature/ui"
              :head "old-head"))
           (new-organization
             (nerimux/model:make-organization
              :host "vcs-host"
              :name "workspace-owner"))
           (new-repository
             (nerimux/model:make-repository
              :specification "workspace-owner/project"
              :local-path "work/project"))
           (new-worktree
             (nerimux/model:make-worktree
              :path "work/project/wt"
              :branch "feature/ui"
              :head "new-head")))
      (unwind-protect
           (progn
             (nerimux/model:organization-add-repository
              old-organization old-repository)
             (nerimux/model:repository-add-worktree
              old-repository old-worktree)
             (nerimux/model:worktree-add-pane old-worktree pane)
             (nerimux/model:organization-add-repository
              new-organization new-repository)
             (nerimux/model:repository-add-worktree
              new-repository new-worktree)
             (nerimux/vcs:set-workspace-organizations
              (list old-organization))
             (nerimux/vcs:set-workspace-organizations
              (list new-organization))
             (expect (eq new-worktree
                         (nerimux/model:pane-worktree pane)))
             (expect (member pane
                             (nerimux/model:worktree-panes new-worktree)
                             :test #'eq)))
        (nerimux/vcs:set-workspace-organizations previous)))))
