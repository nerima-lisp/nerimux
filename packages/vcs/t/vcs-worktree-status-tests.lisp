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

(describe "vcs worktree stash reading"
  (it "applies the stashes the update was read beside, and only those"
    (let* ((repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/stashes"
              :local-path "/tmp/nerimux-stash-reading/"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository
              :path "/tmp/nerimux-stash-reading"
              :branch "main")))
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (nerimux/vcs::%apply-worktree-status
       repository
       (nerimux/vcs::%make-worktree-status-update
        :path "/tmp/nerimux-stash-reading" :ahead 0 :behind 0
        :stashes (cons :ready (list "stash@{0} on main"))))
      (expect (eq :ready (nerimux/workspace-model:worktree-stashes-state worktree)))
      (expect (equal (list "stash@{0} on main")
                     (nerimux/workspace-model:worktree-stashes worktree)))
      ;; An update whose pass took no reading leaves the last one in place
      ;; instead of picking up a reading a discarded capture left behind.
      (nerimux/vcs::%apply-worktree-status
       repository
       (nerimux/vcs::%make-worktree-status-update
        :path "/tmp/nerimux-stash-reading" :ahead 0 :behind 0))
      (expect (eq :ready (nerimux/workspace-model:worktree-stashes-state worktree)))
      (expect (equal (list "stash@{0} on main")
                     (nerimux/workspace-model:worktree-stashes worktree))))))
