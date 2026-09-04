(in-package #:nerimux/test/vcs)

(describe "vcs worktree status"
          (it "marks an absent worktree without querying VCS"
              (let* ((path
                      (namestring
                       (merge-pathnames
                        (format nil
                                "nerimux-missing-worktree-~D/"
                                (random 1000000))
                        (host-kit:temporary-directory))))
                     (repository
                      (nerimux/workspace-model:make-repository :specification
                                                               "workspace-owner/project"
                                                               :local-path
                                                               path))
                     (worktree
                      (nerimux/workspace-model:make-worktree :repository
                                                             repository
                                                             :path
                                                             path
                                                             :branch
                                                             "feature/ui"
                                                             :status
                                                             :stale
                                                             :dirty-p
                                                             t
                                                             :conflict-p
                                                             t
                                                             :ahead
                                                             3
                                                             :behind
                                                             2)))
                (nerimux/workspace-model:repository-add-worktree repository
                                                                 worktree)
                (expect (null (probe-file path)))
                (nerimux/vcs:worktree-status worktree)
                (expect (nerimux/workspace-model:worktree-missing-p worktree))
                (expect
                 (null (nerimux/workspace-model:worktree-status worktree)))
                (expect
                 (not (nerimux/workspace-model:worktree-dirty-p worktree)))
                (expect
                 (not (nerimux/workspace-model:worktree-conflict-p worktree)))
                (expect
                 (zerop (nerimux/workspace-model:worktree-ahead worktree)))
                (expect
                 (zerop (nerimux/workspace-model:worktree-behind worktree)))
                (expect
                 (not (nerimux/workspace-model:repository-dirty-p repository)))
                (expect
                 (not
                  (nerimux/workspace-model:repository-conflict-p repository))))))

(describe "async vcs refresh"
          (it "returns before slow repository status workers complete"
              (let* ((repositories
                      (loop for index from 1 to 3
                            collect (nerimux/workspace-model:make-repository
                                     :specification
                                     (format nil
                                             "workspace-owner/project-~D"
                                             index)
                                     :local-path
                                     (format nil "/tmp/project-~D" index))))
                     (completed nil)
                     (start (get-internal-real-time))
                     (threads
                      (nerimux/vcs:refresh-repositories-async repositories
                                                              :status-reader
                                                              (lambda 
                                                                  (repository)
                                                                (declare (ignore
                                                                          repository))
                                                                (sleep 0.2)
                                                                nil)
                                                              :on-complete
                                                              (lambda 
                                                                  (refreshed)
                                                                (declare (ignore
                                                                          refreshed))
                                                                (setf completed t))))
                     (dispatch-ms
                      (* 1000.0
                         (/ (- (get-internal-real-time) start)
                            internal-time-units-per-second)))
                     (deadline
                      (+ (get-internal-real-time)
                         (* 2 internal-time-units-per-second))))
                (loop until completed
                      while (< (get-internal-real-time) deadline)
                      do (sleep 0.01))
                (expect (= 3 (length threads)))
                (expect (< dispatch-ms 100.0))
                (expect completed)))
          (it "keeps the workspace status entry point non-blocking"
              (let* ((repositories
                      (loop for index from 1 to 3
                            collect (nerimux/workspace-model:make-repository
                                     :specification
                                     (format nil
                                             "workspace-owner/project-~D"
                                             index)
                                     :local-path
                                     (format nil "/tmp/project-~D" index))))
                     (organization
                      (nerimux/workspace-model:make-organization :host
                                                                 "workspace-owner"
                                                                 :name
                                                                 "workspace"
                                                                 :repositories
                                                                 repositories))
                     (completed nil)
                     (start (get-internal-real-time))
                     (threads
                      (nerimux/vcs:refresh-workspace-status-async :organizations
                                                                  (list
                                                                   organization)
                                                                  :status-reader
                                                                  (lambda 
                                                                      (repository)
                                                                    (declare (ignore
                                                                              repository))
                                                                    (sleep 0.2)
                                                                    nil)
                                                                  :on-complete
                                                                  (lambda 
                                                                      (refreshed)
                                                                    (declare (ignore
                                                                              refreshed))
                                                                    (setf completed t))))
                     (dispatch-ms
                      (* 1000.0
                         (/ (- (get-internal-real-time) start)
                            internal-time-units-per-second)))
                     (deadline
                      (+ (get-internal-real-time)
                         (* 2 internal-time-units-per-second))))
                (expect (= 3 (length threads)))
                (expect (not completed))
                (expect (< dispatch-ms 100.0))
                (loop until completed
                      while (< (get-internal-real-time) deadline)
                      do (sleep 0.01))
                (expect completed)))
          (it "completes with the organizations, not the flattened repositories"
              (let* ((repositories
                      (loop for index from 1 to 3
                            collect (nerimux/workspace-model:make-repository
                                     :specification
                                     (format nil
                                             "workspace-owner/project-~D"
                                             index)
                                     :local-path
                                     (format nil "/tmp/project-~D" index))))
                     (organization
                      (nerimux/workspace-model:make-organization :host
                                                                 "workspace-owner"
                                                                 :name
                                                                 "workspace"
                                                                 :repositories
                                                                 repositories))
                     (completed-with :not-called)
                     (deadline
                      (+ (get-internal-real-time)
                         (* 2 internal-time-units-per-second))))
                (nerimux/vcs:refresh-workspace-status-async :organizations
                                                            (list organization)
                                                            :status-reader
                                                            (lambda (repository)
                                                              (declare (ignore
                                                                        repository))
                                                              nil)
                                                            :on-complete
                                                            (lambda (result)
                                                              (setf completed-with result)))
                (loop until (not (eq completed-with :not-called))
                      while (< (get-internal-real-time) deadline)
                      do (sleep 0.01))
                (expect (listp completed-with))
                (expect (= 1 (length completed-with)))
                (expect (eq organization (first completed-with)))
                (expect (not (eq repositories completed-with))))))

(describe "async vcs status ownership"
          (it "applies worker results and completes only through the dispatcher"
              (let* ((repository
                      (nerimux/workspace-model:make-repository :specification
                                                               "workspace-owner/project"
                                                               :local-path
                                                               "/tmp/project"))
                     (queued nil)
                     (completed nil)
                     (thread
                      (first
                       (nerimux/vcs:refresh-repositories-async (list repository)
                                                               :status-reader
                                                               (lambda (current)
                                                                 (expect
                                                                  (eq repository
                                                                      current))
                                                                 :dirty)
                                                               :status-applier
                                                               (lambda 
                                                                   (current
                                                                    update)
                                                                 (expect
                                                                  (eq :dirty
                                                                      update))
                                                                 (setf (nerimux/workspace-model:repository-dirty-p
                                                                        current) t))
                                                               :callback-dispatch
                                                               (lambda (thunk)
                                                                 (push thunk
                                                                       queued))
                                                               :on-complete
                                                               (lambda 
                                                                   (repositories)
                                                                 (expect
                                                                  (equal
                                                                   (list
                                                                    repository)
                                                                   repositories))
                                                                 (setf completed t))))))
                (sb-thread:join-thread thread :timeout 2)
                (expect (= 1 (length queued)))
                (expect
                 (not (nerimux/workspace-model:repository-dirty-p repository)))
                (expect (not completed))
                (funcall (pop queued))
                (expect (nerimux/workspace-model:repository-dirty-p repository))
                (expect completed))))

(describe "async vcs batch edge cases"
          (it "completes immediately for an empty repository set"
              (let ((completed :not-called)
                    (threads :not-called))
                (setf threads (nerimux/vcs:refresh-repositories-async nil
                                                                      :on-complete
                                                                      (lambda 
                                                                          (repositories)
                                                                        (setf completed repositories))))
                (expect (null threads))
                (expect (equal '() completed))))
          (it "reports a repository refresh error before completing the batch"
              (let* ((repository
                      (nerimux/workspace-model:make-repository :specification
                                                               "workspace-owner/project"
                                                               :local-path
                                                               "/tmp/project"))
                     (error-repository nil)
                     (condition-seen nil)
                     (completed nil)
                     (deadline
                      (+ (get-internal-real-time)
                         (* 2 internal-time-units-per-second))))
                (nerimux/vcs:refresh-repositories-async (list repository)
                                                        :status-reader
                                                        (lambda (current)
                                                          (declare (ignore
                                                                    current))
                                                          (error
                                                           "synthetic repository refresh failure"))
                                                        :on-error
                                                        (lambda 
                                                            (current condition)
                                                          (setf error-repository current
                                                                condition-seen condition))
                                                        :on-complete
                                                        (lambda (repositories)
                                                          (declare (ignore
                                                                    repositories))
                                                          (setf completed t)))
                (loop until completed
                      while (< (get-internal-real-time) deadline)
                      do (sleep 0.01))
                (expect (eq repository error-repository))
                (expect condition-seen)
                (expect completed))))

(describe "async vcs scan errors"
          (it "reports a scan failure without leaking an unhandled worker error"
              (let ((condition-seen nil)
                    (deadline
                     (+ (get-internal-real-time)
                        (* 2 internal-time-units-per-second))))
                (with-stubbed-fdefinition
                 ((vcs-kit:ghq-list-repositories
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (error "synthetic ghq failure"))))
                 (nerimux/vcs:scan-repositories-async :on-error
                                                      (lambda (condition)
                                                        (setf condition-seen condition)))
                 (loop until condition-seen
                       while (< (get-internal-real-time) deadline)
                       do (sleep 0.01))
                 (expect condition-seen)))))

(describe "workspace catalog pane preservation"

  (it "re-binds a pane to the refreshed worktree with the same path"
    (let* ((previous (nerimux/vcs:workspace-organizations))
           (pane (nerimux/pane:make-pane :id 31 :title "editor"))
           (old-organization (nerimux/workspace-model:make-organization
                              :host "vcs-host" :name "workspace-owner"))
           (old-repository (nerimux/workspace-model:make-repository
                            :specification "workspace-owner/project"
                            :local-path "work/project"))
           (old-worktree (nerimux/workspace-model:make-worktree
                          :path "work/project/wt" :branch "feature/ui"
                          :head "old-head"))
           (new-organization (nerimux/workspace-model:make-organization
                              :host "vcs-host" :name "workspace-owner"))
           (new-repository (nerimux/workspace-model:make-repository
                            :specification "workspace-owner/project"
                            :local-path "work/project"))
           (new-worktree (nerimux/workspace-model:make-worktree
                          :path "work/project/wt" :branch "feature/ui"
                          :head "new-head")))
      (unwind-protect
           (progn
             (nerimux/workspace-model:organization-add-repository old-organization old-repository)
             (nerimux/workspace-model:repository-add-worktree old-repository old-worktree)
             (nerimux/pane:worktree-add-pane old-worktree pane)
             (nerimux/workspace-model:organization-add-repository new-organization new-repository)
             (nerimux/workspace-model:repository-add-worktree new-repository new-worktree)
             (nerimux/vcs:set-workspace-organizations (list old-organization))
             (nerimux/vcs:set-workspace-organizations (list new-organization))
             (expect (eq new-worktree (nerimux/pane:pane-worktree pane)))
             (expect (member pane (nerimux/workspace-model:worktree-panes new-worktree)
                             :test #'eq)))
        (nerimux/vcs:set-workspace-organizations previous))))

  (it "clears the pane's worktree when the worktree vanishes from the catalog"
    (let* ((previous (nerimux/vcs:workspace-organizations))
           (pane (nerimux/pane:make-pane :id 32 :title "shell"))
           (old-organization (nerimux/workspace-model:make-organization
                              :host "vcs-host" :name "workspace-owner"))
           (old-repository (nerimux/workspace-model:make-repository
                            :specification "workspace-owner/project"
                            :local-path "work/project"))
           (old-worktree (nerimux/workspace-model:make-worktree
                          :path "work/project/removed" :branch "feature/gone"
                          :head "old-head"))
           (new-organization (nerimux/workspace-model:make-organization
                              :host "vcs-host" :name "workspace-owner"))
           (new-repository (nerimux/workspace-model:make-repository
                            :specification "workspace-owner/project"
                            :local-path "work/project"))
           (surviving-worktree (nerimux/workspace-model:make-worktree
                                :path "work/project/other" :branch "main"
                                :head "new-head")))
      (unwind-protect
           (progn
             (nerimux/workspace-model:organization-add-repository old-organization old-repository)
             (nerimux/workspace-model:repository-add-worktree old-repository old-worktree)
             (nerimux/pane:worktree-add-pane old-worktree pane)
             (nerimux/workspace-model:organization-add-repository new-organization new-repository)
             (nerimux/workspace-model:repository-add-worktree new-repository surviving-worktree)
             (nerimux/vcs:set-workspace-organizations (list old-organization))
             (expect (eq old-worktree (nerimux/pane:pane-worktree pane)))
             (nerimux/vcs:set-workspace-organizations (list new-organization))
             (expect (null (nerimux/pane:pane-worktree pane)))
             (expect (not (member pane (nerimux/workspace-model:worktree-panes surviving-worktree)
                                  :test #'eq))))
        (nerimux/vcs:set-workspace-organizations previous)))))

(describe "vcs workspace catalog commit-state preservation (F1)"
  (it "carries id, commits-state and recent-commits across a full catalog rescan matched by path"
    (let* ((previous (nerimux/vcs:workspace-organizations))
           (old-organization (nerimux/workspace-model:make-organization
                              :host "vcs-host" :name "f1-owner"))
           (old-repository (nerimux/workspace-model:make-repository
                            :specification "f1-owner/project"
                            :local-path "work/f1-project"))
           (old-worktree (nerimux/workspace-model:make-worktree
                          :path "work/f1-project/wt" :branch "feature/f1"
                          :head "old-head"))
           (new-organization (nerimux/workspace-model:make-organization
                              :host "vcs-host" :name "f1-owner"))
           (new-repository (nerimux/workspace-model:make-repository
                            :specification "f1-owner/project"
                            :local-path "work/f1-project"))
           (new-worktree (nerimux/workspace-model:make-worktree
                          :path "work/f1-project/wt" :branch "feature/f1"
                          :head "new-head")))
      (unwind-protect
           (progn
             (nerimux/workspace-model:organization-add-repository old-organization old-repository)
             (nerimux/workspace-model:repository-add-worktree old-repository old-worktree)
             (nerimux/vcs:set-workspace-organizations (list old-organization))
             (let ((published (nerimux/workspace-model:repository-worktree-by-path
                               (first (nerimux/workspace-model:organization-repositories
                                       (first (nerimux/vcs:workspace-organizations))))
                               "work/f1-project/wt")))
               (setf (nerimux/workspace-model:worktree-commits-state published) :ready
                     (nerimux/workspace-model:worktree-recent-commits published)
                     (list (cons "abc1234" "a settled commit")))
               (let ((first-id (nerimux/workspace-model:worktree-id published)))
                 (nerimux/workspace-model:organization-add-repository
                  new-organization new-repository)
                 (nerimux/workspace-model:repository-add-worktree new-repository new-worktree)
                 (nerimux/vcs:set-workspace-organizations (list new-organization))
                 (let ((rescanned (nerimux/workspace-model:repository-worktree-by-path
                                   (first (nerimux/workspace-model:organization-repositories
                                           (first (nerimux/vcs:workspace-organizations))))
                                   "work/f1-project/wt")))
                   (expect (not (eq published rescanned)))
                   (expect (string= first-id (nerimux/workspace-model:worktree-id rescanned)))
                   (expect (eq :ready (nerimux/workspace-model:worktree-commits-state rescanned)))
                   (expect (equal (list (cons "abc1234" "a settled commit"))
                                  (nerimux/workspace-model:worktree-recent-commits rescanned)))))))
        (nerimux/vcs:set-workspace-organizations previous)))))

(describe "workspace catalog activity ordering"

  (it "sorts repositories and their worktrees by most-recent pane activity first"
    (let ((previous (nerimux/vcs:workspace-organizations)))
      (unwind-protect
           (let* ((organization
                    (nerimux/workspace-model:make-organization
                     :id "org-activity" :host "github.com" :name "team"))
                  (repo-old
                    (nerimux/workspace-model:make-repository
                     :id "repo-old" :organization organization
                     :specification "github.com/team/old"))
                  (repo-new
                    (nerimux/workspace-model:make-repository
                     :id "repo-new" :organization organization
                     :specification "github.com/team/new"))
                  (worktree-old
                    (nerimux/workspace-model:make-worktree
                     :id "wt-old" :repository repo-old
                     :path "/tmp/old" :branch "old"))
                  (worktree-new
                    (nerimux/workspace-model:make-worktree
                     :id "wt-new" :repository repo-new
                     :path "/tmp/new" :branch "new"))
                  (pane-old (nerimux/pane:make-pane :id 1 :fd -1))
                  (pane-new (nerimux/pane:make-pane :id 2 :fd -1)))
             (nerimux/workspace-model:organization-add-repository organization repo-old)
             (nerimux/workspace-model:organization-add-repository organization repo-new)
             (nerimux/workspace-model:repository-add-worktree repo-old worktree-old)
             (nerimux/workspace-model:repository-add-worktree repo-new worktree-new)
             (nerimux/pane:worktree-add-pane worktree-old pane-old)
             (nerimux/pane:worktree-add-pane worktree-new pane-new)
             (setf (nerimux/pane:pane-last-output-time pane-old)
                   (- (get-universal-time) 600)
                   (nerimux/pane:pane-last-output-time pane-new)
                   (- (get-universal-time) 60))
             (nerimux/vcs:set-workspace-organizations (list organization))
             (let ((sorted-organization (first (nerimux/vcs:workspace-organizations))))
               (expect (equal (list repo-new repo-old)
                              (nerimux/workspace-model:organization-repositories
                               sorted-organization)))))
        (nerimux/vcs:set-workspace-organizations previous))))

  (it "sorts a worktree with no pane activity below any worktree with a timestamp"
    (let ((previous (nerimux/vcs:workspace-organizations)))
      (unwind-protect
           (let* ((organization
                    (nerimux/workspace-model:make-organization
                     :id "org-nil-time" :host "github.com" :name "team"))
                  (repository
                    (nerimux/workspace-model:make-repository
                     :id "repo-nil-time" :organization organization
                     :specification "github.com/team/repo"))
                  (worktree-active
                    (nerimux/workspace-model:make-worktree
                     :id "wt-active" :repository repository
                     :path "/tmp/active" :branch "active"))
                  (worktree-idle
                    (nerimux/workspace-model:make-worktree
                     :id "wt-idle" :repository repository
                     :path "/tmp/idle" :branch "idle"))
                  (pane (nerimux/pane:make-pane :id 3 :fd -1)))
             (nerimux/workspace-model:organization-add-repository organization repository)
             (nerimux/workspace-model:repository-add-worktree repository worktree-active)
             (nerimux/workspace-model:repository-add-worktree repository worktree-idle)
             (nerimux/pane:worktree-add-pane worktree-active pane)
             (setf (nerimux/pane:pane-last-output-time pane)
                   (- (get-universal-time) 30))
             (nerimux/vcs:set-workspace-organizations (list organization))
             (let ((sorted-organization (first (nerimux/vcs:workspace-organizations))))
               (expect (equal (list worktree-active worktree-idle)
                              (nerimux/workspace-model:repository-worktrees
                               (first (nerimux/workspace-model:organization-repositories
                                       sorted-organization)))))))
        (nerimux/vcs:set-workspace-organizations previous))))

  (it "keeps the existing order for tied (no-activity) worktrees"
    (let ((previous (nerimux/vcs:workspace-organizations)))
      (unwind-protect
           (let* ((organization
                    (nerimux/workspace-model:make-organization
                     :id "org-tie" :host "github.com" :name "team"))
                  (repository
                    (nerimux/workspace-model:make-repository
                     :id "repo-tie" :organization organization
                     :specification "github.com/team/repo"))
                  (worktree-first
                    (nerimux/workspace-model:make-worktree
                     :id "wt-first" :repository repository
                     :path "/tmp/first" :branch "first"))
                  (worktree-second
                    (nerimux/workspace-model:make-worktree
                     :id "wt-second" :repository repository
                     :path "/tmp/second" :branch "second")))
             (nerimux/workspace-model:organization-add-repository organization repository)
             (nerimux/workspace-model:repository-add-worktree repository worktree-second)
             (nerimux/workspace-model:repository-add-worktree repository worktree-first)
             (nerimux/vcs:set-workspace-organizations (list organization))
             (let ((sorted-organization (first (nerimux/vcs:workspace-organizations))))
               (expect (equal (list worktree-first worktree-second)
                              (nerimux/workspace-model:repository-worktrees
                               (first (nerimux/workspace-model:organization-repositories
                                       sorted-organization)))))))
        (nerimux/vcs:set-workspace-organizations previous)))))

(describe "merge-workspace-organizations"

  (it "adds-a-wholly-new-organization-by-id"
    (let ((previous (nerimux/vcs:workspace-organizations)))
      (unwind-protect
           (let ((existing (nerimux/workspace-model:make-organization
                            :id "org-existing" :host "github.com" :name "existing")))
             (nerimux/vcs:set-workspace-organizations (list existing))
             (let* ((incoming (nerimux/workspace-model:make-organization
                               :id "org-new" :host "github.com" :name "new"))
                    (merged (nerimux/vcs:merge-workspace-organizations
                             (list incoming))))
               (expect (= 2 (length merged)))
               (expect (find incoming merged :test #'eq))
               (expect (find existing merged :test #'eq))))
        (nerimux/vcs:set-workspace-organizations previous))))

  (it "preserves-catalog-and-incoming-organization-order"
    (let ((previous (nerimux/vcs:workspace-organizations)))
      (unwind-protect
           (let* ((existing-a (nerimux/workspace-model:make-organization
                               :id "org-existing-a" :host "host" :name "a"))
                  (existing-b (nerimux/workspace-model:make-organization
                               :id "org-existing-b" :host "host" :name "b"))
                  (incoming-existing (nerimux/workspace-model:make-organization
                                      :id "org-existing-a" :host "host"
                                      :name "a-refresh"))
                  (incoming-new-a (nerimux/workspace-model:make-organization
                                   :id "org-new-a" :host "host" :name "new-a"))
                  (incoming-new-b (nerimux/workspace-model:make-organization
                                   :id "org-new-b" :host "host" :name "new-b")))
             (nerimux/vcs:set-workspace-organizations
              (list existing-a existing-b))
             (let ((merged (nerimux/vcs:merge-workspace-organizations
                            (list incoming-existing incoming-new-a incoming-new-b))))
               (expect (equal '("org-existing-a" "org-existing-b"
                                "org-new-a" "org-new-b")
                              (mapcar #'nerimux/workspace-model:organization-id merged)))
               (expect (eq existing-a (first merged)))))
        (nerimux/vcs:set-workspace-organizations previous))))

  (it "adds-only-the-missing-repository-to-an-already-present-organization"
    (let ((previous (nerimux/vcs:workspace-organizations)))
      (unwind-protect
           (let* ((organization (nerimux/workspace-model:make-organization
                                 :id "org" :host "github.com" :name "team"))
                  (existing-repository (nerimux/workspace-model:make-repository
                                       :id "repo-existing"
                                       :specification "github.com/team/existing"
                                       :local-path "/workspace/existing")))
             (nerimux/workspace-model:organization-add-repository
              organization existing-repository)
             (nerimux/vcs:set-workspace-organizations (list organization))
             (let* ((incoming-organization (nerimux/workspace-model:make-organization
                                            :id "org" :host "github.com" :name "team"))
                    (duplicate-repository (nerimux/workspace-model:make-repository
                                           :id "repo-duplicate"
                                           :specification "github.com/team/existing"
                                           :local-path "/workspace/existing"))
                    (new-repository (nerimux/workspace-model:make-repository
                                     :id "repo-new"
                                     :specification "github.com/team/new"
                                     :local-path "/workspace/new")))
               (nerimux/workspace-model:organization-add-repository
                incoming-organization duplicate-repository)
               (nerimux/workspace-model:organization-add-repository
                incoming-organization new-repository)
               (let* ((merged (nerimux/vcs:merge-workspace-organizations
                              (list incoming-organization)))
                      (merged-organization (first merged))
                      (repositories (nerimux/workspace-model:organization-repositories
                                     merged-organization)))
                 (expect (= 1 (length merged)))
                 (expect (eq organization merged-organization))
                 (expect (= 2 (length repositories)))
                 (expect (find existing-repository repositories :test #'eq))
                 (expect (find new-repository repositories :test #'eq))
                 (expect (not (find duplicate-repository repositories :test #'eq))))))
        (nerimux/vcs:set-workspace-organizations previous)))))

(defun %bare-status-fixture-directory (label)
  "Create and return a fresh, existing temporary directory path for LABEL."
  (let ((path
         (namestring
          (merge-pathnames
           (format nil
                   "nerimux-bare-status-~A-~D-~D/"
                   label
                   (get-universal-time)
                   (random 1000000))
           (host-kit:temporary-directory)))))
    (ensure-directories-exist path)
    path))

(describe "resolve-directory-organizations-fail-closed-suite"

  (it "returns-nil-for-a-nonexistent-path"
    (expect (null (nerimux/vcs:resolve-directory-organizations
                   (format nil "/nonexistent-nerimux-resolve-probe-~D"
                           (random 1000000))))))

  (it "returns-nil-for-a-directory-that-is-not-a-git-repository"
    (let ((dir (%bare-status-fixture-directory "resolve-non-git")))
      (unwind-protect
           (expect (null (nerimux/vcs:resolve-directory-organizations dir)))
        (ignore-errors (sb-posix:rmdir dir)))))

  (it "returns-nil-for-empty-or-non-string-input"
    (expect (null (nerimux/vcs:resolve-directory-organizations "")))
    (expect (null (nerimux/vcs:resolve-directory-organizations nil)))
    (expect (null (nerimux/vcs:resolve-directory-organizations 42)))))

(describe "directory repository root suite"
          (it "returns no root when git reports no worktrees"
              (let ((backend :fake-backend))
                (with-stubbed-fdefinition
                 ((nerimux/vcs::%make-directory-vcs-repository
                   (lambda (directory)
                     (declare (ignore directory))
                     backend))
                  (vcs-kit:vcs-list-worktrees
                   (lambda (repository)
                     (expect (eq backend repository))
                     nil)))
                 (multiple-value-bind (root worktrees) 
                     (nerimux/vcs::%directory-repository-root
                      "/tmp/empty-worktrees")
                   (expect (null root))
                   (expect (null worktrees))))))
          (it-each
           ((nil "/tmp/first-worktree"
                 ((:path "/tmp/first-worktree" :bare-p nil)
                  (:path "/tmp/second-worktree" :bare-p nil)))
            (t "/tmp/bare-repository"
               ((:path "/tmp/working-tree" :bare-p nil)
                (:path "/tmp/bare-repository" :bare-p t))))
           "selects the repository root from worktrees ~S"
           (expected-bare-p expected-path raw-specs)
           (let ((worktrees
                  (mapcar
                   (lambda (spec)
                     (apply #'vcs-kit::%make-vcs-worktree spec))
                   raw-specs)))
             (with-stubbed-fdefinition
              ((nerimux/vcs::%make-directory-vcs-repository
                (lambda (directory)
                  (declare (ignore directory))
                  :fake-backend))
               (vcs-kit:vcs-list-worktrees
                (lambda (backend)
                  (declare (ignore backend))
                  worktrees)))
              (multiple-value-bind (root returned-worktrees) 
                  (nerimux/vcs::%directory-repository-root "/tmp/probe")
                (expect (string= expected-path root))
                (expect (eq worktrees returned-worktrees))
                (expect
                 (eq expected-bare-p
                     (vcs-kit:vcs-worktree-bare-p
                      (find expected-path
                            worktrees
                            :key
                            #'vcs-kit:vcs-worktree-path
                            :test
                            #'string=)))))))))

(describe "vcs bare worktree status collection"
          (it
           "%read-repository-refresh skips the bare entry and updates only the working worktree"
           (let* ((bare-path (%bare-status-fixture-directory "refresh-bare"))
                  (work-path (%bare-status-fixture-directory "refresh-work"))
                  (repository
                   (nerimux/workspace-model:make-repository :specification
                                                            "workspace-owner/project"
                                                            :local-path
                                                            bare-path))
                  (raw-worktrees
                   (list
                    (vcs-kit::%make-vcs-worktree :path
                                                 bare-path
                                                 :branch
                                                 nil
                                                 :head
                                                 "bare-head"
                                                 :bare-p
                                                 t)
                    (vcs-kit::%make-vcs-worktree :path
                                                 work-path
                                                 :branch
                                                 "main"
                                                 :head
                                                 "work-head"))))
             (with-stubbed-fdefinition
              ((vcs-kit:make-vcs-repository
                (lambda (directory &rest arguments)
                  (declare (ignore arguments))
                  directory))
               (vcs-kit:vcs-list-worktrees
                (lambda (&rest arguments)
                  (declare (ignore arguments))
                  raw-worktrees))
               (vcs-kit:vcs-status-structured
                (lambda (backend-directory &rest arguments)
                  (declare (ignore arguments))
                  (if (string= backend-directory bare-path)
                      (error "status must not run against the bare root")
                      (vcs-kit::%make-vcs-status-snapshot :entries
                                                          nil
                                                          :branch-head
                                                          "work-head"
                                                          :ahead
                                                          0
                                                          :behind
                                                          0)))))
              (let* ((refresh
                      (nerimux/vcs::%read-repository-refresh repository))
                     (updates
                      (nerimux/vcs::%repository-refresh-status-updates refresh)))
                (expect (= 1 (length updates)))
                (expect
                 (string= work-path
                          (nerimux/vcs::%worktree-status-update-path
                           (first updates))))))))
          (it
           "%read-repository-status skips the bare worktree and updates only the working worktree"
           (let* ((bare-path (%bare-status-fixture-directory "status-bare"))
                  (work-path (%bare-status-fixture-directory "status-work"))
                  (repository
                   (nerimux/workspace-model:make-repository :specification
                                                            "workspace-owner/project"
                                                            :local-path
                                                            bare-path))
                  (bare-worktree
                   (nerimux/workspace-model:make-worktree :repository
                                                          repository
                                                          :path
                                                          bare-path
                                                          :bare-p
                                                          t))
                  (work-worktree
                   (nerimux/workspace-model:make-worktree :repository
                                                          repository
                                                          :path
                                                          work-path
                                                          :branch
                                                          "main")))
             (nerimux/workspace-model:repository-add-worktree repository
                                                              bare-worktree)
             (nerimux/workspace-model:repository-add-worktree repository
                                                              work-worktree)
             (with-stubbed-fdefinition
              ((vcs-kit:make-vcs-repository
                (lambda (directory &rest arguments)
                  (declare (ignore arguments))
                  directory))
               (vcs-kit:vcs-status-structured
                (lambda (backend-directory &rest arguments)
                  (declare (ignore arguments))
                  (if (string= backend-directory bare-path)
                      (error "status must not run against the bare root")
                      (vcs-kit::%make-vcs-status-snapshot :entries
                                                          nil
                                                          :branch-head
                                                          "work-head"
                                                          :ahead
                                                          0
                                                          :behind
                                                          0)))))
              (let ((updates (nerimux/vcs::%read-repository-status repository)))
                (expect (= 1 (length updates)))
                (expect
                 (string= work-path
                          (nerimux/vcs::%worktree-status-update-path
                           (first updates)))))))))
