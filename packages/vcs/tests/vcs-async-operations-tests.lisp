(in-package #:nerimux/test/vcs)

(describe "workspace-job worker notifications"
  (it "workspace-job preflight dispatches start before completion from its worker"
    (let ((queued nil) (events nil) (worker nil)
          (caller (cl-concurrent-kit:current-thread))
          (snapshot (nerimux/vcs::make-worktree-prune-snapshot)))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%read-worktree-prune-snapshot
             (lambda (worktree)
               (declare (ignore worktree))
               (setf worker (cl-concurrent-kit:current-thread))
               snapshot)))
        (cl-concurrent-kit:join-thread
         (nerimux/vcs:read-worktree-prune-snapshot-async
          nil :callback-dispatch (lambda (callback) (push callback queued))
          :on-start (lambda () (push :running events))
          :on-complete (lambda (value)
                         (expect (eq snapshot value))
                         (push :succeeded events))) :timeout 2)
        (expect (not (eq caller worker)))
        (expect (null events))
        (expect (= 2 (length queued)))
        (mapc #'funcall (reverse queued))
        (expect (equal '(:succeeded :running) events))))))

(defun %write-prune-fixture-file (path content)
  (with-open-file (stream path :direction :output :if-exists :overwrite
                               :if-does-not-exist :create)
    (write-string content stream)))

(defun %call-with-prune-git-fixture (function)
  (let* ((root (merge-pathnames (format nil ".prune-test-~D-~D/"
                                       (get-universal-time) (random 1000000000))
                                (uiop:getcwd)))
         (primary (merge-pathnames "primary/" root))
         (child (merge-pathnames "child/" root)))
    (ensure-directories-exist primary)
    (unwind-protect
         (flet ((git (&rest arguments)
                  (uiop:run-program (append (list "git" "-C" (namestring primary)) arguments)
                                    :output :string :error-output :string)))
           (git "init")
           (%write-prune-fixture-file (merge-pathnames "tracked" primary) "initial")
           (%write-prune-fixture-file (merge-pathnames ".gitignore" primary) "ignored")
           (git "add" "tracked" ".gitignore")
           (git "-c" "user.name=Fixture" "-c" "user.email=fixture@example.invalid"
                "-c" "commit.gpgsign=false" "commit" "-m" "fixture")
           (git "worktree" "add" "-b" "prune-child" (namestring child))
           (let* ((repository (nerimux/workspace-model:make-repository
                               :id "prune-fixture" :local-path (namestring (truename primary))))
                  (worktree (nerimux/workspace-model:make-worktree
                             :id "prune-child" :repository repository
                             :path (namestring (truename child)) :completed-p t)))
             (funcall function worktree (truename child))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(describe "workspace-prune-snapshot"
  (it "real Git clean control and same-path tracked untracked and staged changes invalidate consent"
    (%call-with-prune-git-fixture
     (lambda (worktree root)
       (let ((clean (nerimux/vcs::%read-worktree-prune-snapshot worktree)))
         (expect (null (nerimux/vcs:worktree-prune-snapshot-changed-files clean)))
         (expect (nerimux/vcs:validate-worktree-prune-snapshot worktree clean))
         (%write-prune-fixture-file (merge-pathnames "tracked" root) "dirty one")
         (expect (signals error (nerimux/vcs:validate-worktree-prune-snapshot worktree clean))))
       (let ((dirty (nerimux/vcs::%read-worktree-prune-snapshot worktree)))
         (expect (nerimux/vcs:worktree-prune-snapshot-changed-files dirty))
         (expect (nerimux/vcs:validate-worktree-prune-snapshot worktree dirty))
         (%write-prune-fixture-file (merge-pathnames "tracked" root) "dirty two")
         (expect (signals error (nerimux/vcs:validate-worktree-prune-snapshot worktree dirty))))
       (%write-prune-fixture-file (merge-pathnames "untracked" root) "first")
       (let ((untracked (nerimux/vcs::%read-worktree-prune-snapshot worktree)))
         (expect (nerimux/vcs:validate-worktree-prune-snapshot worktree untracked))
         (%write-prune-fixture-file (merge-pathnames "untracked" root) "other")
         (expect (signals error (nerimux/vcs:validate-worktree-prune-snapshot worktree untracked))))
       (let ((unstaged (nerimux/vcs::%read-worktree-prune-snapshot worktree)))
         (uiop:run-program (list "git" "-C" (namestring root) "add" "tracked") :output :string)
         (expect (signals error (nerimux/vcs:validate-worktree-prune-snapshot worktree unstaged)))))))
  (it "real Git symbolic HEAD at identical commit invalidates consent"
    (%call-with-prune-git-fixture
     (lambda (worktree root)
       (let ((snapshot (nerimux/vcs::%read-worktree-prune-snapshot worktree)))
         (expect (nerimux/vcs:validate-worktree-prune-snapshot worktree snapshot))
         (uiop:run-program (list "git" "-C" (namestring root) "checkout" "--detach" "HEAD")
                           :output :string :error-output :string)
         (expect (signals error (nerimux/vcs:validate-worktree-prune-snapshot worktree snapshot)))))))
  (it "real Git ignored content and dangling symlinks are refused without deletion"
    (%call-with-prune-git-fixture
     (lambda (worktree root)
       (expect (nerimux/vcs::%read-worktree-prune-snapshot worktree))
       (%write-prune-fixture-file (merge-pathnames "ignored" root) "must survive")
       (expect (signals error (nerimux/vcs::%read-worktree-prune-snapshot worktree)))
       (expect (probe-file (merge-pathnames "ignored" root)))
       (delete-file (merge-pathnames "ignored" root))
       (sb-posix:symlink "absent-target" (namestring (merge-pathnames "dangling" root)))
       (expect (signals error (nerimux/vcs::%read-worktree-prune-snapshot worktree)))
       (expect (sb-posix:lstat (namestring (merge-pathnames "dangling" root)))))))
  (it "preflight runs on a worker and applies only through the queued callback"
    (let ((queued nil) (seen nil) (worker nil) (caller (cl-concurrent-kit:current-thread))
          (snapshot (nerimux/vcs::make-worktree-prune-snapshot)))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%read-worktree-prune-snapshot
             (lambda (worktree) (declare (ignore worktree))
               (setf worker (cl-concurrent-kit:current-thread)) snapshot)))
        (let ((thread (nerimux/vcs:read-worktree-prune-snapshot-async
                       nil :callback-dispatch (lambda (callback) (push callback queued))
                       :on-complete (lambda (value) (push value seen)))))
          (cl-concurrent-kit:join-thread thread :timeout 2)
          (expect (not (eq caller worker)))
          (expect (= 1 (length queued)))
          (expect (null seen))
          (funcall (first queued))
          (expect (equal (list snapshot) seen)))))))

(describe "workspace-prune-refresh-generation"
  (it "reverse delete callbacks cannot overwrite the newer repository refresh"
    (let* ((repository (nerimux/workspace-model:make-repository :id "prune-generation"))
           (worktree (nerimux/workspace-model:make-worktree
                      :id "prune-generation-target" :path "/prune-generation/target"
                      :repository repository))
           (queued nil) (seen nil) (reads 0)
           (old-path "/prune-generation/old")
           (new-path "/prune-generation/new"))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%delete-worktree-command
             (lambda (&rest arguments) (declare (ignore arguments)) repository))
           (nerimux/vcs::%read-repository-refresh
             (lambda (received)
               (expect (eq repository received))
               (let ((path (if (= 1 (incf reads)) old-path new-path)))
                 (nerimux/vcs::%make-repository-refresh
                  :raw-worktrees (list (vcs-kit::%make-vcs-worktree :path path))
                  :status-updates (list (nerimux/vcs::%make-worktree-status-update
                                        :path path :ahead 0 :behind 0)))))))
        (dotimes (index 2)
          (declare (ignore index))
          (cl-concurrent-kit:join-thread
           (nerimux/vcs:delete-worktree-async
            worktree :callback-dispatch (lambda (callback) (push callback queued))
            :on-result (lambda (receipt) (push receipt seen))) :timeout 2))
        (expect (= 2 (length queued)))
        (funcall (first queued))
        (expect (string= new-path (nerimux/workspace-model:worktree-path
                                  (first (nerimux/workspace-model:repository-worktrees repository)))))
        (funcall (second queued))
        (expect (= 2 (length seen)))
        (expect (every #'nerimux/vcs:worktree-delete-result-removed-p seen))
        (expect (nerimux/vcs:worktree-delete-result-refresh-error (first seen)))
        (expect (null (nerimux/vcs:worktree-delete-result-refresh-error (second seen))))
        (expect (string= new-path (nerimux/workspace-model:worktree-path
                                  (first (nerimux/workspace-model:repository-worktrees repository))))))))
  (it "catalog replacement invalidates a captured operation without mutating the repository"
    (let* ((repository (nerimux/workspace-model:make-repository :id "prune-catalog"))
           (nerimux/vcs::*workspace-organizations* nil)
           (snapshot nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%read-repository-refresh
             (lambda (received)
               (expect (eq received repository))
               (nerimux/vcs::%make-repository-refresh))))
        (setf snapshot (nerimux/vcs::%capture-worktree-operation-result repository t)))
      (setf nerimux/vcs::*workspace-organizations*
            (list (nerimux/workspace-model:make-organization :id "replacement")))
      (expect (signals error (nerimux/vcs::%apply-worktree-operation-result snapshot)))
      (expect (null (nerimux/workspace-model:repository-worktrees repository))))))

(defun %exercise-cross-operation-generation (mode)
  (let* ((repository (nerimux/workspace-model:make-repository
                      :id (symbol-name mode) :local-path "/cross-operation"))
         (a-path "/cross-operation/a")
         (b-path "/cross-operation/b")
         (c-path "/cross-operation/c")
         (a (nerimux/workspace-model:make-worktree
             :id a-path :path a-path :repository repository :head "initial"))
         (b (nerimux/workspace-model:make-worktree
             :id b-path :path b-path :repository repository :head "initial"))
         (status-first-p (not (member mode '(:status-after-delete :status-during-delete))))
         (entered (sb-thread:make-semaphore :count 0))
         (resume (sb-thread:make-semaphore :count 0))
         (caller (cl-concurrent-kit:current-thread))
         (io-workers nil) (status-reads 0) (refresh-reads 0) (commands 0)
         (blocked-p nil) (threads nil) (old-queue nil) (new-queue nil)
         (status-observed 0) (status-completed 0) (created nil)
         (errors nil) (receipts nil))
    (setf (nerimux/workspace-model:repository-worktrees repository) (list a b))
    (labels ((read-update (path head)
               (nerimux/vcs::%make-worktree-status-update
                :path path :head head :dirty-p (string= head "fresh")
                :ahead 0 :behind 0))
             (record-io ()
               (push (cl-concurrent-kit:current-thread) io-workers))
             (block-first-read ()
               (unless blocked-p
                 (setf blocked-p t)
                 (sb-thread:signal-semaphore entered)
                 (unless (sb-thread:wait-on-semaphore resume :timeout 2)
                   (error "Cross-operation worker was not released"))))
             (start-status (dispatcher)
               (let ((started
                       (nerimux/vcs:refresh-repositories-async
                        (list repository) :callback-dispatch dispatcher
                        :on-repository (lambda (received)
                                         (expect (eq repository received))
                                         (incf status-observed))
                        :on-complete (lambda (received)
                                       (expect (equal (list repository) received))
                                       (incf status-completed))
                        :on-error (lambda (received condition)
                                    (expect (eq repository received))
                                    (push condition errors)))))
                 (setf threads (append started threads))
                 (first started)))
             (start-operation (dispatcher)
               (let ((thread
                       (if (eq mode :create-after-status)
                           (nerimux/vcs:create-worktree-async
                            repository :branch "new" :path c-path
                            :callback-dispatch dispatcher
                            :on-complete (lambda (worktree) (push worktree created))
                            :on-error (lambda (condition) (push condition errors)))
                           (nerimux/vcs:delete-worktree-async
                            b :callback-dispatch dispatcher
                            :on-result (lambda (receipt) (push receipt receipts))))))
                 (push thread threads)
                 thread)))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%read-worktree-status
             (lambda (worktree)
               (record-io)
               (incf status-reads)
               (let ((update (read-update
                              (nerimux/workspace-model:worktree-path worktree)
                              (if status-first-p "stale" "fresh"))))
                 (when status-first-p (block-first-read))
                 update)))
           (nerimux/vcs::%read-repository-worktrees
             (lambda (received)
               (unless (eq received repository) (error "Unexpected repository"))
               (record-io)
               (incf refresh-reads)
               (let ((raw (mapcar
                           (lambda (path)
                             (vcs-kit::%make-vcs-worktree
                              :path path :head (if status-first-p "fresh" "stale")))
                           (if (eq mode :create-after-status)
                               (list a-path b-path c-path)
                               (list a-path)))))
                 (unless status-first-p (block-first-read))
                 (values raw nil))))
           (nerimux/vcs::%read-worktree-status-at
             (lambda (path head root)
               (declare (ignore head root))
               (record-io)
               (read-update path (if status-first-p "fresh" "stale"))))
           (nerimux/vcs::%path-missing-p
             (lambda (path) (declare (ignore path)) nil))
           (nerimux/vcs::%create-worktree-command
             (lambda (received branch path start-point force)
               (declare (ignore branch start-point force))
               (unless (eq received repository) (error "Unexpected repository"))
               (record-io)
               (incf commands)
               path))
           (nerimux/vcs::%delete-worktree-command
             (lambda (worktree force)
               (declare (ignore force))
               (unless (eq worktree b) (error "Unexpected deletion target"))
               (record-io)
               (incf commands)
               (when (eq mode :status-during-delete) (block-first-read))
               repository)))
        (unwind-protect
             (let* ((old-dispatch (lambda (callback) (push callback old-queue)))
                    (new-dispatch (lambda (callback) (push callback new-queue))))
               (if status-first-p
                   (start-status old-dispatch)
                   (start-operation old-dispatch))
               (expect (sb-thread:wait-on-semaphore entered :timeout 2))
               (expect (null old-queue))
               (when (eq mode :status-during-delete)
                 (start-status new-dispatch)
                 (cl-concurrent-kit:join-thread (first threads) :timeout 2))
               (sb-thread:signal-semaphore resume)
               (cl-concurrent-kit:join-thread (if (eq mode :status-during-delete)
                                                (second threads) (first threads)) :timeout 2)
               (expect (= 1 (length old-queue)))
               (unless (eq mode :status-during-delete)
                 (if status-first-p
                     (start-operation new-dispatch)
                     (start-status new-dispatch)))
               (cl-concurrent-kit:join-thread (first threads) :timeout 2)
               (expect (= 1 (length new-queue)))
               (expect (= 2 status-reads))
               (expect (= 1 refresh-reads))
               (expect (= 1 commands))
               (expect (every (lambda (worker) (not (eq worker caller))) io-workers))
               (funcall (first new-queue))
               (let ((fresh-a (first (nerimux/workspace-model:repository-worktrees repository))))
                 (expect (string= "fresh" (nerimux/workspace-model:worktree-head fresh-a)))
                 (expect (nerimux/workspace-model:worktree-dirty-p fresh-a))
                 (funcall (first old-queue))
                 (expect (= 1 status-completed))
                 (expect (null errors))
                 (expect (= (if status-first-p 0 1) status-observed))
                 (expect (eq fresh-a (first (nerimux/workspace-model:repository-worktrees repository))))
                 (expect (string= "fresh" (nerimux/workspace-model:worktree-head fresh-a)))
                 (expect (nerimux/workspace-model:worktree-dirty-p fresh-a)))
               (if (eq mode :create-after-status)
                   (progn
                     (expect (= 1 (length created)))
                     (expect (string= c-path (nerimux/workspace-model:worktree-path (first created)))))
                   (progn
                     (expect (= 1 (length receipts)))
                     (expect (nerimux/vcs:worktree-delete-result-removed-p (first receipts)))
                     (expect (null (nerimux/vcs:worktree-delete-result-error (first receipts))))
                     (if status-first-p
                         (progn
                           (expect (null (nerimux/vcs:worktree-delete-result-refresh-error (first receipts))))
                           (expect (= 1 (length (nerimux/workspace-model:repository-worktrees repository)))))
                         (expect (nerimux/vcs:worktree-delete-result-refresh-error (first receipts)))))))
          (sb-thread:signal-semaphore resume)
          (dolist (thread threads)
            (cl-concurrent-kit:join-thread thread :timeout 2)))))))

(describe "workspace-job-cross-operation-generation"
  (it "workspace-job-cross-operation-generation create excludes an older status snapshot"
    (%exercise-cross-operation-generation :create-after-status))
  (it "workspace-job-cross-operation-generation delete excludes an older status without partial application"
    (%exercise-cross-operation-generation :delete-after-status))
  (it "workspace-job-cross-operation-generation newer status excludes an older delete refresh but retains removal receipt"
    (%exercise-cross-operation-generation :status-after-delete))
  (it "workspace-job-cross-operation-generation status registered during Git excludes its later refresh and retains removal receipt"
    (%exercise-cross-operation-generation :status-during-delete)))

(describe "worktree-delete-receipt"
  (it "distinguishes guard remove capture apply and success with single settlement"
    (dolist (stage '(:guard :remove :capture :apply :success))
      (let ((queued nil) (seen nil) (removed 0) (applied 0) (legacy 0)
            (fixture (nerimux/vcs::%make-worktree-operation-result :value t)))
        (with-stubbed-fdefinition
            ((nerimux/vcs::%delete-worktree-command
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (when (eq stage :remove) (error "remove failed"))
                 (incf removed)
                 :repository))
             (nerimux/vcs::%capture-worktree-operation-result
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (when (eq stage :capture) (error "capture failed"))
                 fixture))
             (nerimux/vcs::%apply-worktree-operation-result
               (lambda (snapshot)
                 (expect (eq fixture snapshot))
                 (incf applied)
                 (when (eq stage :apply) (error "apply failed"))
                 t)))
          (let ((thread
                  (nerimux/vcs:delete-worktree-async
                   nil :before-delete (lambda () (when (eq stage :guard) (error "guard failed")))
                   :callback-dispatch (lambda (callback) (push callback queued))
                   :on-result (lambda (receipt) (push receipt seen))
                   :on-complete (lambda (value) (declare (ignore value)) (incf legacy))
                   :on-error (lambda (value) (declare (ignore value)) (incf legacy)))))
            (cl-concurrent-kit:join-thread thread :timeout 2)
            (expect (= 1 (length queued)))
            (expect (null seen))
            (expect (= 0 applied))
            (funcall (first queued))
            (funcall (first queued))
            (expect (= 1 (length seen)))
            (expect (= 0 legacy))
            (expect (= (if (member stage '(:guard :remove)) 0 1) removed))
            (expect (= (if (member stage '(:apply :success)) 1 0) applied))
            (let ((receipt (first seen)))
              (expect (eq (not (null (member stage '(:capture :apply :success))))
                          (nerimux/vcs:worktree-delete-result-removed-p receipt)))
              (expect (eq (not (null (member stage '(:guard :remove))))
                          (not (null (nerimux/vcs:worktree-delete-result-error receipt)))))
              (expect (eq (not (null (member stage '(:capture :apply))))
                          (not (null (nerimux/vcs:worktree-delete-result-refresh-error receipt)))))))))))

  (it "preserves legacy observer errors without resettling result observers"
    (dolist (receipt-mode '(nil t))
      (let ((queued nil) (observed 0) (errors 0) (receipt nil)
            (fixture (nerimux/vcs::%make-worktree-operation-result :value t)))
        (with-stubbed-fdefinition
            ((nerimux/vcs::%delete-worktree-command
               (lambda (&rest args) (declare (ignore args)) :repository))
             (nerimux/vcs::%capture-worktree-operation-result
               (lambda (&rest args) (declare (ignore args)) fixture))
             (nerimux/vcs::%apply-worktree-operation-result
               (lambda (snapshot) (expect (eq fixture snapshot)) t)))
          (let ((thread
                  (nerimux/vcs:delete-worktree-async
                   nil :callback-dispatch (lambda (callback) (push callback queued))
                   :on-result (when receipt-mode
                                (lambda (value)
                                  (setf receipt value)
                                  (incf observed)
                                  (error "result observer failed")))
                   :on-complete (lambda (value)
                                  (expect (eq t value))
                                  (incf observed)
                                  (error "legacy observer failed"))
                   :on-error (lambda (condition)
                               (expect (typep condition 'error))
                               (incf errors)))))
            (cl-concurrent-kit:join-thread thread :timeout 2)
            (expect (= 1 (length queued)))
            (let ((signaled nil))
              (handler-case (funcall (first queued))
                (error () (setf signaled t)))
              (expect (eq receipt-mode signaled)))
            (funcall (first queued))
            (expect (= 1 observed))
            (expect (= (if receipt-mode 0 1) errors))
            (when receipt-mode
              (expect (nerimux/vcs:worktree-delete-result-removed-p receipt))
              (expect (null (nerimux/vcs:worktree-delete-result-error receipt)))
              (expect (null (nerimux/vcs:worktree-delete-result-refresh-error receipt))))))))))

(defun %queued-repository-status-refresh (repository &rest options)
  (let ((queued nil))
    (let ((threads
            (apply #'nerimux/vcs:refresh-repositories-async
                   (list repository)
                   :callback-dispatch (lambda (callback) (push callback queued))
                   options)))
      (expect (= 1 (length threads)))
      (dolist (thread threads)
        (sb-thread:join-thread thread :timeout 2)))
    (expect (= 1 (length queued)))
    (first queued)))

(describe "vcs overlapping repository status refresh"
  (it "rejects an older delivery while the newest result is still queued"
    (let ((repository
            (nerimux/workspace-model:make-repository
             :specification "workspace-owner/project"))
          (applied nil)
          (completed nil))
      (labels ((queue-refresh (tag)
                 (%queued-repository-status-refresh
                  repository
                  :status-reader (lambda (current)
                                   (declare (ignore current))
                                   tag)
                  :status-applier (lambda (current update)
                                    (declare (ignore current))
                                    (push update applied))
                  :on-complete (lambda (repositories)
                                 (declare (ignore repositories))
                                 (push tag completed)))))
        (let* ((old (queue-refresh :old))
               (new (queue-refresh :new)))
          (funcall old)
          (expect (null applied))
          (expect (equal '(:old) completed))
          (funcall new)
          (expect (equal '(:new) applied))
          (expect (equal '(:new :old) completed))
          (expect (null (gethash repository
                                 nerimux/vcs::*repository-status-generations*)))))))

  (it "allows an observer to enqueue the next refresh before completing"
    (let ((repository
            (nerimux/workspace-model:make-repository
             :specification "workspace-owner/project"))
          (next nil)
          (applied nil)
          (completed nil))
      (labels ((queue-refresh (tag &optional observer)
                 (%queued-repository-status-refresh
                  repository
                  :status-reader (lambda (current)
                                   (declare (ignore current))
                                   tag)
                  :status-applier (lambda (current update)
                                    (declare (ignore current))
                                    (push update applied))
                  :on-repository observer
                  :on-complete (lambda (repositories)
                                 (declare (ignore repositories))
                                 (push tag completed)))))
        (let ((first
                (queue-refresh :first
                               (lambda (current)
                                 (expect (eq repository current))
                                 (setf next (queue-refresh :next))))))
          (funcall first)
          (expect next)
          (expect (equal '(:first) completed))
          (funcall next)
          (expect (equal '(:next :first) applied))
          (expect (equal '(:next :first) completed))))))

  (it "allows a status applier to enqueue a newer generation recursively"
    (let ((repository
            (nerimux/workspace-model:make-repository
             :specification "workspace-owner/project"))
          (next nil)
          (notified nil)
          (completed nil))
      (labels ((queue-refresh (tag)
                 (%queued-repository-status-refresh
                  repository
                  :status-reader (lambda (current)
                                   (declare (ignore current))
                                   tag)
                  :status-applier
                  (lambda (current update)
                    (setf (nerimux/workspace-model:repository-dirty-p current)
                          (eq update :next))
                    (when (eq update :first)
                      (setf next (queue-refresh :next))))
                  :on-repository (lambda (current)
                                   (declare (ignore current))
                                   (push tag notified))
                  :on-complete (lambda (repositories)
                                 (declare (ignore repositories))
                                 (push tag completed)))))
        (funcall (queue-refresh :first))
        (expect next)
        (expect (null notified))
        (expect (equal '(:first) completed))
        (funcall next)
        (expect (nerimux/workspace-model:repository-dirty-p repository))
        (expect (equal '(:next) notified))
        (expect (equal '(:next :first) completed)))))

  (it "discards stale success without reverting state or notifying observers"
    (let ((repository
            (nerimux/workspace-model:make-repository
             :specification "workspace-owner/project"))
          (applied nil)
          (notified nil)
          (completed nil))
      (labels ((queue-refresh (tag dirty-p)
                 (%queued-repository-status-refresh
                  repository
                  :status-reader (lambda (current)
                                   (declare (ignore current))
                                   dirty-p)
                  :status-applier
                  (lambda (current update)
                    (push tag applied)
                    (setf (nerimux/workspace-model:repository-dirty-p current)
                          update))
                  :on-repository (lambda (current)
                                   (push (list tag current) notified))
                  :on-complete (lambda (repositories)
                                 (push (list tag repositories) completed)))))
        (let* ((old (queue-refresh :old nil))
               (new (queue-refresh :new t)))
          (expect (null applied))
          (expect (null notified))
          (expect (null completed))
          (funcall new)
          (expect (nerimux/workspace-model:repository-dirty-p repository))
          (funcall old)
          (expect (equal (list (list :old (list repository))
                               (list :new (list repository)))
                         completed))
          (expect (nerimux/workspace-model:repository-dirty-p repository))
          (expect (equal '(:new) applied))
          (expect (equal (list (list :new repository)) notified))))))

  (it "preserves stale operation errors and settles each request exactly once"
    (let ((repository
            (nerimux/workspace-model:make-repository
             :specification "workspace-owner/project"))
          (errors nil)
          (completed nil)
          (applied nil))
      (labels ((queue-refresh (tag fail-p)
                 (%queued-repository-status-refresh
                  repository
                  :status-reader (lambda (current)
                                   (declare (ignore current))
                                   (when fail-p (error "stale status failure"))
                                   t)
                  :status-applier
                  (lambda (current update)
                    (push tag applied)
                    (setf (nerimux/workspace-model:repository-dirty-p current)
                          update))
                  :on-error (lambda (current condition)
                              (push (list current condition) errors))
                  :on-complete (lambda (repositories)
                                 (push (list tag repositories) completed)))))
        (let* ((old (queue-refresh :old t))
               (new (queue-refresh :new nil)))
          (expect (null completed))
          (expect (null errors))
          (funcall new)
          (funcall old)
          (expect (equal (list (list :old (list repository))
                               (list :new (list repository)))
                         completed))
          (expect (nerimux/workspace-model:repository-dirty-p repository))
          (expect (equal '(:new) applied))
          (expect (= 1 (length errors)))
          (expect (eq repository (first (first errors))))
          (expect (typep (second (first errors)) 'error))))))

  (it "does not invalidate a pending refresh for a different repository"
    (let ((first-repository
            (nerimux/workspace-model:make-repository
             :specification "workspace-owner/first"))
          (second-repository
            (nerimux/workspace-model:make-repository
             :specification "workspace-owner/second"))
          (notified nil)
          (completed nil))
      (labels ((queue-refresh (repository)
                 (%queued-repository-status-refresh
                  repository
                  :status-reader (lambda (current)
                                   (declare (ignore current))
                                   t)
                  :status-applier
                  (lambda (current update)
                    (setf (nerimux/workspace-model:repository-dirty-p current)
                          update))
                  :on-repository (lambda (current) (push current notified))
                  :on-complete (lambda (repositories)
                                 (push repositories completed)))))
        (let* ((first (queue-refresh first-repository))
               (second (queue-refresh second-repository)))
          (funcall second)
          (funcall first)
          (expect (nerimux/workspace-model:repository-dirty-p first-repository))
          (expect (nerimux/workspace-model:repository-dirty-p second-repository))
          (expect (equal (list first-repository second-repository) notified))
          (expect (equal (list (list first-repository) (list second-repository))
                         completed)))))))

(describe "vcs asynchronous operation callbacks"
  (it "completes an empty repository refresh synchronously"
    (let ((completed nil)
          (dispatched nil))
      (expect
       (null
        (nerimux/vcs:refresh-repositories-async
         nil
         :callback-dispatch
         (lambda (callback)
           (setf dispatched callback))
         :on-complete
         (lambda (repositories)
           (setf completed repositories)))))
      (expect (null completed))
      (expect dispatched)
      (funcall dispatched)
      (expect (null completed))))

  (it "applies a captured refresh without filesystem observation"
    (let* ((path (%vcs-operations-existing-path))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project"
              :local-path path))
           (raw
             (%vcs-operations-fake-worktree
              path :branch "feature/snapshot" :head "old-head"))
           (status
             (nerimux/vcs::%make-worktree-status-update
              :path path :head "new-head" :ahead 2 :behind 1))
           (refresh
             (nerimux/vcs::%make-repository-refresh
              :raw-worktrees (list raw)
              :missing-p nil
              :status-updates (list status))))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%path-missing-p
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "dispatcher attempted filesystem observation"))))
        (expect
         (eq repository
             (nerimux/vcs::%apply-repository-refresh repository refresh)))
        (let ((worktree
                (nerimux/workspace-model:repository-worktree-by-path repository path)))
          (expect (string= "new-head" (nerimux/workspace-model:worktree-head worktree)))
          (expect (= 2 (nerimux/workspace-model:worktree-ahead worktree)))
          (expect (= 1 (nerimux/workspace-model:worktree-behind worktree)))))))

  (it "applies operation results only through the callback dispatcher"
    (let ((queued nil)
          (refresh-count 0)
          (completed nil)
          (fixture (nerimux/vcs::%make-worktree-operation-result :value t)))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%delete-worktree-command
             (lambda (&rest arguments)
               (declare (ignore arguments))
               :repository))
           (nerimux/vcs::%capture-worktree-operation-result
             (lambda (repository result &optional generation)
               (declare (ignore repository result generation))
               fixture))
           (nerimux/vcs::%apply-worktree-operation-result
             (lambda (snapshot)
               (expect (eq fixture snapshot))
               (incf refresh-count)
               t)))
        (let ((thread
                (nerimux/vcs:delete-worktree-async
                 nil
                 :callback-dispatch (lambda (callback) (push callback queued))
                 :on-complete (lambda (result) (setf completed result)))))
          (cl-concurrent-kit:join-thread thread :timeout 2)
          (expect (= 0 refresh-count))
          (expect (null completed))
          (expect (= 1 (length queued)))
          (funcall (pop queued))
          (expect (= 1 refresh-count))
          (expect (eq t completed))))))

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
                   ((nerimux/vcs::%create-worktree-command
                      (lambda (&rest arguments)
                        (declare (ignore arguments))
                        :created))
                    (nerimux/vcs::%apply-created-worktree
                      (lambda (&rest arguments)
                        (declare (ignore arguments))
                        :created))
                    (nerimux/vcs::%delete-worktree-command
                      (lambda (&rest arguments)
                        (declare (ignore arguments))
                        :repository))
                    (nerimux/vcs::%lock-worktree-command
                      (lambda (&rest arguments)
                        (declare (ignore arguments))
                        :repository))
                 (nerimux/vcs::%unlock-worktree-command
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     :repository))
                 (nerimux/vcs::%prune-worktrees-command
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     '(:repository :pruned)))
                 (nerimux/vcs::%capture-worktree-operation-result
                   (lambda (repository result &optional generation)
                     (declare (ignore repository generation))
                     (nerimux/vcs::%make-worktree-operation-result :value result)))
                 (nerimux/vcs::%apply-worktree-operation-result
                   (lambda (result)
                     (nerimux/vcs::%worktree-operation-result-value result))))
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
                              (:delete t)
                              (:lock t)
                              (:unlock t)
                              (:prune :pruned)))
                     (expect (gethash expected observed)))))
               (with-stubbed-fdefinition
                   ((nerimux/vcs::%create-worktree-command
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
          (it "fetches and refreshes status"
              (let* ((repository
                      (nerimux/workspace-model:make-repository :specification
                                                               "workspace-owner/project"
                                                               :local-path
                                                               (%vcs-operations-existing-path)))
                     (fetch-call nil)
                     (refresh-call nil))
                (with-stubbed-fdefinition
                 ((nerimux/vcs::%bare-origin-fetch-p
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     nil))
                  (vcs-kit:make-vcs-repository
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
                 (expect
                  (eq repository (nerimux/vcs::fetch-repository repository)))
                 (expect (equal '(:fetch-backend nil) fetch-call))
                 (expect (eq repository refresh-call))
                 (let ((condition-seen nil))
                   (handler-case (nerimux/vcs::fetch-repository nil)
                     (error (condition)
                       (setf condition-seen condition)))
                   (expect (typep condition-seen 'error)))))))
