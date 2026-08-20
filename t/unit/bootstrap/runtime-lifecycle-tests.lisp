(in-package #:nerimux/test)

(describe "runtime lifecycle"

  (it "uses a safe state filename and honors an explicit override"
    (let ((nerimux::*runtime-server-name* "origin/main worktree"))
      (expect (string= "origin_main_worktree"
                       (nerimux::%runtime-safe-server-name
                        nerimux::*runtime-server-name*))))
    ;; NERIMUX_RUNTIME_STATE names a DIRECTORY, not a literal file -- it is
    ;; shared with %runtime-log-path (see the fix below), so it can no longer
    ;; be returned verbatim as a complete path or both functions would
    ;; resolve to the identical file.  It gets the same
    ;; nerimux/<name>.runtime.lisp suffix the XDG branch applies.
    (with-temporary-posix-environment-variable
        ("NERIMUX_RUNTIME_STATE" "/tmp/nerimux-runtime-test-dir")
      (let ((nerimux::*runtime-server-name* "default"))
        (expect
         (string= "/tmp/nerimux-runtime-test-dir/nerimux/default.runtime.lisp"
                  (namestring (nerimux::%runtime-state-path)))))))

  (it "resolves the log path under the NERIMUX_RUNTIME_STATE override the same way the state path does, as a distinct file"
    ;; Was a correctness bug: both functions used to return the override
    ;; verbatim, so setting NERIMUX_RUNTIME_STATE made the session-state
    ;; snapshot and the raw server log resolve to the SAME path -- writing
    ;; one would clobber/interleave with the other, corrupting whichever
    ;; %runtime-restore-* later read back as Lisp data.  Fixed by treating
    ;; the override as a state-home directory, like the XDG branch, so the
    ;; two functions' distinct filename suffixes keep them apart.
    (with-temporary-posix-environment-variable
        ("NERIMUX_RUNTIME_STATE" "/tmp/nerimux-log-test-dir")
      (let ((nerimux::*runtime-server-name* "myserver"))
        (let ((state-path (namestring (nerimux::%runtime-state-path)))
              (log-path (namestring (nerimux::%runtime-log-path "myserver"))))
          (expect
           (string= "/tmp/nerimux-log-test-dir/nerimux/myserver.runtime.lisp"
                    state-path))
          (expect
           (string= "/tmp/nerimux-log-test-dir/nerimux/myserver.log"
                    log-path))
          (expect (string/= state-path log-path))))))

  (it "resolves the log path under XDG_STATE_HOME to the same directory as the state path, differing only in suffix"
    (with-temporary-posix-environment-variable ("NERIMUX_RUNTIME_STATE" nil)
      (with-temporary-posix-environment-variable
          ("XDG_STATE_HOME" "/tmp/nerimux-log-xdg-test")
        (let ((nerimux::*runtime-server-name* "myserver"))
          (expect
           (string= "/tmp/nerimux-log-xdg-test/nerimux/myserver.runtime.lisp"
                    (namestring (nerimux::%runtime-state-path))))
          (expect
           (string= "/tmp/nerimux-log-xdg-test/nerimux/myserver.log"
                    (namestring (nerimux::%runtime-log-path "myserver"))))))))

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
           (report (nerimux::%runtime-restore-session-state session state)))
      (expect (string= "restored" (session-name session)))
      (expect (string= "editor" (window-name window)))
      (expect (string= "nvim" (nerimux/model:pane-start-command current-pane)))
      (expect (nerimux/model:pane-unread-output-p current-pane))
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
    (let* ((previous (nerimux/vcs:workspace-organizations))
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
             (nerimux/vcs:set-workspace-organizations nil)
             (let* ((report
                      (nerimux::%runtime-restore-worktree-catalog
                       session
                       (list state)))
                    (organizations
                      (nerimux/vcs:workspace-organizations))
                    (organization (first organizations))
                    (repository
                      (first (nerimux/model:organization-repositories
                              organization)))
                    (worktree
                      (first (nerimux/model:repository-worktrees
                              repository))))
               (expect (getf report :catalog-restored-p))
               (expect (eq :snapshot (getf report :catalog-source)))
               (expect (= 1 (getf report :matched-worktree-count)))
               (expect (string= "vcs-host"
                                (nerimux/model:organization-host organization)))
               (expect (string= "vcs-host/workspace-owner/project"
                                (nerimux/model:repository-specification
                                 repository)))
               (expect (string= "work/project/wt"
                                (nerimux/model:worktree-path worktree)))
               (expect (eq worktree (nerimux/model:pane-worktree pane)))))
        (nerimux/vcs:set-workspace-organizations previous)))))
