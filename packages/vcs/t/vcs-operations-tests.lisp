(in-package #:nerimux/test/vcs)

(defun %vcs-operations-existing-path ()
  (namestring (host-kit:temporary-directory)))

(defun %vcs-operations-missing-path ()
  (namestring
   (make-pathname :name
                  (format nil "nerimux-vcs-operations-missing-~A" (gensym))
                  :defaults
                  (host-kit:temporary-directory))))

(defun %vcs-operations-poll-until (predicate &key (timeout-seconds 2.0))
  (let ((deadline
         (+ (get-internal-real-time)
            (round (* timeout-seconds internal-time-units-per-second)))))
    (loop (when (funcall predicate)
            (return t)) (when (>= (get-internal-real-time) deadline)
                          (return)) (sleep 0.01))))

(defun %vcs-operations-join (threads)
  (dolist (thread threads)
    (ignore-errors (sb-thread:join-thread thread :timeout 2))))

(defun %vcs-operations-fake-worktree (path &key
                                           branch
                                           head
                                           bare-p
                                           locked-p
                                           prunable-p)
  (vcs-kit::%make-vcs-worktree :path
                               path
                               :branch
                               branch
                               :head
                               head
                               :bare-p
                               bare-p
                               :locked-p
                               locked-p
                               :prunable-p
                               prunable-p))

(defun %vcs-operations-status-entry (kind)
  (vcs-kit::%make-vcs-status-entry :kind kind))

(defun %vcs-operations-status-snapshot (&key entries branch-head ahead behind)
  (vcs-kit::%make-vcs-status-snapshot :entries
                                      entries
                                      :branch-head
                                      branch-head
                                      :ahead
                                      ahead
                                      :behind
                                      behind))

(defmacro with-vcs-operations-observations ((raw-worktrees &key
                                                           status-snapshot
                                                           status-entries
                                                           status-branch-head
                                                           status-ahead
                                                           status-behind) &body
                                                                          body)
  `(with-stubbed-fdefinition
    ((nerimux/vcs::%git-worktree-list
      (lambda (&rest arguments)
        (declare (ignore arguments))
        ,raw-worktrees))
     (nerimux/vcs::%git-status-snapshot
      (lambda (&rest arguments)
        (declare (ignore arguments))
        (or ,status-snapshot
            (%vcs-operations-status-snapshot :entries
                                             ,status-entries
                                             :branch-head
                                             ,status-branch-head
                                             :ahead
                                             ,status-ahead
                                             :behind
                                             ,status-behind))))
     (nerimux/vcs::%git-numstat-entries
      (lambda (&rest arguments)
        (declare (ignore arguments))
        nil)))
    ,@body))

(describe "vcs worktree observation boundaries"
          (it "rebuilds worktrees while retaining model state and pane bindings"
              (let* ((path (%vcs-operations-existing-path))
                     (missing-path (%vcs-operations-missing-path))
                     (repository
                      (nerimux/workspace-model:make-repository :specification
                                                               "workspace-owner/project"
                                                               :local-path
                                                               path))
                     (pane (make-pane :id 41))
                     (old-worktree
                      (nerimux/workspace-model:make-worktree :id
                                                             "preserved-id"
                                                             :repository
                                                             repository
                                                             :path
                                                             path
                                                             :branch
                                                             "feature/ui"
                                                             :head
                                                             "old-head"
                                                             :status
                                                             :old
                                                             :dirty-p
                                                             t
                                                             :conflict-p
                                                             t
                                                             :ahead
                                                             2
                                                             :behind
                                                             3
                                                             :additions
                                                             5
                                                             :deletions
                                                             2))
                     (raw-worktrees
                      (list
                       (%vcs-operations-fake-worktree path
                                                      :branch
                                                      "feature/ui"
                                                      :head
                                                      "new-head")
                       (%vcs-operations-fake-worktree missing-path
                                                      :branch
                                                      "feature/missing"
                                                      :head
                                                      "missing-head"))))
                (nerimux/workspace-model:repository-add-worktree repository
                                                                 old-worktree)
                (nerimux/pane:worktree-add-pane old-worktree pane)
                (with-vcs-operations-observations
                 (raw-worktrees :status-snapshot
                                nil
                                :status-entries
                                nil
                                :status-branch-head
                                nil
                                :status-ahead
                                nil
                                :status-behind
                                nil)
                 (let ((result
                        (nerimux/vcs:list-repository-worktrees repository)))
                   (let ((current
                          (nerimux/workspace-model:repository-worktree-by-path
                           repository
                           path))
                         (missing
                          (nerimux/workspace-model:repository-worktree-by-path
                           repository
                           missing-path)))
                     (expect (eq repository result))
                     (expect
                      (= 2
                         (length
                          (nerimux/workspace-model:repository-worktrees
                           repository))))
                     (expect
                      (string= "preserved-id"
                               (nerimux/workspace-model:worktree-id current)))
                     (expect
                      (eq :old
                          (nerimux/workspace-model:worktree-status current)))
                     (expect (nerimux/workspace-model:worktree-dirty-p current))
                     (expect
                      (nerimux/workspace-model:worktree-conflict-p current))
                     (expect
                      (= 2 (nerimux/workspace-model:worktree-ahead current)))
                     (expect
                      (= 3 (nerimux/workspace-model:worktree-behind current)))
                     (expect
                      (= 5
                         (nerimux/workspace-model:worktree-additions current)))
                     (expect
                      (= 2
                         (nerimux/workspace-model:worktree-deletions current)))
                     (expect (eq current (nerimux/pane:pane-worktree pane)))
                     (expect
                      (nerimux/workspace-model:worktree-missing-p missing))
                     (expect
                      (null (nerimux/workspace-model:worktree-panes missing)))
                     (expect
                      (eq current
                          (nerimux/workspace-model:repository-main-worktree
                           repository))))))))
          (it "maps structured status into worktree and repository state"
              (let* ((path (%vcs-operations-existing-path))
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
                                                             :head
                                                             "old-head"))
                     (status-entries
                      (list (%vcs-operations-status-entry :ordinary)
                            (%vcs-operations-status-entry :unmerged)))
                     (status-snapshot
                      (%vcs-operations-status-snapshot :entries
                                                       status-entries
                                                       :branch-head
                                                       "new-head"
                                                       :ahead
                                                       4
                                                       :behind
                                                       2))
                     (status-branch-head "new-head")
                     (status-ahead 4)
                     (status-behind 2))
                (nerimux/workspace-model:repository-add-worktree repository
                                                                 worktree)
                (with-vcs-operations-observations
                 (nil :status-snapshot
                      status-snapshot
                      :status-entries
                      status-entries
                      :status-branch-head
                      status-branch-head
                      :status-ahead
                      status-ahead
                      :status-behind
                      status-behind)
                 (nerimux/vcs:worktree-status worktree)
                 (expect
                  (eq status-snapshot
                      (nerimux/workspace-model:worktree-status worktree)))
                 (expect
                  (string= "new-head"
                           (nerimux/workspace-model:worktree-head worktree)))
                 (expect (nerimux/workspace-model:worktree-dirty-p worktree))
                 (expect (nerimux/workspace-model:worktree-conflict-p worktree))
                 (expect
                  (= 4 (nerimux/workspace-model:worktree-ahead worktree)))
                 (expect
                  (= 2 (nerimux/workspace-model:worktree-behind worktree)))
                 (expect
                  (nerimux/workspace-model:repository-dirty-p repository))
                 (expect
                  (nerimux/workspace-model:repository-conflict-p repository))
                 (setf status-snapshot (%vcs-operations-status-snapshot))
                 (nerimux/vcs:worktree-status worktree)
                 (expect
                  (eq status-snapshot
                      (nerimux/workspace-model:worktree-status worktree)))
                 (expect
                  (string= "new-head"
                           (nerimux/workspace-model:worktree-head worktree)))
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
          (describe "vcs repository scanning"
                    (it
                     "groups repositories and sorts organizations while forwarding query"
                     (let* ((path (%vcs-operations-existing-path))
                            (entries
                             (list
                              (vcs-kit:make-ghq-repository-entry :specification
                                                                 "b-host/team/project-a"
                                                                 :path
                                                                 path)
                              (vcs-kit:make-ghq-repository-entry :specification
                                                                 "a-host/team/project-b"
                                                                 :path
                                                                 path)))
                            (raw-worktrees
                             (list
                              (%vcs-operations-fake-worktree path
                                                             :branch
                                                             "main"
                                                             :head
                                                             "head")))
                            (query-seen nil)
                            (callback-result nil))
                       (with-stubbed-fdefinition
                        ((vcs-kit:ghq-list-repositories
                          (lambda (&key query)
                            (setf query-seen query)
                            entries)))
                        (with-vcs-operations-observations
                         (raw-worktrees :status-snapshot
                                        nil
                                        :status-entries
                                        nil
                                        :status-branch-head
                                        nil
                                        :status-ahead
                                        nil
                                        :status-behind
                                        nil)
                         (let ((result
                                (nerimux/vcs:scan-repositories :query
                                                               "workspace"
                                                               :on-complete
                                                               (lambda 
                                                                   (organizations)
                                                                 (setf callback-result organizations)))))
                           (expect (string= "workspace" query-seen))
                           (expect (eq result callback-result))
                           (expect (= 2 (length result)))
                           (expect
                            (string<
                             (nerimux/workspace-model:organization-id
                              (first result))
                             (nerimux/workspace-model:organization-id
                              (second result))))
                           (dolist (organization result)
                             (expect
                              (= 1
                                 (length
                                  (nerimux/workspace-model:organization-repositories
                                   organization))))
                             (expect
                              (= 1
                                 (length
                                  (nerimux/workspace-model:repository-worktrees
                                   (first
                                    (nerimux/workspace-model:organization-repositories
                                     organization))))))))))))
                    (it "publishes one canonical repository for its GHQ worktree entries"
  (let* ((saved-organizations (nerimux/vcs:workspace-organizations))
         (ghq-root "/scan/ghq")
         (bare-path "/scan/ghq/example.test/org/bare-repo")
         (alpha-path "/scan/ghq/example.test/org/bare-repo/.worktrees/alpha")
         (beta-path "/scan/ghq/example.test/org/bare-repo/.worktrees/beta")
         (detached-path "/scan/ghq/example.test/org/bare-repo/.worktrees/detached")
         (raw-worktrees
           (list (%vcs-operations-fake-worktree bare-path :bare-p t)
                 (%vcs-operations-fake-worktree alpha-path :branch "feature/alpha")
                 (%vcs-operations-fake-worktree beta-path :branch "feature/beta")
                 (%vcs-operations-fake-worktree detached-path :branch "feature/detached")))
         (entries
           (list
            (vcs-kit:make-ghq-repository-entry
             :specification "example.test/org/bare-repo/.worktrees/alpha"
             :path alpha-path :backend :git)
            (vcs-kit:make-ghq-repository-entry
             :specification "example.test/org/bare-repo/.worktrees/beta"
             :path beta-path :backend :git)
            (vcs-kit:make-ghq-repository-entry
             :specification "example.test/org/bare-repo/.worktrees/detached"
             :path detached-path :backend :git)))
         (previous-organization
           (nerimux/workspace-model:make-organization
            :id "example.test/org" :host "example.test" :name "org"))
         (previous-repository
           (nerimux/workspace-model:make-repository
            :specification "example.test/org/bare-repo"
            :local-path bare-path :organization previous-organization))
         (previous-alpha
           (nerimux/workspace-model:make-worktree
            :id "previous-alpha" :repository previous-repository
            :path alpha-path :branch "feature/alpha"))
         (pane (make-pane :id 908)))
    (progn
  (nerimux/workspace-model:organization-add-repository
   previous-organization previous-repository)
  (nerimux/workspace-model:repository-add-worktree
   previous-repository previous-alpha))
    (nerimux/pane:worktree-add-pane previous-alpha pane)
    (unwind-protect
         (progn
           (nerimux/vcs:set-workspace-organizations (list previous-organization))
           (with-stubbed-fdefinition
               ((vcs-kit:ghq-list-repositories
                  (lambda (&key query)
                    (declare (ignore query))
                    entries))
                (nerimux/vcs:ghq-root-directory
                  (lambda () ghq-root))
                (nerimux/vcs::%directory-repository-root
                  (lambda (directory)
                    (declare (ignore directory))
                    (values bare-path raw-worktrees)))
                (nerimux/vcs:list-repository-worktrees
                  (lambda (repository)
                    (nerimux/vcs::%apply-repository-worktrees
                     repository raw-worktrees nil))))
             (let* ((organizations (nerimux/vcs:scan-repositories))
                    (repositories
                      (loop for organization in organizations
                            append
                            (nerimux/workspace-model:organization-repositories
                             organization)))
                    (repository (first repositories))
                    (alpha
                      (and repository
                           (find alpha-path
                                 (nerimux/workspace-model:repository-worktrees
                                  repository)
                                 :key
                                 (function nerimux/workspace-model:worktree-path)
                                 :test
                                 (function string=)))))
               (nerimux/vcs:set-workspace-organizations organizations)
               (expect (= 1 (length repositories)))
               (expect (string= bare-path
                                (nerimux/workspace-model:repository-local-path
                                 repository)))
               (expect (= 3
                          (length
                           (nerimux/workspace-model:repository-worktrees
                            repository))))
               (expect alpha)
               (expect (eq alpha (pane-worktree pane)))
               (expect (eq repository
                           (nerimux/workspace-model:worktree-repository alpha)))
               (expect (string= "feature/alpha"
                                (nerimux/workspace-model:worktree-branch
                                 alpha))))))
      (nerimux/vcs:set-workspace-organizations saved-organizations)
      (setf (pane-worktree pane) nil))))
)
          (it "keeps an unreadable repository in the catalog as missing"
              (let* ((path (%vcs-operations-existing-path))
                     (entry
                      (vcs-kit:make-ghq-repository-entry :specification
                                                         "workspace-owner/project"
                                                         :path
                                                         path)))
                (with-stubbed-fdefinition
                 ((vcs-kit:ghq-list-repositories
                   (lambda (&key query)
                     (declare (ignore query))
                     (list entry)))
                  (nerimux/vcs::%git-worktree-list
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (error "unreadable worktree metadata"))))
                 (let* ((organizations (nerimux/vcs:scan-repositories))
                        (repository
                         (first
                          (nerimux/workspace-model:organization-repositories
                           (first organizations)))))
                   (expect (= 1 (length organizations)))
                   (expect
                    (nerimux/workspace-model:repository-missing-p repository))))))
          (it "keeps scanning the full repository set after an individual read error"
              (let* ((entries
                       (list
                        (vcs-kit:make-ghq-repository-entry
                         :specification "workspace-owner/one" :path "/scan/one")
                        (vcs-kit:make-ghq-repository-entry
                         :specification "workspace-owner/failing" :path "/scan/failing")
                        (vcs-kit:make-ghq-repository-entry
                         :specification "workspace-owner/two" :path "/scan/two")))
                     (progress-lock (cl-concurrent-kit:make-lock
                                     :name "vcs scan progress test"))
                     (progress nil))
                (with-stubbed-fdefinition
                 ((vcs-kit:ghq-list-repositories
                   (lambda (&key query)
                     (declare (ignore query))
                     entries))
                  (nerimux/vcs:list-repository-worktrees
                   (lambda (repository)
                     (when (string= "/scan/failing"
                                    (nerimux/workspace-model:repository-local-path
                                     repository))
                       (error "synthetic repository read failure"))
                     repository)))
                 (let* ((organizations
                          (nerimux/vcs:scan-repositories
                           :on-progress
                           (lambda (count)
                             (cl-concurrent-kit:with-lock-held (progress-lock)
                               (push count progress)))))
                        (repositories
                          (loop for organization in organizations
                                append
                                (nerimux/workspace-model:organization-repositories
                                 organization)))
                        (failing
                          (find "/scan/failing" repositories
                                :key #'nerimux/workspace-model:repository-local-path
                                :test #'string=)))
                   (expect (= 3 (length repositories)))
                   (expect
                    (equal '("workspace-owner/failing"
                             "workspace-owner/one"
                             "workspace-owner/two")
                           (sort
                            (mapcar
                             #'nerimux/workspace-model:repository-specification
                             repositories)
                            #'string<)))
                   (expect failing)
                   (expect (nerimux/workspace-model:repository-missing-p failing))
                   (expect
                    (equal '(1 2 3)
           (sort (copy-list progress) #'<)))))))
          (it "reports an individual repository construction failure"
              (let ((condition-seen nil)
                    (complete-called nil)
                    (entry
                     (vcs-kit:make-ghq-repository-entry
                      :specification "workspace-owner/broken"
                      :path "/scan/broken")))
                (with-stubbed-fdefinition
                 ((vcs-kit:ghq-list-repositories
                   (lambda (&key query)
                     (declare (ignore query))
                     (list entry)))
                  (nerimux/vcs::%repository-from-entry
                   (lambda (ignored-entry)
                     (declare (ignore ignored-entry))
                     (error "synthetic repository construction failure"))))
                 (expect
                  (null
                   (nerimux/vcs:scan-repositories
                    :on-complete (lambda (organizations)
                                   (declare (ignore organizations))
                                   (setf complete-called t))
                    :on-error (lambda (condition)
                                (setf condition-seen condition)))))
                 (expect (typep condition-seen 'error))
                 (expect (not complete-called)))))
          (it "reports progress callback failures after all workers stop"
              (let ((condition-seen nil)
                    (complete-called nil)
                    (entries
                     (list
                      (vcs-kit:make-ghq-repository-entry
                       :specification "workspace-owner/one" :path "/scan/one")
                      (vcs-kit:make-ghq-repository-entry
                       :specification "workspace-owner/two" :path "/scan/two"))))
                (with-stubbed-fdefinition
                 ((vcs-kit:ghq-list-repositories
                   (lambda (&key query)
                     (declare (ignore query))
                     entries))
                  (nerimux/vcs:list-repository-worktrees
                   (lambda (repository) repository)))
                 (expect
                  (null
                   (nerimux/vcs:scan-repositories
                    :on-progress (lambda (count)
                                   (declare (ignore count))
                                   (error "synthetic progress failure"))
                    :on-complete (lambda (organizations)
                                   (declare (ignore organizations))
                                   (setf complete-called t))
                    :on-error (lambda (condition)
                                (setf condition-seen condition)))))
                 (expect (typep condition-seen 'error))
                 (expect (not complete-called)))))
          (it "reports a top-level repository scan failure"
              (let ((condition-seen nil))
                (with-stubbed-fdefinition
                 ((vcs-kit:ghq-list-repositories
                   (lambda (&key query)
                     (declare (ignore query))
                     (error "ghq unavailable"))))
                 (expect
                  (null
                   (nerimux/vcs:scan-repositories :on-error
                                                  (lambda (condition)
                                                    (setf condition-seen condition)))))
                 (expect (typep condition-seen 'error))))))

(describe "vcs worktree creation"
  (it "creates worktrees from default and explicit start points"
    (let* ((repository-path (%vcs-operations-missing-path))
           (worktree-parent
            (nerimux/vcs::%ensure-trailing-slash
             (namestring
              (nerimux/vcs:resolve-path-prefix
               (concatenate 'string repository-path ".worktrees/")))))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (raw-worktrees nil)
           (branch-commands nil)
           (worktree-commands nil))
      (with-vcs-operations-observations
          (raw-worktrees
           :status-snapshot nil
           :status-entries nil
           :status-branch-head nil
           :status-ahead nil
           :status-behind nil)
        (with-stubbed-fdefinition
            ((nerimux/vcs:worktree-parent-directory
               (lambda (current)
                 (unless (eq current repository)
                   (error "Unexpected repository"))
                 worktree-parent))
             (vcs-kit:git-symbolic-ref
               (lambda (backend &rest arguments)
                 (declare (ignore backend))
                 (if (equal '("-q" "refs/remotes/origin/HEAD") arguments)
                     (process-kit:make-process-result
                      :stdout "refs/remotes/origin/main")
                     (error "unexpected symbolic-ref arguments: ~S" arguments))))
             (vcs-kit:git-rev-parse-value
               (lambda (backend &rest arguments)
                 (declare (ignore backend))
                 (cond
                   ((equal '("--verify" "--quiet"
                             "refs/remotes/origin/main^{commit}")
                           arguments)
                    "origin/main")
                   ((equal '("--short" "origin/main") arguments)
                    "abc1234")
                   ((equal '("--short" "release") arguments)
                    "def5678")
                   (t
                    (error "unexpected rev-parse arguments: ~S" arguments)))))
             (vcs-kit:vcs-branch
               (lambda (backend &rest arguments)
                 (declare (ignore backend))
                 (push (copy-list arguments) branch-commands)))
             (vcs-kit:vcs-worktree
               (lambda (backend &rest arguments)
                 (declare (ignore backend))
                 (push (copy-list arguments) worktree-commands)
                 (let* ((options-position (position :execution-options arguments))
                        (command-arguments (subseq arguments 0 options-position))
                        (path (nth (- (length command-arguments) 2) command-arguments))
                        (branch (first (last command-arguments))))
                   (progn
                     (ensure-directories-exist (format nil "~A/placeholder" path))
                     (setf raw-worktrees
                           (list (%vcs-operations-fake-worktree
                                  path :branch branch :head "deadbeef"))))
                   :created))
             (nerimux/vcs:refresh-repository-status
               (lambda (current) current))))
          (let* ((first-path (concatenate 'string worktree-parent "first"))
                 (first-worktree
                   (nerimux/vcs:create-worktree
                    repository :branch "feature/first" :path first-path)))
            (expect (string= first-path
                             (nerimux/workspace-model:worktree-path first-worktree)))
            (expect
             (equal
              (append (list "add" "--" first-path "feature/first")
                      (list :execution-options
                            (nerimux/vcs::%worktree-operation-execution-options)))
              (first worktree-commands)))
            (expect
             (equal
              (append (list "--" "feature/first" "origin/main")
                      (list :execution-options
                            (nerimux/vcs::%worktree-operation-execution-options)))
              (first branch-commands))))
          (let* ((second-path (concatenate 'string worktree-parent "second"))
                 (second-worktree
                   (nerimux/vcs:create-worktree
                    repository
                    :branch "feature/second"
                    :path second-path
                    :start-point "release"
                    :force t)))
            (expect (string= second-path
                             (nerimux/workspace-model:worktree-path second-worktree)))
            (expect
             (equal
              (append (list "add" "--force" "--" second-path "feature/second")
                      (list :execution-options
                            (nerimux/vcs::%worktree-operation-execution-options)))
              (first worktree-commands)))
            (expect
             (equal
              (append (list "--" "feature/second" "release")
                      (list :execution-options
                            (nerimux/vcs::%worktree-operation-execution-options)))
              (first branch-commands))))
          (let ((condition-seen nil))
            (handler-case
                (nerimux/vcs:create-worktree repository :branch "")
              (error (condition)
                (setf condition-seen condition)))
            (progn
              (expect (typep condition-seen (quote error)))
              (when (probe-file worktree-parent)
                (uiop:delete-directory-tree (pathname worktree-parent)
                                            :validate t))))))))

  (it "falls back to local HEAD when origin/HEAD cannot be resolved"
    (let* ((repository-path (%vcs-operations-existing-path))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (condition-seen nil)
           (start-point nil))
      (with-stubbed-fdefinition
          ((vcs-kit:git-rev-parse-value
             (lambda (backend &rest arguments)
               (declare (ignore backend))
               (cond
                 ((equal '("origin/HEAD") arguments)
                  (error "fatal: ambiguous argument 'origin/HEAD': unknown revision or path not in the working tree."))
                 ((equal '("HEAD") arguments)
                  "deadbeefcafe")
                 (t
                  (error "unexpected rev-parse arguments: ~S" arguments))))))
        (handler-case
            (setf start-point
                  (nerimux/vcs::%default-branch-start-point repository))
          (error (condition) (setf condition-seen condition))))
      (expect (null condition-seen))
      (expect (string= "deadbeefcafe" start-point))))

  (it "rev-parse-passes-a-git-layer-repository-handle-not-the-vcs-backend-one"
    (let* ((repository-path (%vcs-operations-existing-path))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path repository-path))
           (captured nil))
      (with-stubbed-fdefinition
          ((vcs-kit:git-rev-parse-value
             (lambda (backend &rest arguments)
               (declare (ignore arguments))
               (setf captured backend)
               "origin/main")))
        (nerimux/vcs::%rev-parse repository "origin/HEAD"))
      (expect (typep captured 'vcs-kit:repository))
      (expect (not (typep captured 'vcs-kit:vcs-repository))))))

  (describe "repository-helper-suite"

    (it "resolves local HEAD when no default branch can be named"
    (let ((repository
            (nerimux/workspace-model:make-repository
             :specification "workspace-owner/project"
             :local-path (%vcs-operations-existing-path)))
          (arguments-seen nil))
      (with-stubbed-fdefinition
          ((vcs-kit:git-rev-parse-value
             (lambda (backend &rest arguments)
               (declare (ignore backend))
               (push arguments arguments-seen)
               "local-head")))
        (expect (string= "local-head"
                         (nerimux/vcs::%default-branch-start-point repository)))
        (expect (equal '(("HEAD")) arguments-seen)))))

  (it "builds worktree command arguments from option data"
    (dolist (row '(("remove" ("--force") ("remove" "--force" "/tmp/tree"))
                   ("lock" (nil "reason") ("lock" "reason" "/tmp/tree"))
                   ("unlock" () ("unlock" "/tmp/tree"))))
      (destructuring-bind (operation options expected) row
        (expect (equal expected
                       (append
                        (apply #'nerimux/vcs::%worktree-command-arguments
                               operation options)
                        (list "/tmp/tree"))))))
    (expect (equal '("add" "-b" "feature/ui" "--" "/tmp/tree" "HEAD")
                   (nerimux/vcs::%create-worktree-arguments
                    "feature/ui" "/tmp/tree" "HEAD" nil)))
    (expect (equal '("add" "--force" "-b" "feature/ui" "--" "/tmp/tree" "HEAD")
                   (nerimux/vcs::%create-worktree-arguments
                    "feature/ui" "/tmp/tree" "HEAD" t))))

  (it "always places -- immediately before the positional path, so a path or start-point starting with - cannot be read as a flag"
    (dolist (arguments (list (nerimux/vcs::%create-worktree-arguments
                              "-evil" "-x" "-y" nil)
                             (nerimux/vcs::%create-worktree-arguments
                              "-evil" "-x" "-y" t)))
      (let ((dash-dash (position "--" arguments :test #'string=))
            (path (position "-x" arguments :test #'string=)))
        (expect dash-dash)
        (expect path)
        (expect (= (1+ dash-dash) path)))))

  (it "normalizes repository specifications and values through pure helpers"
    (dolist (row '((nil "")
                   ("owner/project" "owner/project")
                   (#p"/tmp/project" "/tmp/project")
                   (42 "42")))
      (expect (string= (second row)
                       (nerimux/vcs::%string-value (first row)))))
    (multiple-value-bind (host name)
        (nerimux/vcs::%organization-and-name "github/owner/project")
      (expect (string= "github" host))
      (expect (string= "owner" name)))
    (multiple-value-bind (host name)
        (nerimux/vcs::%organization-and-name "project")
      (expect (string= "local" host))
      (expect (string= "default" name))))

  (it "handles directory boundaries and ghq-root specifications"
    (expect (nerimux/vcs::%directory-under-p "/work/ghq" "/work/ghq/owner/project"))
    (expect (nerimux/vcs::%directory-under-p "/work/ghq/" "/work/ghq/owner/project"))
    (expect (not (nerimux/vcs::%directory-under-p "/work/ghq" "/work/ghq-other/project")))
    (expect (not (nerimux/vcs::%directory-under-p "" "/work/ghq/project")))
    (with-stubbed-fdefinition
        ((nerimux/vcs:ghq-root-directory
           (lambda () "/work/ghq")))
      (expect (string= "owner/project"
                       (nerimux/vcs::%directory-specification
                        "/work/ghq/owner/project")))
      (expect (string= "local"
                       (nerimux/vcs::%directory-specification
                        "/tmp/owner/project")))))

  (it "returns no ghq root when the provider lookup fails"
    (let ((nerimux/vcs::*ghq-root-cache* :unresolved))
      (with-stubbed-fdefinition
          ((vcs-kit:ghq-root
             (lambda () (error "ghq root unavailable"))))
        (expect (null (nerimux/vcs:ghq-root-directory)))))))

(describe "vcs bare repository worktrees"

  (it "drops the bare entry and leaves a bare repository with no primary worktree"
    (let ((repository (nerimux/workspace-model:make-repository
                       :specification "workspace-owner/bare"
                       :local-path "/tmp/nerimux-bare.git/")))
      (nerimux/vcs::%apply-repository-worktrees
       repository
       (list (%vcs-operations-fake-worktree "/tmp/nerimux-bare.git" :bare-p t)
             (%vcs-operations-fake-worktree "/tmp/nerimux-bare.git/.worktrees/feat"
                                            :branch "feature/x"))
       nil)
      (expect (equal '("/tmp/nerimux-bare.git/.worktrees/feat")
                     (mapcar #'nerimux/workspace-model:worktree-path
                             (nerimux/workspace-model:repository-worktrees repository))))
      (expect (null (nerimux/workspace-model:repository-main-worktree repository)))))

  (it "keeps a checkout's own worktree as its primary"
    (let ((repository (nerimux/workspace-model:make-repository
                       :specification "workspace-owner/checkout"
                       :local-path "/tmp/nerimux-checkout/")))
      (nerimux/vcs::%apply-repository-worktrees
       repository
       (list (%vcs-operations-fake-worktree "/tmp/nerimux-checkout" :branch "main"))
       nil)
      (expect (string= "/tmp/nerimux-checkout"
                       (nerimux/workspace-model:worktree-path
                        (nerimux/workspace-model:repository-main-worktree repository)))))))

(describe "vcs unreadable checkout"

  (it "keeps the worktrees a checkout had when git can no longer read it"
    (let ((repository (nerimux/workspace-model:make-repository
                       :specification "workspace-owner/broken"
                       :local-path "/tmp/nerimux-broken/")))
      (nerimux/vcs::%apply-repository-worktrees
       repository
       (list (%vcs-operations-fake-worktree "/tmp/nerimux-broken" :branch "main"))
       nil)
      (let ((worktree (first (nerimux/workspace-model:repository-worktrees repository))))
        (nerimux/vcs::%apply-repository-worktrees repository nil t)
        (expect (eq worktree
                    (first (nerimux/workspace-model:repository-worktrees repository))))
        (expect (nerimux/workspace-model:worktree-missing-p worktree))
        (expect (nerimux/workspace-model:repository-missing-p repository)))))

  (it "carries an unreadable repository's worktrees across a full rescan"
    (let* ((previous-organization
             (nerimux/workspace-model:make-organization :id "unreadable-org"))
           (previous-repository
             (nerimux/workspace-model:make-repository
              :id "unreadable-repo"
              :organization previous-organization
              :local-path "/tmp/nerimux-rescan/"))
           (worktree (nerimux/workspace-model:make-worktree
                      :id "kept" :repository previous-repository
                      :path "/tmp/nerimux-rescan"))
           (current-organization
             (nerimux/workspace-model:make-organization :id "unreadable-org"))
           (current-repository
             (nerimux/workspace-model:make-repository
              :id "unreadable-repo"
              :organization current-organization
              :local-path "/tmp/nerimux-rescan/")))
      (nerimux/workspace-model:organization-add-repository previous-organization
                                                           previous-repository)
      (nerimux/workspace-model:repository-add-worktree previous-repository worktree)
      (nerimux/workspace-model:organization-add-repository current-organization
                                                           current-repository)
      (setf (nerimux/workspace-model:repository-missing-p current-repository) t)
      (nerimux/vcs::%preserve-unreadable-repository-worktrees
       (list previous-organization) (list current-organization))
      (expect (equal (list worktree)
                     (nerimux/workspace-model:repository-worktrees current-repository)))
      (expect (nerimux/workspace-model:worktree-missing-p worktree))
      (expect (eq current-repository
                  (nerimux/workspace-model:worktree-repository worktree)))))

  (it "leaves a readable repository's rebuilt worktree list alone"
    (let* ((previous-organization
             (nerimux/workspace-model:make-organization :id "readable-org"))
           (previous-repository
             (nerimux/workspace-model:make-repository
              :id "readable-repo"
              :organization previous-organization
              :local-path "/tmp/nerimux-readable/"))
           (stale (nerimux/workspace-model:make-worktree
                   :id "stale" :repository previous-repository
                   :path "/tmp/nerimux-readable-gone"))
           (current-organization
             (nerimux/workspace-model:make-organization :id "readable-org"))
           (current-repository
             (nerimux/workspace-model:make-repository
              :id "readable-repo"
              :organization current-organization
              :local-path "/tmp/nerimux-readable/")))
      (nerimux/workspace-model:organization-add-repository previous-organization
                                                           previous-repository)
      (nerimux/workspace-model:repository-add-worktree previous-repository stale)
      (nerimux/workspace-model:organization-add-repository current-organization
                                                           current-repository)
      (nerimux/vcs::%preserve-unreadable-repository-worktrees
       (list previous-organization) (list current-organization))
      (expect (null (nerimux/workspace-model:repository-worktrees
                     current-repository)))
      (expect (null (nerimux/workspace-model:worktree-missing-p stale))))))
