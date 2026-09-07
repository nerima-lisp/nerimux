(in-package #:nerimux/test/vcs)
(defun %call-with-catalog-refresh-driver (test &key direct)
  (let ((previous (nerimux/vcs:workspace-organizations))
        (previous-generation
          (sb-thread:with-recursive-lock (nerimux/vcs::*workspace-catalog-generation-lock*)
            nerimux/vcs::*workspace-catalog-generation*))
        (scans nil)
        (statuses nil)
        (events nil)
        (queued nil))
    (unwind-protect
         (with-stubbed-fdefinition
             ((nerimux/vcs:scan-repositories-async
                (lambda (&rest options)
                  (let ((handle (gensym "SCAN-")))
                    (push (list* :handle handle options) scans)
                    handle)))
              (nerimux/vcs:refresh-repositories-async
                (lambda (repositories &rest options)
                  (push (list* :repositories repositories options) statuses)
                  nil)))
           (labels ((record-event (tag channel &rest values)
                      (push (list* tag channel values) events))
                    (start (tag &optional catalog-observer)
                      (let ((handle
                              (nerimux/vcs:refresh-workspace-organizations-async
                               :callback-dispatch
                               (unless direct
                                 (lambda (callback) (push callback queued)))
                               :on-catalog
                               (lambda (organizations)
                                 (record-event tag :catalog organizations)
                                 (when catalog-observer
                                   (funcall catalog-observer organizations)))
                               :on-complete
                               (lambda (organizations)
                                 (record-event tag :complete organizations))
                               :on-error
                               (lambda (condition)
                                 (record-event tag :error condition))
                               :on-repository-error
                               (lambda (repository condition)
                                 (record-event tag :repository-error repository condition))
                               :on-progress
                               (lambda (count)
                                 (record-event tag :progress count)))))
                        (expect (eq handle (getf (first scans) :handle)))
                        (first scans)))
                    (emit (request channel &rest values)
                      (apply #'nerimux/vcs::%dispatch-callback
                             (getf request :callback-dispatch)
                             (getf request channel)
                             values))
                    (drain ()
                      (let ((callbacks (nreverse queued)))
                        (setf queued nil)
                        (dolist (callback callbacks) (funcall callback)))))
             (funcall test #'start #'emit #'drain
                      (lambda () (reverse statuses))
                      (lambda () (reverse events)))))
      (sb-thread:with-recursive-lock (nerimux/vcs::*workspace-catalog-generation-lock*)
        (nerimux/vcs:set-workspace-organizations previous)
        (setf nerimux/vcs::*workspace-catalog-generation* previous-generation)))))
(defun %call-with-creation-order-fixture (paths test)
  (let* ((previous (nerimux/vcs:workspace-organizations))
         (organization
           (nerimux/workspace-model:make-organization
            :id "creation-org" :host "example.org" :name "team"))
         (repository
           (nerimux/workspace-model:make-repository
            :id "creation-repo" :organization organization
            :specification "example.org/team/repo"))
         (worktrees
           (loop for path in paths
                 for index from 0
                 collect (nerimux/workspace-model:make-worktree
                          :id (format nil "creation-~D" index)
                          :repository repository :path path)))
         (organizations (list organization)))
    (unwind-protect
         (progn
           (setf nerimux/vcs::*workspace-organizations* nil
                 (nerimux/workspace-model:organization-repositories organization)
                 (list repository)
                 (nerimux/workspace-model:repository-worktrees repository)
                 worktrees)
           (funcall test organization repository worktrees organizations))
      (setf nerimux/vcs::*workspace-organizations* previous))))
(defun %expect-creation-order (paths expected)
  (%call-with-creation-order-fixture
   paths
   (lambda (organization repository worktrees organizations)
     (declare (ignore organization))
     (nerimux/vcs:set-workspace-organizations organizations)
     (expect (equal (mapcar (lambda (index) (nth index worktrees)) expected)
                    (nerimux/workspace-model:repository-worktrees repository))))))


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
(describe "vcs overlapping catalog refresh"
  (it "publishes only the newest scan and never starts status for the old catalog"
    (%call-with-catalog-refresh-driver
     (lambda (start emit drain statuses events)
       (let* ((old-catalog (list (nerimux/workspace-model:make-organization :id "old")))
              (new-catalog (list (nerimux/workspace-model:make-organization :id "new")))
              (old (funcall start :old))
              (new (funcall start :new)))
         (funcall emit new :on-complete new-catalog)
         (funcall emit old :on-complete old-catalog)
         (funcall drain)
         (expect (equal new-catalog (nerimux/vcs:workspace-organizations)))
         (expect (= 1 (length (funcall statuses))))
         (expect (equal (list (list :new :catalog new-catalog)) (funcall events)))))))

  (it "drops stale queued progress and both error channels and status completion"
    (%call-with-catalog-refresh-driver
     (lambda (start emit drain statuses events)
       (let* ((old-catalog (list (nerimux/workspace-model:make-organization :id "old")))
              (new-catalog (list (nerimux/workspace-model:make-organization :id "new")))
              (repository (nerimux/workspace-model:make-repository))
              (failure (make-condition 'simple-error :format-control "catalog failure"))
              (old (funcall start :old)))
         (funcall emit old :on-complete old-catalog)
         (funcall drain)
         (expect (= 1 (length (funcall statuses))))
         (let ((old-status (first (funcall statuses))))
           (funcall emit old :on-progress 11)
           (funcall emit old :on-error failure)
           (funcall emit old-status :on-error repository failure)
           (funcall emit old-status :on-complete nil)
           (let ((new (funcall start :new)))
             (funcall drain)
             (expect (equal (list (list :old :catalog old-catalog)) (funcall events)))
             (funcall emit new :on-progress 22)
             (funcall emit new :on-complete new-catalog)
             (funcall drain)
             (expect (= 2 (length (funcall statuses))))
             (let ((new-status (second (funcall statuses))))
               (funcall emit new-status :on-error repository failure)
               (funcall emit new-status :on-complete nil)
               (funcall drain)
               (expect (equal
                        (list (list :old :catalog old-catalog)
                              (list :new :progress 22)
                              (list :new :catalog new-catalog)
                              (list :new :repository-error repository failure)
                              (list :new :complete new-catalog))
                        (funcall events))))))))))

  (it "keeps the newest terminal scan error without publishing a catalog"
    (%call-with-catalog-refresh-driver
     (lambda (start emit drain statuses events)
       (let* ((failure (make-condition 'simple-error :format-control "new scan failure"))
              (old (funcall start :old))
              (new (funcall start :new)))
         (funcall emit old :on-error failure)
         (funcall emit new :on-error failure)
         (funcall drain)
         (expect (null (funcall statuses)))
         (expect (equal (list (list :new :error failure)) (funcall events)))))))

  (it "rechecks freshness after a catalog observer starts another refresh"
    (%call-with-catalog-refresh-driver
     (lambda (start emit drain statuses events)
       (let* ((old-catalog (list (nerimux/workspace-model:make-organization :id "old")))
              (new-catalog (list (nerimux/workspace-model:make-organization :id "new")))
              (new nil)
              (old (funcall start :old
                            (lambda (organizations)
                              (declare (ignore organizations))
                              (setf new (funcall start :new))))))
         (funcall emit old :on-complete old-catalog)
         (funcall drain)
         (expect new)
         (expect (null (funcall statuses)))
         (funcall emit new :on-complete new-catalog)
         (funcall drain)
         (expect (= 1 (length (funcall statuses))))
         (expect (equal new-catalog (nerimux/vcs:workspace-organizations)))
         (expect (equal (list (list :old :catalog old-catalog)
                              (list :new :catalog new-catalog))
                        (funcall events)))))))

  (it "guards direct delivery without requiring an event loop dispatcher"
    (%call-with-catalog-refresh-driver
     (lambda (start emit drain statuses events)
       (declare (ignore drain))
       (let* ((catalog (list (nerimux/workspace-model:make-organization :id "new")))
              (old (funcall start :old))
              (new (funcall start :new)))
         (funcall emit new :on-complete catalog)
         (funcall emit old :on-progress 99)
         (funcall emit old :on-complete nil)
         (expect (equal catalog (nerimux/vcs:workspace-organizations)))
         (expect (= 1 (length (funcall statuses))))
         (expect (equal (list (list :new :catalog catalog)) (funcall events)))))
     :direct t)))
(describe "worktree lifecycle catalog preservation"
  (it "preserves completion and retained agent history through both refresh paths"
    (let* ((previous (nerimux/vcs:workspace-organizations))
           (org (nerimux/workspace-model:make-organization))
           (repo (nerimux/workspace-model:make-repository))
           (wt (nerimux/workspace-model:make-worktree :path "work/lifecycle"))
           (agent (nerimux/pane:make-pane :fd 44 :agent-kind :codex))
           (old-agent (nerimux/pane:make-pane :fd 43 :agent-kind :claude)))
      (unwind-protect
           (progn
             (nerimux/workspace-model:organization-add-repository org repo)
             (nerimux/workspace-model:repository-add-worktree repo wt)
             (nerimux/vcs:set-workspace-organizations (list org))
             (nerimux/pane:worktree-add-pane wt old-agent)
             (nerimux/pane:pane-mark-process-exit old-agent :status 0)
             (nerimux/pane:worktree-add-pane wt agent)
             (nerimux/workspace-model:worktree-complete wt)
             (nerimux/vcs::%apply-repository-worktrees
              repo (list (vcs-kit::%make-vcs-worktree :path "work/lifecycle" :prunable-p nil)) nil)
             (let ((refreshed (first (nerimux/workspace-model:repository-worktrees repo))))
               (expect (not (eq wt refreshed)))
               (expect (nerimux/workspace-model:worktree-completed-p refreshed))
               (expect (eq :running (nerimux/pane:worktree-agent-state refreshed)))
               (expect (eq refreshed (nerimux/pane:pane-worktree agent)))
               (expect (= 2 (length (nerimux/workspace-model:worktree-panes refreshed)))))
             (let* ((new-org (nerimux/workspace-model:make-organization))
                    (new-repo (nerimux/workspace-model:make-repository))
                    (new-wt (nerimux/workspace-model:make-worktree :path "work/lifecycle" :prunable-p t)))
               (nerimux/workspace-model:organization-add-repository new-org new-repo)
               (nerimux/workspace-model:repository-add-worktree new-repo new-wt)
               (nerimux/vcs:set-workspace-organizations (list new-org))
               (expect (nerimux/workspace-model:worktree-completed-p new-wt))
               (expect (eq agent (nerimux/workspace-model:worktree-agent-pane new-wt)))
               (expect (eq :running (nerimux/pane:worktree-agent-state new-wt)))
               (expect (= 2 (length (nerimux/workspace-model:worktree-panes new-wt))))
               (expect (eq new-wt (nerimux/pane:pane-worktree old-agent)))
               (expect (eq new-wt (nerimux/pane:pane-worktree agent)))
               (setf (nerimux/pane:pane-fd agent) -1
                     (nerimux/pane:pane-worktree agent) nil
                     (nerimux/workspace-model:worktree-panes new-wt) nil)
               (nerimux/vcs::%apply-repository-worktrees
                new-repo (list (vcs-kit::%make-vcs-worktree :path "work/lifecycle")) nil)
               (setf new-wt (first (nerimux/workspace-model:repository-worktrees new-repo)))
               (expect (nerimux/workspace-model:worktree-completed-p new-wt))
               (expect (eq agent (nerimux/workspace-model:worktree-agent-pane new-wt)))
               (expect (eq :exited (nerimux/pane:worktree-agent-state new-wt)))))
        (nerimux/vcs:set-workspace-organizations previous)))))
(describe "workspace catalog creation ordering"
  (it "orders valid creation timestamps newest first including trailing slashes"
    (%expect-creation-order
     '("/virtual/20240229T235959-abcdef0"
       "/virtual/20250301T000000-abcdef0/"
       "/virtual/20241231T235959-abcdef0"
       "/virtual/20250301T000001-abcdef0")
     '(3 1 2 0))
    (%expect-creation-order
     '("/virtual/20250301T120000-abcdef0"
       "/virtual/20250302T120000-ABCDEF0")
     '(1 0)))

  (it "orders numeric collision suffixes across different SHAs for every input permutation"
    (dolist (order '((0 1 2) (0 2 1) (1 0 2) (1 2 0) (2 0 1) (2 1 0)))
      (let* ((paths '("/virtual/20250301T120000-ffffff0"
                      "/virtual/20250301T120000-000000a-2"
                      "/virtual/20250301T120000-aaaaaaa-10"))
             (input (mapcar (lambda (index) (nth index paths)) order)))
        (%expect-creation-order input
                                (mapcar (lambda (index) (position index order))
                                        '(2 1 0))))))

  (it "preserves equal timestamp and suffix input order regardless of SHA"
    (dolist (order '((0 1 2 3) (1 0 3 2)))
      (let ((paths '("/virtual/20250301T120000-000000a-2"
                     "/virtual/20250301T120000-fffffff-2"
                     "/virtual/20250301T120000-abcdef0"
                     "/virtual/20250301T120000-FFFFFFF")))
        (%expect-creation-order
         (mapcar (lambda (index) (nth index paths)) order)
         '(0 1 2 3)))))

  (it "keeps unknown and malformed names stable below known calendar-valid names"
    (let ((invalid '("" "/" "/virtual/manual"
                     "/virtual/20250229T120000-abcdef0"
                     "/virtual/19000229T120000-abcdef0"
                     "/virtual/20250431T120000-abcdef0"
                     "/virtual/20251301T120000-abcdef0"
                     "/virtual/20250001T120000-abcdef0"
                     "/virtual/20250100T120000-abcdef0"
                     "/virtual/20250101T240000-abcdef0"
                     "/virtual/20250101T126000-abcdef0"
                     "/virtual/20250101T120060-abcdef0"
                     "/virtual/20250101t120000-abcdef0"
                     "/virtual/20250101T120000-ghijklm"
                     "/virtual/20250101T120000-"
                     "/virtual/20250101T120000-abcdef0-1"
                     "/virtual/20250101T120000-abcdef0-0"
                     "/virtual/20250101T120000-abcdef0-02"
                     "/virtual/20250101T120000-abcdef0--2"
                     "/virtual/20250101T120000-abcdef0-2x"
                     "/virtual/20250101T120000-abcdef0/child")))
      (%expect-creation-order
       (append invalid '("/virtual/20000229T120000-abcdef0"))
       (cons (length invalid) (loop for index below (length invalid) collect index)))))

  (it "does not reorder after output focus agent or completed changes and republishing"
    (%call-with-creation-order-fixture
     '("/virtual/20250302T120000-abcdef0" "/virtual/20250301T120000-abcdef0")
     (lambda (organization repository worktrees organizations)
       (declare (ignore organization))
       (let ((pane (nerimux/pane:make-pane :id 801 :fd -1)))
         (nerimux/pane:worktree-add-pane (second worktrees) pane)
         (nerimux/vcs:set-workspace-organizations organizations)
         (dolist (change '(:output :focus :agent :completed :exit))
           (ecase change
             (:output (setf (nerimux/pane:pane-last-output-time pane) 100))
             (:focus (setf (nerimux/pane:pane-last-focused-time pane) 200))
             (:agent
              (setf (nerimux/pane:pane-agent-kind pane) :codex)
              (nerimux/pane:worktree-add-pane (second worktrees) pane))
             (:completed
              (setf (nerimux/workspace-model:worktree-completed-p (second worktrees)) t))
             (:exit (setf (nerimux/pane:pane-process-exited-p pane) t)))
           (nerimux/vcs:set-workspace-organizations organizations)
           (expect (equal worktrees
                          (nerimux/workspace-model:repository-worktrees repository))))))))

  (it "reconstructs creation order from paths without pane or persisted timestamp state"
    (let ((paths '("/virtual/20250301T120000-abcdef0"
                   "/virtual/20250302T120000-abcdef0")))
      (dotimes (iteration 2)
        (declare (ignore iteration))
        (%expect-creation-order (mapcar #'copy-seq paths) '(1 0)))))

  (it "preserves parent order and caller cons structure while sorting a copy of worktrees"
    (%call-with-creation-order-fixture
     '("/virtual/20250301T120000-abcdef0" "/virtual/20250302T120000-abcdef0")
     (lambda (organization repository worktrees organizations)
       (declare (ignore organizations))
       (let* ((other-org
                (nerimux/workspace-model:make-organization
                 :id "creation-other" :host "example.org" :name "other"))
              (other-repo
                (nerimux/workspace-model:make-repository
                 :id "creation-other-repo" :organization other-org
                 :specification "example.org/other/repo"))
              (second-repo
                (nerimux/workspace-model:make-repository
                 :id "creation-second-repo" :organization organization
                 :specification "example.org/team/second"))
              (pane (nerimux/pane:make-pane :id 802 :fd -1))
              (input (list other-org organization))
              (repos (list second-repo repository))
              (input-tail (cdr input))
              (repos-tail (cdr repos))
              (worktrees-tail (cdr worktrees))
              (worktree-snapshot (copy-list worktrees)))
         (setf (nerimux/workspace-model:organization-repositories other-org)
               (list other-repo)
               (nerimux/workspace-model:organization-repositories organization) repos)
         (nerimux/pane:worktree-add-pane (second worktrees) pane)
         (setf (nerimux/pane:pane-last-output-time pane) 100)
         (nerimux/vcs:set-workspace-organizations input)
         (expect (equal input (nerimux/vcs:workspace-organizations)))
         (expect (not (eq input (nerimux/vcs:workspace-organizations))))
         (expect (equal repos
                        (nerimux/workspace-model:organization-repositories organization)))
         (expect (eq input-tail (cdr input)))
         (expect (eq repos-tail (cdr repos)))
         (expect (eq worktrees-tail (cdr worktrees)))
         (expect (equal (list other-org organization) input))
         (expect (equal (list second-repo repository) repos))
         (expect (equal worktree-snapshot worktrees))
         (expect (equal (reverse worktree-snapshot)
                        (nerimux/workspace-model:repository-worktrees repository)))
         (expect (not (eq worktrees
                          (nerimux/workspace-model:repository-worktrees repository))))))))

  (it "accepts empty catalogs and repositories"
    (%call-with-creation-order-fixture
     nil
     (lambda (organization repository worktrees organizations)
       (declare (ignore organization worktrees))
       (nerimux/vcs:set-workspace-organizations organizations)
       (expect (null (nerimux/workspace-model:repository-worktrees repository)))
       (nerimux/vcs:set-workspace-organizations nil)
       (expect (null (nerimux/vcs:workspace-organizations)))))))
(describe "agent-workspace merge additions"
  (it "marks an absent worktree without querying the adapter"
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
                    (nerimux/workspace-model:repository-conflict-p repository)))))
)
