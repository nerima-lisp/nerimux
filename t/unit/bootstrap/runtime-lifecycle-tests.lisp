(in-package #:cl-tmux/test)

(describe "runtime lifecycle"

  (it "uses a safe state filename and honors an explicit override"
    (let ((cl-tmux::*runtime-server-name* "origin/main worktree"))
      (expect (string= "origin_main_worktree"
                       (cl-tmux::%runtime-safe-server-name
                        cl-tmux::*runtime-server-name*))))
    (with-temporary-posix-environment-variable
        ("CL_TMUX_RUNTIME_STATE" "/tmp/cl-tmux-runtime-test.sexp")
      (expect
       (string= "/tmp/cl-tmux-runtime-test.sexp"
                (namestring (cl-tmux::%runtime-state-path))))))

  (it "matches current panes and reports orphaned and lost state"
    (let* ((current-pane (make-pane :id 7 :title "editor"))
           (lost-pane (make-pane :id 9 :title "new"))
           (window (make-window :id 3 :name "main"
                                :panes (list current-pane lost-pane)
                                :active current-pane))
           (session (make-session :id 2 :name "workspace"
                                  :windows (list window)
                                  :active window))
           (state
             (list :id 2
                   :name "restored"
                   :active-window-id 3
                   :windows
                   (list
                    (list :id 3
                          :name "editor"
                          :active-pane-id 7
                          :panes
                          (list
                           (list :id 7
                                 :title "editor"
                                 :start-command "nvim"
                                 :unread-output-p t)
                           (list :id 8 :title "closed"))))))
           (report (cl-tmux::%runtime-restore-session-state session state)))
      (expect (string= "restored" (session-name session)))
      (expect (string= "editor" (window-name window)))
      (expect (string= "nvim" (cl-tmux/model:pane-start-command current-pane)))
      (expect (cl-tmux/model:pane-unread-output-p current-pane))
      (expect (= 1 (getf report :matched-window-count)))
      (expect (= 1 (getf report :matched-pane-count)))
      (expect (equal '(8) (getf report :orphan-panes)))
      (expect (equal '(9) (getf report :lost-panes)))
      (let ((recovery-items (getf report :recovery-items)))
        (expect (= 2 (length recovery-items)))
        (expect (eq :orphan-pane (getf (first recovery-items) :kind)))
        (expect (= 8 (getf (first recovery-items) :pane-id)))
        (expect (eq :lost-pane (getf (second recovery-items) :kind)))
        (expect (= 9 (getf (second recovery-items) :pane-id))))
      (expect (eq current-pane (window-active-pane window)))
      (expect (eq window (session-active-window session)))))

  (it "rebuilds a bare repository worktree catalog from a saved snapshot"
    (let* ((previous (cl-tmux/vcs:workspace-organizations))
           (pane (make-pane :id 17 :title "editor"))
           (window (make-window :id 4 :name "main"
                                :panes (list pane)
                                :active pane))
           (session (make-session :id 5 :name "workspace"
                                  :windows (list window)
                                  :active window))
           (state
             (list :organization-id "vcs-host/workspace-owner"
                   :organization-host "vcs-host"
                   :organization-name "workspace-owner"
                   :repository-id "vcs-host/workspace-owner/project"
                   :repository-specification "vcs-host/workspace-owner/project"
                   :repository-local-path "work/project"
                   :worktree-id "work/project/wt|feature/ui|new-head"
                   :worktree-path "work/project/wt"
                   :worktree-branch "feature/ui"
                   :worktree-head "new-head"
                   :worktree-status :clean
                   :dirty-p nil
                   :conflict-p nil
                   :ahead 0
                   :behind 0
                   :bare-p nil
                   :locked-p nil
                   :prunable-p nil
                   :missing-p nil
                   :pane-ids '(17))))
      (unwind-protect
           (progn
             (cl-tmux/vcs:set-workspace-organizations nil)
             (let* ((report
                      (cl-tmux::%runtime-restore-worktree-catalog
                       session
                       (list state)))
                    (organizations
                      (cl-tmux/vcs:workspace-organizations))
                    (organization (first organizations))
                    (repository
                      (first (cl-tmux/model:organization-repositories
                              organization)))
                    (worktree
                      (first (cl-tmux/model:repository-worktrees
                              repository))))
               (expect (getf report :catalog-restored-p))
               (expect (eq :snapshot (getf report :catalog-source)))
               (expect (= 1 (getf report :matched-worktree-count)))
               (expect (string= "vcs-host"
                                (cl-tmux/model:organization-host organization)))
               (expect (string= "vcs-host/workspace-owner/project"
                                (cl-tmux/model:repository-specification
                                 repository)))
               (expect (string= "work/project/wt"
                                (cl-tmux/model:worktree-path worktree)))
               (expect (eq worktree (cl-tmux/model:pane-worktree pane)))))
        (cl-tmux/vcs:set-workspace-organizations previous)))))
