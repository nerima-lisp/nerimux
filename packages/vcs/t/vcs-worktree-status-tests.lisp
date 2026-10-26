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
(describe "F2 L2-06 vcs worktree commit display"
          (it "switches to level 4 through key dispatch and replaces loading with real Git commits"
              (labels
                  ((git (directory &rest arguments)
                        (multiple-value-bind (stdout stderr exit-code)
                            (uiop:run-program
                             (append (list "git" "-C" directory) arguments)
                             :output :string :error-output :string :ignore-error-status t)
                          (unless (and (integerp exit-code) (zerop exit-code))
                            (error "fixture git failed (~D): ~A" exit-code stderr))
                          stdout))
                   (frame-text (frame)
                               (multiple-value-bind (type payload)
                                   (uiop:symbol-call :nerimux/protocol :decode-frame frame)
                                 (declare (ignore type))
                                 (uiop:symbol-call :cl-codec-kit :octets-to-string
                                                   payload :encoding :utf-8))))
                (let* ((root
                        (merge-pathnames
                         (format nil "nerimux-l2-06-~D-~D/"
                                 (get-universal-time) (random 1000000000))
                         (host-kit:temporary-directory)))
                       (repository-path (merge-pathnames "repository/" root))
                       (subject "f2-l2-06-real-git-log-subject"))
                  (ensure-directories-exist (merge-pathnames ".keep" repository-path))
                  (unwind-protect
                      (progn
                        (git (namestring repository-path) "init" "--initial-branch=main")
                        (with-open-file (stream (merge-pathnames "tracked.txt" repository-path)
                                                :direction :output :if-exists :error
                                                :if-does-not-exist :create)
                          (write-line "fixture" stream))
                        (git (namestring repository-path) "add" "tracked.txt")
                        (git (namestring repository-path)
                             "-c" "user.name=Fixture" "-c" "user.email=fixture@example.invalid"
                             "-c" "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null"
                             "commit" "-m" subject)
                        (uiop:symbol-call :asdf :load-system "nerimux")
                        (let* ((repository-path (namestring (truename repository-path)))
                               (previous-organizations (nerimux/vcs:workspace-organizations))
                               (repository
                                (nerimux/workspace-model:make-repository
                                 :id "l2-06-repository" :specification "fixture.invalid/l2-06"
                                 :local-path repository-path))
                               (worktree
                                (nerimux/workspace-model:make-worktree
                                 :id "l2-06-worktree" :repository repository
                                 :path repository-path :branch "main"))
                               (organization
                                (nerimux/workspace-model:make-organization
                                 :id "fixture.invalid/l2-06" :host "fixture.invalid" :name "l2-06"))
                               (server-package (find-package :nerimux))
                               (state-symbols
                                (mapcar (lambda (name)
                                          (or (find-symbol name server-package)
                                              (error "missing server state variable ~A" name)))
                                        '("*CLIENT-VISIBILITY-LEVEL-APPLIED*"
                                          "*WORKSPACE-COLLAPSED-NODE-IDS*"
                                          "*WORKSPACE-EXPANDED-NODE-IDS*"
                                          "*CLIENT-MESSAGE-DISPLAY*"
                                          "*WORKSPACE-FILE-DIFFS*"
                                          "*WORKSPACE-REFRESHING-IDS*"
                                          "*WORKSPACE-STALE-IDS*")))
                               (state-values
                                (list (make-hash-table :test #'eq)
                                      (make-hash-table :test #'equal)
                                      (make-hash-table :test #'equal)
                                      (make-hash-table :test #'eq)
                                      (make-hash-table :test #'equal)
                                      (make-hash-table :test #'equal)
                                      (make-hash-table :test #'equal)))
                               (entered (sb-thread:make-semaphore :count 0))
                               (release (sb-thread:make-semaphore :count 0))
                               (worker nil)
                               (released-p nil)
                               (calls 0)
                               (actual-commits nil)
                               (original-list-commits (fdefinition 'vcs-kit:vcs-list-commits)))
                          (nerimux/workspace-model:organization-add-repository
                           organization repository)
                          (nerimux/workspace-model:repository-add-worktree repository worktree)
                          (unwind-protect
                              (progv state-symbols state-values
                                (nerimux/vcs:set-workspace-organizations (list organization))
                                (with-stubbed-fdefinition
                                 ((vcs-kit:vcs-list-commits
                                   (lambda (&rest arguments)
                                     (incf calls)
                                     (setf worker (cl-concurrent-kit:current-thread))
                                     (sb-thread:signal-semaphore entered)
                                     (unless (sb-thread:wait-on-semaphore release :timeout 10)
                                       (error "timed out waiting to release the Git log gate"))
                                     (setf actual-commits
                                           (apply original-list-commits arguments)))))
                                 (let* ((session
                                         (uiop:symbol-call :nerimux/session :make-session
                                                           :id 1 :name "l2-06"))
                                        (conn
                                         (nerimux::%make-client-conn :rows 30 :cols 160))
                                        (initial-frame
                                         (uiop:symbol-call :nerimux "%render-client-frame"
                                                           session conn)))
                                   (expect initial-frame)
                                   (expect (= 2 (uiop:symbol-call
                                                 :nerimux "client-conn-visibility-level" conn)))
                                   (uiop:symbol-call :nerimux "%handle-multi-key-message"
                                                     session conn #(52))
                                   (expect (= 4 (uiop:symbol-call
                                                 :nerimux "client-conn-visibility-level" conn)))
                                   (let ((loading-frame
                                          (uiop:symbol-call :nerimux "%render-client-frame"
                                                            session conn)))
                                     (expect (sb-thread:wait-on-semaphore entered :timeout 5))
                                     (expect (search "commits: loading..."
                                                     (frame-text loading-frame)))
                                     (expect (eq :pending
                                                 (nerimux/workspace-model:worktree-commits-state
                                                  worktree)))
                                     (sb-thread:signal-semaphore release)
                                     (setf released-p t)
                                     (cl-concurrent-kit:join-thread worker :timeout 10)
                                     (uiop:symbol-call :nerimux "%drain-main-thread-callbacks")
                                     (let ((ready-text
                                            (frame-text
                                             (uiop:symbol-call :nerimux "%render-client-frame"
                                                               session conn))))
                                       (expect (= 1 calls))
                                       (expect (= 1 (length actual-commits)))
                                       (expect (string= subject
                                                        (vcs-kit:vcs-commit-message
                                                         (first actual-commits))))
                                       (expect (eq :ready
                                                   (nerimux/workspace-model:worktree-commits-state
                                                    worktree)))
                                       (expect (search subject ready-text))
                                       (expect (null (search "commits: loading..." ready-text))))))
                                 (unless released-p (sb-thread:signal-semaphore release))
                                 (when worker
                                   (ignore-errors (cl-concurrent-kit:join-thread worker :timeout 10))
                                   (ignore-errors
                                    (uiop:symbol-call :nerimux "%drain-main-thread-callbacks")))
                                 (nerimux/vcs:set-workspace-organizations previous-organizations))))
                          (when (probe-file root)
                            (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))))
              ))
