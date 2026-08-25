(in-package #:nerimux/test)

(defun %vcs-operations-existing-path ()
  (namestring (host-kit:temporary-directory)))

(defun %vcs-operations-missing-path ()
  (namestring
   (make-pathname
    :name (format nil "nerimux-vcs-operations-missing-~A" (gensym))
    :defaults (host-kit:temporary-directory))))

(defun %vcs-operations-poll-until (predicate &key (timeout-seconds 2.0))
  (let ((deadline (+ (get-internal-real-time)
                     (round (* timeout-seconds internal-time-units-per-second)))))
    (loop
      (when (funcall predicate)
        (return t))
      (when (>= (get-internal-real-time) deadline)
        (return))
      (sleep 0.01))))

(defun %vcs-operations-join (threads)
  (dolist (thread threads)
    (ignore-errors (sb-thread:join-thread thread :timeout 2))))

(defun %vcs-operations-fake-worktree
    (path &key branch head bare-p locked-p prunable-p)
  (vcs-kit::%make-vcs-worktree
   :path path
   :branch branch
   :head head
   :bare-p bare-p
   :locked-p locked-p
   :prunable-p prunable-p))

(defun %vcs-operations-status-entry (kind)
  (vcs-kit::%make-vcs-status-entry :kind kind))

(defun %vcs-operations-status-snapshot
    (&key entries branch-head ahead behind)
  (vcs-kit::%make-vcs-status-snapshot
   :entries entries
   :branch-head branch-head
   :ahead ahead
   :behind behind))

(defmacro with-vcs-operations-observations
    ((raw-worktrees &key status-snapshot status-entries status-branch-head
                    status-ahead status-behind)
     &body body)
  `(with-stubbed-fdefinition
       ((vcs-kit:make-vcs-repository
          (lambda (&rest arguments)
            (declare (ignore arguments))
            :vcs-operations-backend))
        (vcs-kit:vcs-list-worktrees
          (lambda (&rest arguments)
            (declare (ignore arguments))
            ,raw-worktrees))
        (vcs-kit:vcs-status-structured
          (lambda (&rest arguments)
            (declare (ignore arguments))
            (or ,status-snapshot
                (%vcs-operations-status-snapshot
                 :entries ,status-entries
                 :branch-head ,status-branch-head
                 :ahead ,status-ahead
                 :behind ,status-behind)))))
     ,@body))

(describe "vcs worktree observation boundaries"
  (it "rebuilds worktrees while retaining model state and pane bindings"
    (let* ((path (%vcs-operations-existing-path))
           (missing-path (%vcs-operations-missing-path))
           (repository
             (nerimux/model:make-repository
              :specification "workspace-owner/project"
              :local-path path))
           (pane (make-pane :id 41))
           (old-worktree
             (nerimux/model:make-worktree
              :id "preserved-id"
              :repository repository
              :path path
              :branch "feature/ui"
              :head "old-head"
              :status :old
              :dirty-p t
              :conflict-p t
              :ahead 2
              :behind 3))
           (raw-worktrees
             (list (%vcs-operations-fake-worktree
                    path
                    :branch "feature/ui"
                    :head "new-head")
                   (%vcs-operations-fake-worktree
                    missing-path
                    :branch "feature/missing"
                    :head "missing-head"))))
      (nerimux/model:repository-add-worktree repository old-worktree)
      (nerimux/model:worktree-add-pane old-worktree pane)
      (with-vcs-operations-observations
          (raw-worktrees
           :status-snapshot nil
           :status-entries nil
           :status-branch-head nil
           :status-ahead nil
           :status-behind nil)
        (let ((result (nerimux/vcs:list-repository-worktrees repository)))
          (let ((current (nerimux/model:repository-worktree-by-path
                          repository path))
                (missing (nerimux/model:repository-worktree-by-path
                          repository missing-path)))
            (expect (eq repository result))
            (expect (= 2 (length (nerimux/model:repository-worktrees repository))))
            (expect (string= "preserved-id"
                             (nerimux/model:worktree-id current)))
            (expect (eq :old (nerimux/model:worktree-status current)))
            (expect (nerimux/model:worktree-dirty-p current))
            (expect (nerimux/model:worktree-conflict-p current))
            (expect (= 2 (nerimux/model:worktree-ahead current)))
            (expect (= 3 (nerimux/model:worktree-behind current)))
            (expect (eq current (nerimux/model:pane-worktree pane)))
            (expect (nerimux/model:worktree-missing-p missing))
            (expect (null (nerimux/model:worktree-panes missing)))
            (expect (eq current
                       (nerimux/model:repository-main-worktree repository))))))))

  (it "maps structured status into worktree and repository state"
    (let* ((path (%vcs-operations-existing-path))
           (repository
             (nerimux/model:make-repository
              :specification "workspace-owner/project"
              :local-path path))
           (worktree
             (nerimux/model:make-worktree
              :repository repository
              :path path
              :branch "feature/ui"
              :head "old-head"))
           (status-entries
             (list (%vcs-operations-status-entry :ordinary)
                   (%vcs-operations-status-entry :unmerged)))
           (status-snapshot
             (%vcs-operations-status-snapshot
              :entries status-entries
              :branch-head "new-head"
              :ahead 4
              :behind 2))
           (status-branch-head "new-head")
           (status-ahead 4)
           (status-behind 2))
      (nerimux/model:repository-add-worktree repository worktree)
      (with-vcs-operations-observations
          (nil
           :status-snapshot status-snapshot
           :status-entries status-entries
           :status-branch-head status-branch-head
           :status-ahead status-ahead
           :status-behind status-behind)
        (nerimux/vcs:worktree-status worktree)
        (expect (eq status-snapshot
                    (nerimux/model:worktree-status worktree)))
        (expect (string= "new-head"
                         (nerimux/model:worktree-head worktree)))
        (expect (nerimux/model:worktree-dirty-p worktree))
        (expect (nerimux/model:worktree-conflict-p worktree))
        (expect (= 4 (nerimux/model:worktree-ahead worktree)))
        (expect (= 2 (nerimux/model:worktree-behind worktree)))
        (expect (nerimux/model:repository-dirty-p repository))
        (expect (nerimux/model:repository-conflict-p repository))
        (setf status-snapshot (%vcs-operations-status-snapshot))
        (nerimux/vcs:worktree-status worktree)
        (expect (eq status-snapshot
                    (nerimux/model:worktree-status worktree)))
        (expect (string= "new-head"
                         (nerimux/model:worktree-head worktree)))
        (expect (not (nerimux/model:worktree-dirty-p worktree)))
        (expect (not (nerimux/model:worktree-conflict-p worktree)))
        (expect (zerop (nerimux/model:worktree-ahead worktree)))
        (expect (zerop (nerimux/model:worktree-behind worktree)))
        (expect (not (nerimux/model:repository-dirty-p repository)))
        (expect (not (nerimux/model:repository-conflict-p repository))))))

(describe "vcs repository scanning"
  (it "groups repositories and sorts organizations while forwarding query"
    (let* ((path (%vcs-operations-existing-path))
           (entries
             (list
              (vcs-kit:make-ghq-repository-entry
               :specification "b-host/team/project-a"
               :path path)
              (vcs-kit:make-ghq-repository-entry
               :specification "a-host/team/project-b"
               :path path)))
           (raw-worktrees
             (list (%vcs-operations-fake-worktree
                    path
                    :branch "main"
                    :head "head")))
           (query-seen nil)
           (callback-result nil))
      (with-stubbed-fdefinition
          ((vcs-kit:ghq-list-repositories
             (lambda (&key query)
               (setf query-seen query)
               entries)))
        (with-vcs-operations-observations
            (raw-worktrees
             :status-snapshot nil
             :status-entries nil
             :status-branch-head nil
             :status-ahead nil
             :status-behind nil)
          (let ((result
                  (nerimux/vcs:scan-repositories
                   :query "workspace"
                   :on-complete (lambda (organizations)
                                  (setf callback-result organizations)))))
            (expect (string= "workspace" query-seen))
            (expect (eq result callback-result))
            (expect (= 2 (length result)))
            (expect (string<
                     (nerimux/model:organization-id (first result))
                     (nerimux/model:organization-id (second result))))
            (dolist (organization result)
              (expect (= 1
                         (length
                          (nerimux/model:organization-repositories
                           organization))))
              (expect (= 1
                         (length
                          (nerimux/model:repository-worktrees
                           (first (nerimux/model:organization-repositories
                                   organization)))))))))))))

  (it "keeps an unreadable repository in the catalog as missing"
    (let* ((path (%vcs-operations-existing-path))
           (entry
             (vcs-kit:make-ghq-repository-entry
              :specification "workspace-owner/project"
              :path path)))
      (with-stubbed-fdefinition
          ((vcs-kit:ghq-list-repositories
             (lambda (&key query)
               (declare (ignore query))
               (list entry)))
           (vcs-kit:make-vcs-repository
             (lambda (&rest arguments)
               (declare (ignore arguments))
               :unreadable-backend))
           (vcs-kit:vcs-list-worktrees
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "unreadable worktree metadata"))))
        (let* ((organizations (nerimux/vcs:scan-repositories))
               (repository
                 (first
                  (nerimux/model:organization-repositories
                   (first organizations)))))
          (expect (= 1 (length organizations)))
          (expect (nerimux/model:repository-missing-p repository))))))

  (it "reports a top-level repository scan failure"
    (let ((condition-seen nil))
      (with-stubbed-fdefinition
          ((vcs-kit:ghq-list-repositories
             (lambda (&key query)
               (declare (ignore query))
               (error "ghq unavailable"))))
        (expect
         (null
          (nerimux/vcs:scan-repositories
           :on-error (lambda (condition)
                       (setf condition-seen condition)))))
        (expect (typep condition-seen 'error))))))

(describe "vcs workspace refresh"
  (it "stores the scanned catalog and refreshes each repository"
    (let* ((path (%vcs-operations-existing-path))
           (repository
             (nerimux/model:make-repository
              :specification "workspace-owner/project"
              :local-path path))
           (organization
             (nerimux/model:make-organization
              :host "workspace-owner"
              :name "workspace"))
           (catalog (list organization))
           (query-seen nil)
           (refreshed nil)
           (callback-result nil)
           (previous (nerimux/vcs:workspace-organizations)))
      (nerimux/model:organization-add-repository organization repository)
      (unwind-protect
           (with-stubbed-fdefinition
               ((nerimux/vcs:scan-repositories
                  (lambda (&key query)
                    (setf query-seen query)
                    catalog))
                (nerimux/vcs:refresh-repository-status
                  (lambda (current)
                    (push current refreshed)
                    current)))
             (let ((result
                     (nerimux/vcs:refresh-workspace-organizations
                      :query "workspace"
                      :on-complete (lambda (organizations)
                                     (setf callback-result organizations)))))
               (expect (eq result callback-result))
               (expect (equal "workspace" query-seen))
               (expect (equal catalog (nerimux/vcs:workspace-organizations)))
               (expect (member repository refreshed :test #'eq))))
        (nerimux/vcs:set-workspace-organizations previous)))))

  (it "reports a synchronous workspace refresh failure"
    (let ((condition-seen nil)
          (previous (nerimux/vcs:workspace-organizations)))
      (unwind-protect
           (with-stubbed-fdefinition
               ((nerimux/vcs:scan-repositories
                  (lambda (&key query)
                    (declare (ignore query))
                    (error "scan failed"))))
             (expect
              (null
               (nerimux/vcs:refresh-workspace-organizations
                :on-error (lambda (condition)
                            (setf condition-seen condition)))))
             (expect (typep condition-seen 'error)))
        (nerimux/vcs:set-workspace-organizations previous))))

(describe "vcs worktree commands"
  (it "emits exact synchronous worktree operation commands"
    (let* ((repository-path (%vcs-operations-existing-path))
           (secondary-path (concatenate 'string repository-path "secondary"))
           (repository
             (nerimux/model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (main-worktree
             (nerimux/model:make-worktree
              :repository repository
              :path repository-path
              :branch "main"))
           (secondary-worktree
             (nerimux/model:make-worktree
              :repository repository
              :path secondary-path
              :branch "feature/ui"))
           (commands nil))
      (nerimux/model:repository-add-worktree repository main-worktree)
      (nerimux/model:repository-add-worktree repository secondary-worktree)
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (&rest arguments)
               (declare (ignore arguments))
               :command-backend))
           (vcs-kit:vcs-worktree
             (lambda (backend &rest arguments)
               (declare (ignore backend))
               (push (copy-list arguments) commands)
               :command-result))
           (nerimux/vcs:list-repository-worktrees
             (lambda (current) current))
           (nerimux/vcs:refresh-repository-status
             (lambda (current) current)))
        (expect (nerimux/vcs:delete-worktree secondary-worktree))
        (expect (nerimux/vcs:delete-worktree secondary-worktree :force t))
        (expect (nerimux/vcs:lock-worktree secondary-worktree :reason "reason"))
        (expect (nerimux/vcs:lock-worktree secondary-worktree :reason ""))
        (expect (nerimux/vcs:unlock-worktree secondary-worktree))
        (expect (eq :command-result
                    (nerimux/vcs:prune-worktrees
                     repository
                     :dry-run nil
                     :verbose t)))
        (expect
         (equal
          (list (list "remove" secondary-path)
                (list "remove" "--force" secondary-path)
                (list "lock" "--reason" "reason" secondary-path)
                (list "lock" secondary-path)
                (list "unlock" secondary-path)
                (list "prune" "--verbose"))
          (nreverse commands)))
        (let ((condition-seen nil))
          (handler-case
              (nerimux/vcs:delete-worktree main-worktree)
            (error (condition)
              (setf condition-seen condition)))
          (expect (typep condition-seen 'error)))))))

(describe "vcs worktree creation"
  (it "creates worktrees from default and explicit start points"
    (let* ((repository-path (%vcs-operations-existing-path))
           (repository
             (nerimux/model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (raw-worktrees nil)
           (commands nil))
      (with-vcs-operations-observations
          (raw-worktrees
           :status-snapshot nil
           :status-entries nil
           :status-branch-head nil
           :status-ahead nil
           :status-behind nil)
        (with-stubbed-fdefinition
            ((vcs-kit:git-rev-parse-value
               (lambda (backend &rest arguments)
                 (declare (ignore backend))
                 (cond
                   ((equal '("origin/HEAD") arguments)
                    "origin/main")
                   ((equal '("--short" "origin/main") arguments)
                    "abc1234")
                   ((equal '("--short" "release") arguments)
                    "def5678")
                   (t
                    (error "unexpected rev-parse arguments: ~S" arguments)))))
             (vcs-kit:vcs-worktree
               (lambda (backend &rest arguments)
                 (declare (ignore backend))
                 (push (copy-list arguments) commands)
                 (let ((path (nth (- (length arguments) 2) arguments))
                       (branch (nth (- (length arguments) 3) arguments))
                       (head (car (last arguments))))
                   (setf raw-worktrees
                         (list (%vcs-operations-fake-worktree
                                path
                                :branch branch
                                :head head))))
                 :created))
             (nerimux/vcs:refresh-repository-status
               (lambda (current) current)))
          (let* ((first-path (concatenate 'string repository-path "first"))
                 (first-worktree
                   (nerimux/vcs:create-worktree
                    repository
                    :branch "feature/first"
                    :path first-path)))
            (expect (string= first-path
                             (nerimux/model:worktree-path first-worktree)))
            (expect (equal
                     (list "add" "-b" "feature/first" first-path "origin/main")
                     (first commands))))
          (let* ((second-path (concatenate 'string repository-path "second"))
                 (second-worktree
                   (nerimux/vcs:create-worktree
                    repository
                    :branch "feature/second"
                    :path second-path
                    :start-point "release"
                    :force t)))
            (expect (string= second-path
                             (nerimux/model:worktree-path second-worktree)))
            (expect (equal
                     (list "add" "--force" "-b" "feature/second"
                           second-path "release")
                     (first commands))))
          (let ((condition-seen nil))
            (handler-case
                (nerimux/vcs:create-worktree repository :branch "")
              (error (condition)
                (setf condition-seen condition)))
            (expect (typep condition-seen 'error))))))))

(describe "vcs asynchronous operation callbacks"
  (it "routes successful operations and errors through callbacks"
    (let ((lock (cl-concurrent-kit:make-lock :name "vcs-operations-test"))
          (results nil)
          (condition-seen nil)
          (threads nil))
      (labels ((record-result (tag)
                 (lambda (result)
                   (cl-concurrent-kit:with-lock-held (lock)
                     (push (list tag result) results))))
               (record-error (condition)
                 (cl-concurrent-kit:with-lock-held (lock)
                   (setf condition-seen condition))))
        (unwind-protect
             (progn
               (with-stubbed-fdefinition
                   ((nerimux/vcs:create-worktree
                      (lambda (&rest arguments)
                        (declare (ignore arguments))
                        :created))
                    (nerimux/vcs:delete-worktree
                      (lambda (&rest arguments)
                        (declare (ignore arguments))
                        :deleted))
                    (nerimux/vcs:lock-worktree
                      (lambda (&rest arguments)
                        (declare (ignore arguments))
                        :locked))
                 (nerimux/vcs:unlock-worktree
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     :unlocked))
                 (nerimux/vcs:prune-worktrees
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     :pruned)))
                 (push
                  (nerimux/vcs:create-worktree-async
                   nil
                   :branch "feature"
                   :on-complete (record-result :create))
                  threads)
                 (push
                  (nerimux/vcs:delete-worktree-async
                   nil
                   :on-complete (record-result :delete))
                  threads)
                 (push
                  (nerimux/vcs:lock-worktree-async
                   nil
                   :on-complete (record-result :lock))
                  threads)
                 (push
                  (nerimux/vcs:unlock-worktree-async
                   nil
                   :on-complete (record-result :unlock))
                  threads)
                 (push
                  (nerimux/vcs:prune-worktrees-async
                   nil
                   :dry-run nil
                   :verbose t
                   :on-complete (record-result :prune))
                  threads)
                 (expect
                  (%vcs-operations-poll-until
                   (lambda ()
                     (cl-concurrent-kit:with-lock-held (lock)
                       (= 5 (length results))))))
                 (let ((observed
                         (cl-concurrent-kit:with-lock-held (lock)
                           (let ((table (make-hash-table :test #'equal)))
                             (dolist (result results)
                               (setf (gethash result table) t))
                             table))))
                   (dolist (expected
                            '((:create :created)
                              (:delete :deleted)
                              (:lock :locked)
                              (:unlock :unlocked)
                              (:prune :pruned)))
                     (expect (gethash expected observed)))))
               (with-stubbed-fdefinition
                   ((nerimux/vcs:create-worktree
                      (lambda (&rest arguments)
                        (declare (ignore arguments))
                        (error "create failed"))))
                 (push
                  (nerimux/vcs:create-worktree-async
                   nil
                   :branch "feature"
                   :on-error #'record-error)
                  threads)
                 (expect
                  (%vcs-operations-poll-until
                   (lambda ()
                     (cl-concurrent-kit:with-lock-held (lock)
                       (typep condition-seen 'error)))))))
          (%vcs-operations-join threads))))))

(describe "vcs synchronous fetch"
  (it "fetches through the adapter and refreshes status"
    (let* ((repository
             (nerimux/model:make-repository
              :specification "workspace-owner/project"
              :local-path (%vcs-operations-existing-path)))
           (fetch-call nil)
           (refresh-call nil))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (&rest arguments)
               (declare (ignore arguments))
               :fetch-backend))
           (vcs-kit:vcs-fetch
             (lambda (backend &rest arguments)
               (setf fetch-call (list backend arguments))
               :fetched))
           (nerimux/vcs:refresh-repository-status
             (lambda (current)
               (setf refresh-call current)
               current)))
        (expect (eq repository (nerimux/vcs::fetch-repository repository)))
        (expect (equal '(:fetch-backend nil) fetch-call))
        (expect (eq repository refresh-call))
        (let ((condition-seen nil))
          (handler-case
              (nerimux/vcs::fetch-repository nil)
            (error (condition)
              (setf condition-seen condition)))
          (expect (typep condition-seen 'error)))))))