(describe "vcs worktree status failures"
  (it "applies a read error when diagnostics signal"
    (let* ((path (namestring (host-kit:temporary-directory)))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/status-read-error"
              :local-path path))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path path))
           (stderr
             (format nil "fatal: bad~%path~Ctext~Cmore~C detail"
                     #\Return #\Tab (code-char 27)))
           (expected "git status exited 128: fatal: bad path text more detail")
           (logged-p nil))
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (sb-ext:without-package-locks
        (with-stubbed-fdefinition
            ((nerimux/vcs::%git-status-snapshot
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error
                  (make-condition
                   (find-symbol "%GIT-READ-ERROR" :nerimux/vcs)
                   :directory path :subcommand "status" :arguments nil
                   :exit-code 128 :stderr stderr))))
             (log-kit:emit-log
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (setf logged-p t)
                 (error "forced logger failure"))))
          (let ((update (nerimux/vcs::%read-worktree-status-at path nil path)))
            (expect (eq :read-error
                        (nerimux/vcs::%worktree-status-update-status-state update)))
            (expect (equal expected
                           (nerimux/vcs::%worktree-status-update-status-error-message
                            update)))
            (expect (null (nerimux/vcs::%worktree-status-update-snapshot update)))
            (nerimux/vcs::%apply-worktree-status repository update)
            (expect (eq :read-error
                        (nerimux/workspace-model:worktree-status-state worktree)))
            (expect (null (nerimux/workspace-model:worktree-status worktree)))
            (expect (nerimux/workspace-model:worktree-read-error-p worktree))
            (expect (equal expected
                           (nerimux/workspace-model:worktree-status-error-message
                            worktree)))
            (dolist (control (list #\Newline #\Return #\Tab (code-char 27)))
              (expect (not (find control
                                 (nerimux/workspace-model:worktree-status-error-message
                                  worktree)))))
            (expect logged-p)))))

  (it "keeps the last successful snapshot as stale after a status read error"
    (let* ((path (namestring (host-kit:temporary-directory)))
           (snapshot
             (vcs-kit::%make-vcs-status-snapshot
              :branch-head "main" :ahead 2 :behind 1 :entries nil))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/status-stale" :local-path path))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path path :status snapshot
              :dirty-p t :changed-files (list (cons "M" "tracked.lisp"))
              :ahead 2 :behind 1 :additions 5 :deletions 3))
           (update
             (nerimux/vcs::%make-worktree-status-update
              :path path :status-state :read-error
              :status-error-message "git status exited 128: no work tree")))
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (nerimux/vcs::%apply-worktree-status repository update)
      (expect (eq :stale (nerimux/workspace-model:worktree-status-state worktree)))
      (expect (eq snapshot (nerimux/workspace-model:worktree-status worktree)))
      (expect (nerimux/workspace-model:worktree-read-error-p worktree))
      (expect (equal "git status exited 128: no work tree"
                     (nerimux/workspace-model:worktree-status-error-message worktree)))
      (expect (nerimux/workspace-model:worktree-dirty-p worktree))
      (expect (equal (list (cons "M" "tracked.lisp"))
                     (nerimux/workspace-model:worktree-changed-files worktree)))
      (expect (= 5 (nerimux/workspace-model:worktree-additions worktree)))
      (expect (= 3 (nerimux/workspace-model:worktree-deletions worktree)))))

  (it "retains typed numstat failure and its reason without replacing counts with zero"
    (let* ((path (namestring (host-kit:temporary-directory)))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/status-numstat" :local-path path))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path path :additions 5 :deletions 2)))
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (with-stubbed-fdefinition
          ((nerimux/vcs::%git-status-snapshot
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (vcs-kit::%make-vcs-status-snapshot
                :branch-head "main" :ahead 0 :behind 0
                :entries
                (list (vcs-kit::%make-vcs-status-entry
                       :kind :ordinary :index-status " " :worktree-status "M"
                       :path "tracked.lisp")))))
           (nerimux/vcs::%git-numstat-entries
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "forced numstat failure"))))
        (let ((update
                (nerimux/vcs::%read-worktree-status-at
                 path nil path :stashes (cons :ready nil))))
          (expect (eq :ready
                      (nerimux/vcs::%worktree-status-update-status-state update)))
          (expect (eq :failed
                      (nerimux/vcs::%worktree-status-update-numstat-state update)))
          (expect (equal "forced numstat failure"
                         (nerimux/vcs::%worktree-status-update-numstat-error-message
                          update)))
          (expect (null (nerimux/vcs::%worktree-status-update-additions update)))
          (expect (null (nerimux/vcs::%worktree-status-update-deletions update)))
          (nerimux/vcs::%apply-worktree-status repository update)
          (expect (eq :failed
                      (nerimux/workspace-model:worktree-numstat-state worktree)))
          (expect (equal "forced numstat failure"
                         (nerimux/workspace-model:worktree-numstat-error-message
                          worktree)))
          (expect (= 5 (nerimux/workspace-model:worktree-additions worktree)))
          (expect (= 2 (nerimux/workspace-model:worktree-deletions worktree)))))))

  (it "retains the stash failure reason on the worktree"
    (let* ((path (namestring (host-kit:temporary-directory)))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/status-stash" :local-path path))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path path)))
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (with-stubbed-fdefinition
          ((nerimux/vcs::%git-status-snapshot
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (vcs-kit::%make-vcs-status-snapshot
                :branch-head "main" :ahead 0 :behind 0 :entries nil)))
           (nerimux/vcs::%git-stash-entries
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "forced stash failure"))))
        (let* ((stash-reading (nerimux/vcs::%read-stashes-at path))
               (update
                 (nerimux/vcs::%read-worktree-status-at
                  path nil path :stashes stash-reading)))
          (expect (eq :failed
                      (nerimux/vcs::%stash-reading-state stash-reading)))
          (expect (equal "forced stash failure"
                         (nerimux/vcs::%stash-reading-error-message
                          stash-reading)))
          (nerimux/vcs::%apply-worktree-status repository update)
          (expect (eq :failed
                      (nerimux/workspace-model:worktree-stashes-state worktree)))
          (expect (equal "forced stash failure"
                         (nerimux/workspace-model:worktree-stashes-error-message
                          worktree)))
          (expect (null (nerimux/workspace-model:worktree-stashes worktree)))))))
  (it "applies the stash failure when status reading also fails"
    (let* ((path (namestring (host-kit:temporary-directory)))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/status-and-stash-error"
              :local-path path))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path path))
           (status-reason "git status exited 128: fatal: status denied")
           (stash-reading nil)
           (update nil))
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (sb-ext:without-package-locks
        (with-stubbed-fdefinition
            ((nerimux/vcs::%git-stash-entries
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error "forced stash failure")))
             (nerimux/vcs::%git-status-snapshot
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error
                  (make-condition
                   (find-symbol "%GIT-READ-ERROR" :nerimux/vcs)
                   :directory path :subcommand "status" :arguments nil
                   :exit-code 128 :stderr "fatal: status denied"))))
             (log-kit:emit-log
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 nil)))
          (setf stash-reading (nerimux/vcs::%read-stashes-at path)
                update
                (nerimux/vcs::%read-worktree-status-at
                 path nil path :stashes stash-reading)))
        (expect
         (eq :failed (nerimux/vcs::%stash-reading-state stash-reading)))
        (expect
         (equal "forced stash failure"
                (nerimux/vcs::%stash-reading-error-message stash-reading)))
        (expect
         (eq :read-error
             (nerimux/vcs::%worktree-status-update-status-state update)))
        (expect
         (equal status-reason
                (nerimux/vcs::%worktree-status-update-status-error-message update)))
        (expect
         (eq stash-reading (nerimux/vcs::%worktree-status-update-stashes update)))
        (nerimux/vcs::%apply-worktree-status repository update)
        (expect
         (eq :read-error
             (nerimux/workspace-model:worktree-status-state worktree)))
        (expect
         (equal status-reason
                (nerimux/workspace-model:worktree-status-error-message worktree)))
        (expect
         (eq :failed
             (nerimux/workspace-model:worktree-stashes-state worktree)))
        (expect
         (equal "forced stash failure"
                (nerimux/workspace-model:worktree-stashes-error-message worktree)))
        (expect (null (nerimux/workspace-model:worktree-stashes worktree))))))))
