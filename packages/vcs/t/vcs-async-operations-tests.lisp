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
  (%call-with-isolated-test-git-environment
   (lambda ()
     (let* ((root
             (merge-pathnames
              (format nil ".prune-test-~D-~D/" (get-universal-time) (random 1000000000))
              (uiop:getcwd)))
            (primary (merge-pathnames "primary/" root))
            (child (merge-pathnames "child/" root)))
       (ensure-directories-exist primary)
       (unwind-protect
           (flet ((git (&rest arguments)
                    (apply #'%worktree-path-test-git (namestring primary) arguments)))
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
               (funcall function worktree (truename child)))
             (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))))

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
         (%worktree-path-test-git (namestring root) "add" "tracked")
         (expect (signals error (nerimux/vcs:validate-worktree-prune-snapshot worktree unstaged)))))))
  (it "real Git symbolic HEAD at identical commit invalidates consent"
    (%call-with-prune-git-fixture
     (lambda (worktree root)
       (let ((snapshot (nerimux/vcs::%read-worktree-prune-snapshot worktree)))
         (expect (nerimux/vcs:validate-worktree-prune-snapshot worktree snapshot))
         (%worktree-path-test-git (namestring root) "checkout" "--detach" "HEAD")
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
             (lambda (received branch path start-point force &optional generation)
               (declare (ignore branch start-point force))
               (unless (eq received repository) (error "Unexpected repository"))
               (record-io)
               (incf commands)
               (values path generation)))
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
            (apply (function nerimux/vcs:refresh-repositories-async)
                   (list repository)
                   :callback-dispatch (lambda (callback) (push callback queued))
                   options)))
      (expect (= 1 (length threads)))
      (loop for thread in threads
            for index from 1
            do (%join-test-worker
                thread
                (format nil
                        "repository status refresh worker ~D for ~A"
                        index
                        (nerimux/workspace-model:repository-local-path repository))))
      (expect (= 1 (length queued)))
      (first queued))))

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

(describe "vcs repository status worker pool"
  (it "bounds in-flight status reads and still settles every repository"
    (let* ((repositories
             (loop for index from 1 to 40
                   collect (nerimux/workspace-model:make-repository
                            :specification
                            (format nil "workspace-owner/project-~D" index)
                            :local-path (format nil "/tmp/project-~D" index))))
           (probe-lock (cl-concurrent-kit:make-lock :name "status probe"))
           (in-flight 0)
           (peak 0)
           (reads 0)
           (completed nil)
           (deadline (+ (get-internal-real-time)
                        (* 20 internal-time-units-per-second)))
           (threads
             (nerimux/vcs:refresh-repositories-async
              repositories
              :status-reader
              (lambda (repository)
                (declare (ignore repository))
                (cl-concurrent-kit:with-lock-held (probe-lock)
                  (incf reads)
                  (incf in-flight)
                  (setf peak (max peak in-flight)))
                (sleep 0.02)
                (cl-concurrent-kit:with-lock-held (probe-lock)
                  (decf in-flight))
                nil)
              :status-applier
              (lambda (repository update)
                (declare (ignore repository update))
                nil)
              :on-complete
              (lambda (refreshed)
                (declare (ignore refreshed))
                (setf completed t)))))
      (loop until completed
            while (< (get-internal-real-time) deadline)
            do (sleep 0.01))
      (dolist (thread threads)
        (cl-concurrent-kit:join-thread thread :timeout 10))
      (expect completed)
      (expect (= 8 (length threads)))
      (expect (= 40 reads))
      (expect (zerop in-flight))
      (expect (<= peak 8))
      (expect (> peak 1))))

  (it "uses one worker for one repository and keeps the batch in order"
    (let ((repository (nerimux/workspace-model:make-repository
                       :specification "workspace-owner/project"))
          (completed :not-called))
      (let ((threads
              (nerimux/vcs:refresh-repositories-async
               (list repository)
               :status-reader (lambda (current) (declare (ignore current)) nil)
               :status-applier (lambda (current update)
                                 (declare (ignore current update))
                                 nil)
               :on-complete (lambda (refreshed) (setf completed refreshed)))))
        (expect (= 1 (length threads)))
        (dolist (thread threads)
          (cl-concurrent-kit:join-thread thread :timeout 10)))
      (expect (equal (list repository) completed))))

  (it "settles the batch when a request signals before READ-ONE ever reaches FAIL-ONE"
    (let ((repository (nerimux/workspace-model:make-repository
                       :specification "workspace-owner/project"))
          (completed :not-called)
          (errors nil))
      (let ((threads
              (nerimux/vcs:refresh-repositories-async
               (list repository)
               ;; ON-START runs before the STATUS-READER handler-case exists,
               ;; so a condition here used to escape DRAIN's catch-all
               ;; uncaught by FAIL-ONE, leaving REMAINING stuck above zero.
               :on-start (lambda (current) (declare (ignore current))
                          (error "on-start failed"))
               :on-error (lambda (current condition)
                          (push (cons current condition) errors))
               :status-reader (lambda (current) (declare (ignore current)) nil)
               :status-applier (lambda (current update)
                                 (declare (ignore current update))
                                 nil)
               :on-complete (lambda (refreshed) (setf completed refreshed)))))
        (dolist (thread threads)
          (cl-concurrent-kit:join-thread thread :timeout 10)))
      (expect (equal (list repository) completed))
      (expect (= 1 (length errors)))
      (expect (eq repository (car (first errors))))
      (expect (typep (cdr (first errors)) 'error)))))
(describe "workspace fair worktree status queue"
    (it "fairly fills the global bound while preserving per-repository order and callbacks"
      (labels ((make-repository (repository-index)
                 (let ((repository
                         (nerimux/workspace-model:make-repository
                          :specification
                          (format nil "workspace-owner/status-queue-~D"
                                  repository-index)
                          :local-path
                          (format nil "/tmp/status-queue-~D" repository-index))))
                   (dotimes (worktree-index 8)
                     (nerimux/workspace-model:repository-add-worktree
                      repository
                      (nerimux/workspace-model:make-worktree
                       :repository repository
                       :path
                       (format nil "/tmp/status-queue-~D/worktree-~D"
                               repository-index worktree-index))))
                   repository)))
        (let* ((repositories
                 (loop for index from 1 to 16 collect (make-repository index)))
               (repository-index (make-hash-table :test #'eq))
               (organization
                 (nerimux/workspace-model:make-organization
                  :host "workspace-owner" :name "status-queue"
                  :repositories repositories))
               (probe-lock
                 (cl-concurrent-kit:make-lock :name "workspace status queue probe"))
               (release-readers (sb-thread:make-semaphore :count 0))
               (release-first (sb-thread:make-semaphore :count 0))
               (full-queue (sb-thread:make-semaphore :count 0))
               (queue-progress (sb-thread:make-semaphore :count 0))
               (shared-stashes (list :shared))
               (active-by-repository (make-array 16 :initial-element 0))
               (peak-by-repository (make-array 16 :initial-element 0))
               (reads 0) (in-flight 0) (peak 0) (stash-reads 0)
               (stash-uses 0) (start-count 0) (repository-count 0)
               (fast-completed 0)
               (applied-count 0) (completion-count 0)
               (completed-organizations nil) (order-errors nil) (errors nil)
               (threads nil))
          (loop for repository in repositories for index from 0
                do (setf (gethash repository repository-index) index))
          (with-stubbed-fdefinition
              ((nerimux/vcs::%repository-status-shared-stashes
                 (lambda (repository)
                   (cl-concurrent-kit:with-lock-held (probe-lock)
                     (incf stash-reads))
                   (if (eq repository (first repositories))
                       nil
                       shared-stashes)))
               (nerimux/vcs::%read-worktree-status
                 (lambda (worktree &key (stashes nil stashes-supplied-p))
                   (let* ((repository
                            (nerimux/workspace-model:worktree-repository worktree))
                          (index (gethash repository repository-index)))
                     (cl-concurrent-kit:with-lock-held (probe-lock)
                       (incf reads)
                       (incf in-flight)
                       (incf (aref active-by-repository index))
                       (setf peak (max peak in-flight)
                             (aref peak-by-repository index)
                             (max (aref peak-by-repository index)
                                  (aref active-by-repository index)))
                       (if (if (eq repository (first repositories))
                               (not stashes-supplied-p)
                               (and stashes-supplied-p
                                    (eq stashes shared-stashes)))
                           (incf stash-uses)
                           (decf stash-uses)))
                     (when (= in-flight 64)
                       (sb-thread:signal-semaphore full-queue))
                     (unwind-protect
                          (progn
                            (unless
                                (sb-thread:wait-on-semaphore
                                 (if (eq worktree
                                         (first
                                          (nerimux/workspace-model:repository-worktrees
                                           (first repositories))))
                                     release-first
                                     release-readers)
                                 :timeout 10)
                              (error "The queue test reader was not released"))
                            (nerimux/workspace-model:worktree-path worktree))
                       (cl-concurrent-kit:with-lock-held (probe-lock)
                         (decf in-flight)
                         (decf (aref active-by-repository index))
                         (unless
                             (eq worktree
                                 (first
                                  (nerimux/workspace-model:repository-worktrees
                                   (first repositories))))
                           (incf fast-completed)
                           (when (= fast-completed 127)
                             (sb-thread:signal-semaphore
                              queue-progress)))))))))
            (unwind-protect
                 (progn
                   (setf threads
                         (nerimux/vcs:refresh-workspace-status-async
                          :organizations (list organization)
                          :on-start
                          (lambda (repository)
                            (declare (ignore repository))
                            (cl-concurrent-kit:with-lock-held (probe-lock)
                              (incf start-count)))
                          :on-repository
                          (lambda (repository)
                            (declare (ignore repository))
                            (cl-concurrent-kit:with-lock-held (probe-lock)
                              (incf repository-count)))
                          :status-applier
                          (lambda (repository updates)
                            (let ((expected
                                    (loop for worktree in
                                            (nerimux/workspace-model:repository-worktrees
                                             repository)
                                          collect
                                            (nerimux/workspace-model:worktree-path
                                             worktree))))
                              (cl-concurrent-kit:with-lock-held (probe-lock)
                                (unless (equal expected updates)
                                  (push repository order-errors))
                                (when (= 15 (incf applied-count))
                                  (sb-thread:signal-semaphore queue-progress)))))
                          :on-error
                          (lambda (repository condition)
                            (declare (ignore repository))
                            (cl-concurrent-kit:with-lock-held (probe-lock)
                              (push condition errors)))
                          :on-complete
                          (lambda (completed)
                            (cl-concurrent-kit:with-lock-held (probe-lock)
                              (incf completion-count)
                              (setf completed-organizations completed)))))
                   (expect (sb-thread:wait-on-semaphore full-queue :timeout 10))
                   (cl-concurrent-kit:with-lock-held (probe-lock)
                     (expect (= 64 in-flight))
                     (expect (= 64 peak))
                     (expect (every (lambda (count) (= 4 count))
                                    (coerce active-by-repository 'list)))
                     (expect (every (lambda (count) (= 4 count))
                                    (coerce peak-by-repository 'list))))
                   (progn
                     (dotimes (index 128)
                       (declare (ignore index))
                       (sb-thread:signal-semaphore release-readers))
                     (expect
                      (sb-thread:wait-on-semaphore queue-progress :timeout 10))
                     (expect
                      (sb-thread:wait-on-semaphore queue-progress :timeout 10))
                     (cl-concurrent-kit:with-lock-held (probe-lock)
                       (expect (= 15 applied-count)))
                     (sb-thread:signal-semaphore release-first))
                   (dolist (thread threads)
                     (cl-concurrent-kit:join-thread thread :timeout 10))
                   (progn
                     (expect (= 68 (length threads)))
                     (setf threads nil)))
              (progn
               (dotimes (index 128)
                 (declare (ignore index))
                 (sb-thread:signal-semaphore release-readers))
               (sb-thread:signal-semaphore release-first))
              (dolist (thread threads)
                (cl-concurrent-kit:join-thread thread :timeout 10))))
          (expect (= 128 reads))
          (expect (zerop in-flight))
          (expect (= 16 stash-reads))
          (expect (= 128 stash-uses))
          (expect (= 16 start-count))
          (expect (= 16 repository-count))
          (expect (= 16 applied-count))
          (expect (null order-errors))
          (expect (null errors))
          (expect (= 1 completion-count))
          (expect
            (and (= 1 (length completed-organizations))
                 (eq organization
                     (first completed-organizations)))))))

    (it "joins active status reads before a repository error callback and skips partial apply"
      (let* ((repository
               (nerimux/workspace-model:make-repository
                :specification "workspace-owner/status-queue-error"
                :local-path "/tmp/status-queue-error"))
             (worktrees nil)
             (organization
               (nerimux/workspace-model:make-organization
                :host "workspace-owner" :name "status-queue-error"
                :repositories (list repository)))
             (probe-lock
               (cl-concurrent-kit:make-lock :name "workspace status queue error"))
             (siblings-started (sb-thread:make-semaphore :count 0))
             (failure-started (sb-thread:make-semaphore :count 0))
             (release-readers (sb-thread:make-semaphore :count 0))
             (error-reported (sb-thread:make-semaphore :count 0))
             (sibling-count 0) (in-flight 0) (reads 0)
             (in-flight-at-error nil) (applied 0)
             (errors nil) (completion-count 0) (threads nil))
        (dotimes (index 8)
          (nerimux/workspace-model:repository-add-worktree
           repository
           (nerimux/workspace-model:make-worktree
            :repository repository
            :path (format nil "/tmp/status-queue-error/worktree-~D" index))))
        (setf worktrees (nerimux/workspace-model:repository-worktrees repository))
        (let ((failed-worktree (first worktrees)))
          (with-stubbed-fdefinition
              ((nerimux/vcs::%repository-status-shared-stashes
                 (lambda (current)
                   (declare (ignore current))
                   (list :shared)))
               (nerimux/vcs::%read-worktree-status
                 (lambda (worktree &key stashes)
                   (declare (ignore stashes))
                   (cl-concurrent-kit:with-lock-held (probe-lock)
                     (incf reads)
                     (incf in-flight)
                     (unless (eq worktree failed-worktree)
                       (incf sibling-count)
                       (when (= sibling-count 3)
                         (sb-thread:signal-semaphore siblings-started))))
                   (unwind-protect
                        (if (eq worktree failed-worktree)
                            (progn
                              (unless (sb-thread:wait-on-semaphore
                                       siblings-started :timeout 5)
                                (error "Three sibling reads did not start"))
                              (sb-thread:signal-semaphore failure-started)
                              (error "Fixture status read failed"))
                            (progn
                              (unless (sb-thread:wait-on-semaphore
                                       release-readers :timeout 10)
                                (error "The queue error readers were not released"))
                              (nerimux/workspace-model:worktree-path worktree)))
                     (cl-concurrent-kit:with-lock-held (probe-lock)
                       (decf in-flight))))))
            (unwind-protect
                 (progn
                   (setf threads
                         (nerimux/vcs:refresh-workspace-status-async
                          :organizations (list organization)
                          :status-applier
                          (lambda (current updates)
                            (declare (ignore current updates))
                            (cl-concurrent-kit:with-lock-held (probe-lock)
                              (incf applied)))
                          :on-error
                          (lambda (current condition)
                            (cl-concurrent-kit:with-lock-held (probe-lock)
                              (push (list current condition) errors)
                              (setf in-flight-at-error in-flight))
                            (sb-thread:signal-semaphore error-reported))
                          :on-complete
                          (lambda (completed)
                            (declare (ignore completed))
                            (cl-concurrent-kit:with-lock-held (probe-lock)
                              (incf completion-count)))))
                   (expect (sb-thread:wait-on-semaphore failure-started :timeout 5))
                   (expect (null (sb-thread:wait-on-semaphore
                                  error-reported :timeout 0.05)))
                   (dotimes (index 3)
                     (declare (ignore index))
                     (sb-thread:signal-semaphore release-readers))
                   (expect (sb-thread:wait-on-semaphore error-reported :timeout 5))
                   (dolist (thread threads)
                     (cl-concurrent-kit:join-thread thread :timeout 10))
                   (setf threads nil))
              (dotimes (index 3)
                (declare (ignore index))
                (sb-thread:signal-semaphore release-readers))
              (dolist (thread threads)
                (cl-concurrent-kit:join-thread thread :timeout 10))))
          (expect (= 4 reads))
          (expect (zerop in-flight))
          (expect (zerop in-flight-at-error))
          (expect (zerop applied))
          (expect (= 1 (length errors)))
          (expect (eq repository (first (first errors))))
          (expect (typep (second (first errors)) 'error))
          (expect (= 1 completion-count)))))

    (it "waits for other repositories before completion after stash preparation fails"
      (let* ((failed-repository
               (nerimux/workspace-model:make-repository
                :specification "workspace-owner/status-preparation-error"
                :local-path "/tmp/status-preparation-error"))
             (ready-repository
               (nerimux/workspace-model:make-repository
                :specification "workspace-owner/status-preparation-ready"
                :local-path "/tmp/status-preparation-ready"))
             (organization
               (nerimux/workspace-model:make-organization
                :host "workspace-owner" :name "status-preparation"
                :repositories (list failed-repository ready-repository)))
             (reader-started (sb-thread:make-semaphore :count 0))
             (release-reader (sb-thread:make-semaphore :count 0))
             (error-reported (sb-thread:make-semaphore :count 0))
             (completed-event (sb-thread:make-semaphore :count 0))
             (errors nil) (applied 0) (completion-count 0) (threads nil))
        (dolist (repository (list failed-repository ready-repository))
          (nerimux/workspace-model:repository-add-worktree
           repository
           (nerimux/workspace-model:make-worktree
            :repository repository
            :path (format nil "/tmp/status-preparation-error/~D"
                          (if (eq repository failed-repository) 1 2)))))
        (with-stubbed-fdefinition
            ((nerimux/vcs::%repository-status-shared-stashes
               (lambda (repository)
                 (if (eq repository failed-repository)
                     (error "Fixture stash read failed")
                     (list :shared))))
             (nerimux/vcs::%read-worktree-status
               (lambda (worktree &key stashes)
                 (declare (ignore stashes))
                 (sb-thread:signal-semaphore reader-started)
                 (unless (sb-thread:wait-on-semaphore release-reader :timeout 10)
                   (error "The preparation test reader was not released"))
                 (nerimux/workspace-model:worktree-path worktree))))
          (unwind-protect
               (progn
                 (setf threads
                       (nerimux/vcs:refresh-workspace-status-async
                        :organizations (list organization)
                        :status-applier
                        (lambda (repository updates)
                          (declare (ignore repository updates))
                          (incf applied))
                        :on-error
                        (lambda (repository condition)
                          (push (list repository condition) errors)
                          (sb-thread:signal-semaphore error-reported))
                        :on-complete
                        (lambda (completed)
                          (declare (ignore completed))
                          (incf completion-count)
                          (sb-thread:signal-semaphore completed-event))))
                 (expect (sb-thread:wait-on-semaphore reader-started :timeout 5))
                 (expect (sb-thread:wait-on-semaphore error-reported :timeout 5))
                 (expect (null (sb-thread:wait-on-semaphore
                                completed-event :timeout 0.05)))
                 (sb-thread:signal-semaphore release-reader)
                 (expect (sb-thread:wait-on-semaphore completed-event :timeout 5))
                 (dolist (thread threads)
                   (cl-concurrent-kit:join-thread thread :timeout 10))
                 (setf threads nil))
            (sb-thread:signal-semaphore release-reader)
            (dolist (thread threads)
              (cl-concurrent-kit:join-thread thread :timeout 10))))
        (expect (= 1 (length errors)))
        (expect (eq failed-repository (first (first errors))))
        (expect (typep (second (first errors)) 'error))
        (expect (= 1 applied))
        (expect (= 1 completion-count))))
 (it "discards a stale status result after a newer workspace generation applies"
      (let* ((repository
               (nerimux/workspace-model:make-repository
                :specification "workspace-owner/status-generation"
                :local-path "/tmp/status-generation"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :repository repository :path "/tmp/status-generation/main"))
             (organization
               (nerimux/workspace-model:make-organization
                :host "workspace-owner" :name "status-generation"
                :repositories (list repository)))
             (probe-lock (cl-concurrent-kit:make-lock :name "status generation probe"))
             (old-reader-started (sb-thread:make-semaphore :count 0))
             (release-old-reader (sb-thread:make-semaphore :count 0))
             (new-applied (sb-thread:make-semaphore :count 0))
             (read-count 0) (applied nil) (completion-count 0)
             (threads nil))
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (with-stubbed-fdefinition
            ((nerimux/vcs::%repository-status-shared-stashes
               (lambda (current) (declare (ignore current)) (list :shared)))
             (nerimux/vcs::%read-worktree-status
               (lambda (current &key stashes)
                 (declare (ignore current stashes))
                 (let ((index
                         (cl-concurrent-kit:with-lock-held (probe-lock)
                           (incf read-count))))
                   (if (= index 1)
                       (progn
                         (sb-thread:signal-semaphore old-reader-started)
                         (unless (sb-thread:wait-on-semaphore
                                  release-old-reader :timeout 10)
                           (error "The stale status reader was not released"))
                         :old)
                       :new)))))
          (unwind-protect
               (progn
                 (setf threads
                       (nerimux/vcs:refresh-workspace-status-async
                        :organizations (list organization)
                        :status-applier
                        (lambda (current updates)
                          (declare (ignore current))
                          (push (first updates) applied)
                          (when (eq :new (first updates))
                            (sb-thread:signal-semaphore new-applied)))
                        :on-complete
                        (lambda (completed)
                          (declare (ignore completed))
                          (incf completion-count))))
                 (expect (sb-thread:wait-on-semaphore old-reader-started :timeout 5))
                 (setf threads
                       (append
                        threads
                        (nerimux/vcs:refresh-workspace-status-async
                         :organizations (list organization)
                         :status-applier
                         (lambda (current updates)
                           (declare (ignore current))
                           (push (first updates) applied)
                           (when (eq :new (first updates))
                             (sb-thread:signal-semaphore new-applied)))
                         :on-complete
                         (lambda (completed)
                           (declare (ignore completed))
                           (incf completion-count)))))
                 (expect (sb-thread:wait-on-semaphore new-applied :timeout 5))
                 (expect (equal '(:new) applied))
                 (sb-thread:signal-semaphore release-old-reader)
                 (dolist (thread threads)
                   (cl-concurrent-kit:join-thread thread :timeout 10))
                 (setf threads nil))
            (sb-thread:signal-semaphore release-old-reader)
            (dolist (thread threads)
              (cl-concurrent-kit:join-thread thread :timeout 10)))
        (expect (= 2 read-count))
        (expect (equal '(:new) applied))
        (expect (= 2 completion-count)))))
 (it "settles the request when callback dispatch rejects settlement before acceptance"
      (let* ((repository
               (nerimux/workspace-model:make-repository
                :specification "workspace-owner/dispatch-rejection"
                :local-path "/tmp/dispatch-rejection"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :repository repository
                :path "/tmp/dispatch-rejection/main"))
             (organization
               (nerimux/workspace-model:make-organization
                :host "workspace-owner"
                :name "dispatch-rejection"
                :repositories (list repository)))
             (dispatch-count 0)
             (start-count 0)
             (read-count 0)
             (errors nil)
             (applied-count 0)
             (completion-count 0)
             (completed-event (sb-thread:make-semaphore :count 0))
             (threads nil))
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (with-stubbed-fdefinition
            ((nerimux/vcs::%repository-status-shared-stashes
               (lambda (current)
                 (declare (ignore current))
                 (list :shared)))
             (nerimux/vcs::%read-worktree-status
               (lambda (current &key stashes)
                 (declare (ignore stashes))
                 (incf read-count)
                 (nerimux/workspace-model:worktree-path current))))
          (unwind-protect
               (progn
                 (setf threads
                       (nerimux/vcs:refresh-workspace-status-async
                        :organizations (list organization)
                        :callback-dispatch
                        (lambda (callback)
                          (incf dispatch-count)
                          (if (= dispatch-count 1)
                              (funcall callback)
                              (error "Settlement dispatch was rejected")))
                        :on-start
                        (lambda (current)
                          (declare (ignore current))
                          (incf start-count))
                        :status-applier
                        (lambda (current updates)
                          (declare (ignore current updates))
                          (incf applied-count))
                        :on-error
                        (lambda (current condition)
                          (push (list current condition) errors))
                        :on-complete
                        (lambda (completed)
                          (declare (ignore completed))
                          (incf completion-count)
                          (sb-thread:signal-semaphore completed-event))))
                 (expect
                  (sb-thread:wait-on-semaphore completed-event :timeout 5))
                 (dolist (thread threads)
                   (cl-concurrent-kit:join-thread thread :timeout 10))
                 (setf threads nil))
            (dolist (thread threads)
              (cl-concurrent-kit:join-thread thread :timeout 10)))
          (expect (= 2 dispatch-count))
          (expect (= 1 start-count))
          (expect (= 1 read-count))
          (expect (zerop applied-count))
          (expect (= 1 (length errors)))
          (expect (eq repository (first (first errors))))
          (expect (typep (second (first errors)) 'error))
          (expect (= 1 completion-count)))))
    (it "does not resettle when a synchronous callback errors after dispatch acceptance"
      (let* ((repository
               (nerimux/workspace-model:make-repository
                :specification "workspace-owner/accepted-callback-error"
                :local-path "/tmp/accepted-callback-error"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :repository repository
                :path "/tmp/accepted-callback-error/main"))
             (organization
               (nerimux/workspace-model:make-organization
                :host "workspace-owner"
                :name "accepted-callback-error"
                :repositories (list repository)))
             (probe-lock
               (cl-concurrent-kit:make-lock :name "callback dispatch error probe"))
             (dispatch-count 0)
             (start-count 0)
             (read-count 0)
             (error-count 0)
             (applied-count 0)
             (completion-count 0)
             (callback-errors nil)
             (completed-event (sb-thread:make-semaphore :count 0))
             (threads nil))
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (with-stubbed-fdefinition
            ((nerimux/vcs::%repository-status-shared-stashes
               (lambda (current)
                 (declare (ignore current))
                 (list :shared)))
             (nerimux/vcs::%read-worktree-status
               (lambda (current &key stashes)
                 (declare (ignore stashes))
                 (incf read-count)
                 (error "Fixture status read failed")))
             (cl-concurrent-kit:make-thread
               (lambda (function &key name)
                 (sb-thread:make-thread
                  (lambda ()
                    (handler-case
                        (funcall function)
                      (error (caught)
                        (cl-concurrent-kit:with-lock-held (probe-lock)
                          (push caught callback-errors)))))
                  :name name))))
          (unwind-protect
               (progn
                 (setf threads
                       (nerimux/vcs:refresh-workspace-status-async
                        :organizations (list organization)
                        :callback-dispatch
                        (lambda (callback)
                          (incf dispatch-count)
                          (funcall callback))
                        :on-start
                        (lambda (current)
                          (declare (ignore current))
                          (incf start-count))
                        :status-applier
                        (lambda (current updates)
                          (declare (ignore current updates))
                          (incf applied-count))
                        :on-error
                        (lambda (current condition)
                          (declare (ignore current condition))
                          (incf error-count)
                          (error "Fixture error callback failed"))
                        :on-complete
                        (lambda (completed)
                          (declare (ignore completed))
                          (incf completion-count)
                          (sb-thread:signal-semaphore completed-event))))
                 (expect (sb-thread:wait-on-semaphore completed-event :timeout 5))
                 (dolist (thread threads)
                   (cl-concurrent-kit:join-thread thread :timeout 10))
                 (setf threads nil))
            (dolist (thread threads)
              (cl-concurrent-kit:join-thread thread :timeout 10)))
        (expect (= 2 dispatch-count))
        (expect (= 1 start-count))
        (expect (= 1 read-count))
        (expect (= 1 error-count))
        (expect (zerop applied-count))
        (expect (= 1 completion-count))
        (expect (= 1 (length callback-errors)))
        (expect (typep (first callback-errors) 'error)))))
    (it "caps status readers across overlapping workspace refreshes"
      (labels ((make-organization (name suffix)
                 (let ((repositories
                         (loop for repository-index below 17
                               collect
                                 (let ((repository
                                         (nerimux/workspace-model:make-repository
                                          :specification
                                          (format nil "workspace-owner/status-overlap-~A-~D"
                                                  suffix repository-index)
                                          :local-path
                                          (format nil "/tmp/status-overlap-~A-~D"
                                                  suffix repository-index))))
                                   (dotimes (worktree-index 4)
                                     (nerimux/workspace-model:repository-add-worktree
                                      repository
                                      (nerimux/workspace-model:make-worktree
                                       :repository repository
                                       :path
                                       (format nil "/tmp/status-overlap-~A-~D/worktree-~D"
                                               suffix repository-index worktree-index))))
                                   repository))))
                   (nerimux/workspace-model:make-organization
                    :host "workspace-owner" :name name :repositories repositories))))
        (let* ((first-organization (make-organization "status-overlap-first" "first"))
               (second-organization (make-organization "status-overlap-second" "second"))
               (first-repositories
                 (nerimux/workspace-model:organization-repositories
                  first-organization))
               (release-first (sb-thread:make-semaphore :count 0))
               (release-second (sb-thread:make-semaphore :count 0))
               (first-saturated (sb-thread:make-semaphore :count 0))
               (second-prepared (sb-thread:make-semaphore :count 0))
               (second-reader-started (sb-thread:make-semaphore :count 0))
               (probe-lock
                 (cl-concurrent-kit:make-lock :name "overlapping status refresh probe"))
               (active 0) (peak 0) (first-reads 0) (second-reads 0)
               (first-threads nil) (second-threads nil))
          (with-stubbed-fdefinition
              ((nerimux/vcs::%repository-status-shared-stashes
                 (lambda (repository)
                   (declare (ignore repository))
                   (list :shared)))
               (nerimux/vcs::%read-worktree-status
                 (lambda (worktree &key stashes)
                   (declare (ignore stashes))
                   (let* ((repository
                            (nerimux/workspace-model:worktree-repository worktree))
                          (first-p (member repository first-repositories :test #'eq))
                          (release (if first-p release-first release-second)))
                     (cl-concurrent-kit:with-lock-held (probe-lock)
                       (incf active)
                       (setf peak (max peak active))
                       (if first-p
                           (incf first-reads)
                           (progn
                             (incf second-reads)
                             (sb-thread:signal-semaphore second-reader-started)))
                       (when (and first-p (= active 64))
                         (sb-thread:signal-semaphore first-saturated)))
                     (unwind-protect
                          (progn
                            (unless (sb-thread:wait-on-semaphore release :timeout 10)
                              (error "The overlapping status reader was not released"))
                            (nerimux/workspace-model:worktree-path worktree))
                       (cl-concurrent-kit:with-lock-held (probe-lock)
                         (decf active)))))))
            (unwind-protect
                 (progn
                   (setf first-threads
                         (nerimux/vcs:refresh-workspace-status-async
                          :organizations (list first-organization)
                          :status-applier
                          (lambda (repository updates)
                            (declare (ignore repository updates))
                            nil)))
                   (expect (sb-thread:wait-on-semaphore first-saturated :timeout 10))
                   (setf second-threads
                         (nerimux/vcs:refresh-workspace-status-async
                          :organizations (list second-organization)
                          :on-start
                          (lambda (repository)
                            (declare (ignore repository))
                            (sb-thread:signal-semaphore second-prepared))
                          :status-applier
                          (lambda (repository updates)
                            (declare (ignore repository updates))
                            nil)))
                   (dotimes (index 17)
                     (declare (ignore index))
                     (expect
                      (sb-thread:wait-on-semaphore second-prepared :timeout 10)))
                   (dotimes (index 5)
                     (declare (ignore index))
                     (sb-thread:signal-semaphore release-first))
                   (expect (sb-thread:wait-on-semaphore second-reader-started :timeout 10))
                   (cl-concurrent-kit:with-lock-held (probe-lock)
                     (expect (<= peak 64)))
                   (dotimes (index 128)
                     (declare (ignore index))
                     (sb-thread:signal-semaphore release-first)
                     (sb-thread:signal-semaphore release-second))
                   (dolist (thread first-threads)
                     (cl-concurrent-kit:join-thread thread :timeout 10))
                   (dolist (thread second-threads)
                     (cl-concurrent-kit:join-thread thread :timeout 10))
                   (setf first-threads nil second-threads nil))
              (progn
                (dotimes (index 128)
                  (declare (ignore index))
                  (sb-thread:signal-semaphore release-first)
                  (sb-thread:signal-semaphore release-second))
                (dolist (thread first-threads)
                  (cl-concurrent-kit:join-thread thread :timeout 10))
                (dolist (thread second-threads)
                  (cl-concurrent-kit:join-thread thread :timeout 10)))))
          (expect (= 68 first-reads))
          (expect (= 68 second-reads))
          (expect (zerop active))
          (expect (<= peak 64)))))
    (it "stops a stale status pool after its settlement closure is dropped"
      (let* ((repository
               (nerimux/workspace-model:make-repository
                :specification "workspace-owner/stale-pool"
                :local-path "/tmp/stale-pool"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :repository repository :path "/tmp/stale-pool/main"))
             (organization
               (nerimux/workspace-model:make-organization
                :host "workspace-owner" :name "stale-pool"
                :repositories (list repository)))
             (probe-lock
               (cl-concurrent-kit:make-lock :name "stale status pool probe"))
             (old-reader-started (sb-thread:make-semaphore :count 0))
             (release-old-reader (sb-thread:make-semaphore :count 0))
             (new-reader-started (sb-thread:make-semaphore :count 0))
             (old-settlement-ready (sb-thread:make-semaphore :count 0))
             (new-settlement-ready (sb-thread:make-semaphore :count 0))
             (read-count 0) (old-settlement nil) (new-settlement nil)
             (old-threads nil) (new-threads nil))
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (with-stubbed-fdefinition
            ((nerimux/vcs::%repository-status-shared-stashes
               (lambda (current)
                 (declare (ignore current))
                 (list :shared)))
             (nerimux/vcs::%read-worktree-status
               (lambda (current &key stashes)
                 (declare (ignore current stashes))
                 (case (cl-concurrent-kit:with-lock-held (probe-lock)
                         (incf read-count))
                   (1
                    (sb-thread:signal-semaphore old-reader-started)
                    (unless (sb-thread:wait-on-semaphore release-old-reader :timeout 10)
                      (error "The stale status reader was not released"))
                    :old)
                   (2
                    (sb-thread:signal-semaphore new-reader-started)
                    :new)
                   (otherwise
                    (error "Unexpected stale pool status read"))))))
          (unwind-protect
               (progn
                 (setf old-threads
                       (nerimux/vcs:refresh-workspace-status-async
                        :organizations (list organization)
                        :callback-dispatch
                        (lambda (callback)
                          (setf old-settlement callback)
                          (sb-thread:signal-semaphore old-settlement-ready))
                        :status-applier
                        (lambda (current updates)
                          (declare (ignore current updates))
                          nil)))
                 (expect (sb-thread:wait-on-semaphore old-reader-started :timeout 5))
                 (setf new-threads
                       (nerimux/vcs:refresh-workspace-status-async
                        :organizations (list organization)
                        :callback-dispatch
                        (lambda (callback)
                          (setf new-settlement callback)
                          (sb-thread:signal-semaphore new-settlement-ready))
                        :status-applier
                        (lambda (current updates)
                          (declare (ignore current updates))
                          nil)))
                 (expect (sb-thread:wait-on-semaphore new-reader-started :timeout 5))
                 (expect (sb-thread:wait-on-semaphore new-settlement-ready :timeout 5))
                 (sb-thread:signal-semaphore release-old-reader)
                 (expect (sb-thread:wait-on-semaphore old-settlement-ready :timeout 5))
                 (let ((stopped-p
                        (every
                         (lambda (thread)
                           (handler-case
                               (progn
                                 (cl-concurrent-kit:join-thread thread :timeout 1)
                                 (not (sb-thread:thread-alive-p thread)))
                             (error () nil)))
                         old-threads)))
                   (expect stopped-p))
                 (expect
                  (every (lambda (thread) (not (sb-thread:thread-alive-p thread)))
                         old-threads))
                 (setf old-threads nil))
            (progn
              (sb-thread:signal-semaphore release-old-reader)
              ;; The test dispatcher drops these closures; run them only during
              ;; teardown so the baseline's stranded workers can exit cleanly.
              (when new-settlement (funcall new-settlement))
              (when old-settlement (funcall old-settlement))
              (dolist (thread old-threads)
                (cl-concurrent-kit:join-thread thread :timeout 10))
              (dolist (thread new-threads)
                (cl-concurrent-kit:join-thread thread :timeout 10)))))
        (expect (= 2 read-count))))
    (it "continues preparation workers after a settlement callback signals"
      (let* ((repositories
               (loop for index below 5
                     collect
                       (nerimux/workspace-model:make-repository
                        :specification
                        (format nil "workspace-owner/preparation-callback-~D" index)
                        :local-path
                        (format nil "/tmp/preparation-callback-~D" index))))
             (organization
               (nerimux/workspace-model:make-organization
                :host "workspace-owner" :name "preparation-callback"
                :repositories repositories))
             (probe-lock
               (cl-concurrent-kit:make-lock :name "preparation callback probe"))
             (completed-event (sb-thread:make-semaphore :count 0))
             (start-count 0) (error-count 0) (completion-count 0)
             (threads nil))
        (with-stubbed-fdefinition
            ((nerimux/vcs::%repository-status-shared-stashes
               (lambda (repository)
                 (declare (ignore repository))
                 nil)))
          (unwind-protect
               (progn
                 (setf threads
                       (nerimux/vcs:refresh-workspace-status-async
                        :organizations (list organization)
                        :callback-dispatch
                        (lambda (callback) (funcall callback))
                        :on-start
                        (lambda (repository)
                          (declare (ignore repository))
                          (cl-concurrent-kit:with-lock-held (probe-lock)
                            (incf start-count))
                          (error "Fixture start callback failed"))
                        :on-error
                        (lambda (repository condition)
                          (declare (ignore repository condition))
                          (cl-concurrent-kit:with-lock-held (probe-lock)
                            (incf error-count))
                          (error "Fixture status error callback failed"))
                        :on-complete
                        (lambda (completed-organizations)
                          (expect (equal (list organization) completed-organizations))
                          (cl-concurrent-kit:with-lock-held (probe-lock)
                            (incf completion-count))
                          (sb-thread:signal-semaphore completed-event))))
                 (expect (= 4 (length threads)))
                 (expect
                  (sb-thread:wait-on-semaphore completed-event :timeout 5))
                 (dolist (thread threads)
                   (cl-concurrent-kit:join-thread thread :timeout 10))
                 (setf threads nil))
            (dolist (thread threads)
              (cl-concurrent-kit:join-thread thread :timeout 10))))
        (expect (= 5 start-count))
        (expect (= 5 error-count))
        (expect (= 1 completion-count))))


)

(describe "workspace status queue dynamic catalog bindings"
  (it "checks shared generations on workers before applying in caller bindings"
    (let* ((repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/dynamic-catalog"
              :local-path "/tmp/dynamic-catalog"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path "/tmp/dynamic-catalog/main"))
           (organization
             (nerimux/workspace-model:make-organization
              :host "workspace-owner" :name "dynamic-catalog"
              :repositories (list repository)))
           (callback-lock
             (cl-concurrent-kit:make-lock :name "dynamic catalog callback queue"))
           (callbacks nil)
           (completed-event (sb-thread:make-semaphore :count 0))
           (read-count 0)
           (applied-updates nil)
           (completed-p nil)
           (threads nil))
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (labels ((enqueue-callback (callback)
                 (cl-concurrent-kit:with-lock-held (callback-lock)
                   (setf callbacks (nconc callbacks (list callback)))))
               (take-callback ()
                 (cl-concurrent-kit:with-lock-held (callback-lock)
                   (pop callbacks)))
               (drain-callbacks ()
                 (loop for callback = (take-callback)
                       while callback
                       do (funcall callback))))
        (let ((nerimux/vcs::*workspace-organizations* nil))
          (nerimux/vcs::set-workspace-organizations (list organization))
          (with-stubbed-fdefinition
              ((nerimux/vcs::%repository-status-shared-stashes
                 (lambda (current)
                   (declare (ignore current))
                   nil))
               (nerimux/vcs::%read-worktree-status
                 (lambda (current &key stashes)
                   (declare (ignore current stashes))
                   (incf read-count)
                   :status)))
            (unwind-protect
                 (progn
                   (setf threads
                         (nerimux/vcs:refresh-workspace-status-async
                          :organizations (list organization)
                          :callback-dispatch #'enqueue-callback
                          :status-applier
                          (lambda (current updates)
                            (declare (ignore current))
                            (setf applied-updates updates))
                          :on-complete
                          (lambda (completed)
                            (declare (ignore completed))
                            (sb-thread:signal-semaphore completed-event))))
                   (loop repeat 500
                         until completed-p
                         do (drain-callbacks)
                            (setf completed-p
                                  (sb-thread:wait-on-semaphore
                                   completed-event :timeout 0.01)))
                   (expect completed-p)
                   (dolist (thread threads)
                     (cl-concurrent-kit:join-thread thread :timeout 10))
                   (setf threads nil))
              (progn
                (drain-callbacks)
                (dolist (thread threads)
                  (cl-concurrent-kit:join-thread thread :timeout 10)))))
          (expect (= 1 read-count))
          (expect (equal (list :status) applied-updates)))))))
(describe "workspace status queue process-wide reader limit"
          (it "caps readers across overlapping refreshes"
              (let* ((global-limit
                      (sb-thread:semaphore-count
                       nerimux/vcs::*workspace-worktree-status-reader-semaphore*))
                     (repositories
                      (loop for repository-index from 1 to 16
                            collect (let ((repository
                                           (nerimux/workspace-model:make-repository
                                            :specification
                                            (format nil
                                                    "workspace-owner/global-limit-~D"
                                                    repository-index)
                                            :local-path
                                            (format nil
                                                    "/tmp/global-limit-~D"
                                                    repository-index))))
                                      (dotimes (worktree-index 8)
                                        (nerimux/workspace-model:repository-add-worktree
                                         repository
                                         (nerimux/workspace-model:make-worktree
                                          :repository
                                          repository
                                          :path
                                          (format nil
                                                  "/tmp/global-limit-~D/worktree-~D"
                                                  repository-index
                                                  worktree-index))))
                                      repository)))
                     (organization
                      (nerimux/workspace-model:make-organization :host
                                                                 "workspace-owner"
                                                                 :name
                                                                 "global-limit"
                                                                 :repositories
                                                                 repositories))
                     (probe-lock
                      (cl-concurrent-kit:make-lock :name
                                                   "global reader limit probe"))
                     (release-readers (sb-thread:make-semaphore :count 0))
                     (at-limit (sb-thread:make-semaphore :count 0))
                     (above-limit (sb-thread:make-semaphore :count 0))
                     (second-preparation-ready
                      (sb-thread:make-semaphore :count 0))
                     (completed-events (sb-thread:make-semaphore :count 0))
                     (second-started-repositories (make-hash-table :test #'eq))
                     (second-preparation-count 0)
                     (completed-count 0)
                     (read-count 0)
                     (in-flight 0)
                     (peak 0)
                     (first-threads nil)
                     (second-threads nil))
                (expect (> global-limit 0))
                (with-stubbed-fdefinition
                 ((nerimux/vcs::%repository-status-shared-stashes
                   (lambda (repository)
                     (when
                         (cl-concurrent-kit:with-lock-held (probe-lock)
                                                           (when
                                                               (gethash
                                                                repository
                                                                second-started-repositories)
                                                             (= 16
                                                                (incf
                                                                 second-preparation-count))))
                       (sb-thread:signal-semaphore second-preparation-ready))
                     nil))
                  (nerimux/vcs::%read-worktree-status
                   (lambda (worktree &key stashes)
                     (declare (ignore worktree stashes))
                     (let ((active
                            (cl-concurrent-kit:with-lock-held (probe-lock)
                                                              (incf read-count)
                                                              (setf peak (max
                                                                          peak
                                                                          (incf
                                                                           in-flight)))
                                                              in-flight)))
                       (when (= active global-limit)
                         (sb-thread:signal-semaphore at-limit))
                       (when (= active (1+ global-limit))
                         (sb-thread:signal-semaphore above-limit))
                       (unwind-protect
                           (progn
                             (unless
                                 (sb-thread:wait-on-semaphore release-readers
                                                              :timeout
                                                              10)
                               (error
                                "The global-limit status reader was not released"))
                             :status)
                         (cl-concurrent-kit:with-lock-held (probe-lock)
                                                           (decf in-flight)))))))
                 (unwind-protect
                     (progn
                       (setf first-threads (nerimux/vcs:refresh-workspace-status-async
                                            :organizations
                                            (list organization)
                                            :callback-dispatch
                                            (lambda (callback)
                                              (funcall callback))
                                            :status-applier
                                            (lambda (repository updates)
                                              (declare (ignore repository
                                                               updates)))
                                            :on-complete
                                            (lambda (completed-organizations)
                                              (expect
                                               (equal (list organization)
                                                      completed-organizations))
                                              (cl-concurrent-kit:with-lock-held
                                               (probe-lock)
                                               (incf completed-count))
                                              (sb-thread:signal-semaphore
                                               completed-events))))
                       (expect
                        (= (+ (min global-limit 128) 4) (length first-threads)))
                       (expect
                        (sb-thread:wait-on-semaphore at-limit :timeout 10))
                       (setf second-threads (nerimux/vcs:refresh-workspace-status-async
                                             :organizations
                                             (list organization)
                                             :callback-dispatch
                                             (lambda (callback)
                                               (funcall callback))
                                             :on-start
                                             (lambda (repository)
                                               (cl-concurrent-kit:with-lock-held
                                                (probe-lock)
                                                (setf (gethash repository
                                                               second-started-repositories) t)))
                                             :status-applier
                                             (lambda (repository updates)
                                               (declare (ignore repository
                                                                updates)))
                                             :on-complete
                                             (lambda (completed-organizations)
                                               (expect
                                                (equal (list organization)
                                                       completed-organizations))
                                               (cl-concurrent-kit:with-lock-held
                                                (probe-lock)
                                                (incf completed-count))
                                               (sb-thread:signal-semaphore
                                                completed-events))))
                       (expect
                        (= (+ (min global-limit 128) 4) (length second-threads)))
                       (expect
                        (sb-thread:wait-on-semaphore second-preparation-ready
                                                     :timeout
                                                     10))
                       (expect
                        (not
                         (sb-thread:wait-on-semaphore above-limit :timeout 1)))
                       (dotimes (index (* 4 global-limit))
                         (declare (ignore index))
                         (sb-thread:signal-semaphore release-readers))
                       (expect
                        (sb-thread:wait-on-semaphore completed-events
                                                     :timeout
                                                     20))
                       (expect
                        (sb-thread:wait-on-semaphore completed-events
                                                     :timeout
                                                     20))
                       (dolist (thread (append first-threads second-threads))
                         (cl-concurrent-kit:join-thread thread :timeout 10))
                       (expect
                        (every
                         (lambda (thread)
                           (not (sb-thread:thread-alive-p thread)))
                         (append first-threads second-threads)))
                       (setf first-threads nil
                             second-threads nil))
                   (progn
                     (dotimes (index (* 4 global-limit))
                       (declare (ignore index))
                       (sb-thread:signal-semaphore release-readers))
                     (dolist (thread (append first-threads second-threads))
                       (cl-concurrent-kit:join-thread thread :timeout 10))))
                 (cl-concurrent-kit:with-lock-held (probe-lock)
                                                   (expect
                                                    (<= peak global-limit))
                                                   (expect
                                                    (>= read-count
                                                        (* 2 global-limit)))
                                                   (expect (zerop in-flight))
                                                   (expect
                                                    (= 2 completed-count))))))
          (it "settles every request when preparation diagnostics signal"
              (let* ((repositories
                       (loop for repository-index from 1 to 5
                             collect
                               (nerimux/workspace-model:make-repository
                                :specification
                                (format nil
                                        "workspace-owner/preparation-diagnostic-failure-~D"
                                        repository-index)
                                :local-path
                                (format nil
                                        "/tmp/preparation-diagnostic-failure-~D"
                                        repository-index))))
                     (organization
                       (nerimux/workspace-model:make-organization
                        :host "workspace-owner"
                        :name "preparation-diagnostic-failure"
                        :repositories repositories))
                     (probe-lock
                       (cl-concurrent-kit:make-lock
                        :name "preparation diagnostic probe"))
                     (completed-event (sb-thread:make-semaphore :count 0))
                     (real-signal-semaphore
                       (symbol-function 'sb-thread:signal-semaphore))
                     (signal-count 0)
                     (preparation-worker-threads nil)
                     (diagnostic-count 0)
                     (read-count 0)
                     (start-count 0)
                     (error-count 0)
                     (completion-count 0)
                     (threads nil))
                (dolist (repository repositories)
                  (nerimux/workspace-model:repository-add-worktree
                   repository
                   (nerimux/workspace-model:make-worktree
                    :repository repository
                    :path
                    (format nil "~A/main"
                            (nerimux/workspace-model:repository-local-path repository)))))
                (sb-ext:without-package-locks
                  (with-stubbed-fdefinition
                   ((nerimux/vcs::%repository-status-shared-stashes
                     (lambda (repository)
                       (declare (ignore repository))
                       nil))
                    (nerimux/vcs::%read-worktree-status
                     (lambda (worktree &key stashes)
                       (declare (ignore worktree stashes))
                       (cl-concurrent-kit:with-lock-held (probe-lock)
                         (incf read-count))
                       :unexpected))
                    (sb-thread:signal-semaphore
                     (lambda (semaphore &optional (count 1))
                       (let ((fail-p
                               (cl-concurrent-kit:with-lock-held (probe-lock)
                                 (when (member sb-thread:*current-thread*
                                               preparation-worker-threads
                                               :test (function eq))
                                   (incf signal-count)
                                   (<= signal-count 4)))))
                         (if fail-p
                             (error "Fixture queue signal failed")
                             (funcall real-signal-semaphore semaphore count)))))
                    (log-kit:emit-log
                     (lambda (logger level message fields)
                       (declare (ignore logger level message fields))
                       (cl-concurrent-kit:with-lock-held (probe-lock)
                         (incf diagnostic-count))
                       (error "Fixture diagnostic logger failed"))))
                   (unwind-protect
                        (progn
                          (setf threads
                                (nerimux/vcs:refresh-workspace-status-async
                                 :organizations (list organization)
                                 :callback-dispatch
                                 (lambda (callback) (funcall callback))
                                 :status-applier
                                 (lambda (repository updates)
                                   (declare (ignore repository updates)))
                                 :on-start
                                 (lambda (repository)
                                   (declare (ignore repository))
                                   (cl-concurrent-kit:with-lock-held (probe-lock)
                                     (incf start-count)
                                     (pushnew sb-thread:*current-thread*
                                              preparation-worker-threads
                                              :test (function eq))))
                                 :on-error
                                 (lambda (repository condition)
                                   (declare (ignore repository condition))
                                   (cl-concurrent-kit:with-lock-held (probe-lock)
                                     (incf error-count)))
                                 :on-complete
                                 (lambda (completed-organizations)
                                   (expect (equal (list organization)
                                                  completed-organizations))
                                   (cl-concurrent-kit:with-lock-held (probe-lock)
                                     (incf completion-count))
                                   (sb-thread:signal-semaphore completed-event))))
                          (expect
                           (= (+ (min nerimux/vcs::*workspace-worktree-status-worker-limit* 5)
                                 (min nerimux/vcs::+workspace-status-preparation-worker-limit+
                                      5))
                              (length threads)))
                          (expect (sb-thread:wait-on-semaphore completed-event :timeout 10))
                          (dolist (thread threads)
                            (cl-concurrent-kit:join-thread thread :timeout 5))
                          (expect
                           (every
                            (lambda (thread) (not (sb-thread:thread-alive-p thread)))
                            threads))
                          (setf threads nil))
                     (dolist (thread threads)
                       (ignore-errors (cl-concurrent-kit:join-thread thread :timeout 1)))))
                (cl-concurrent-kit:with-lock-held (probe-lock)
                  (expect (= 5 start-count))
                  (expect (= 4 diagnostic-count))
                  (expect (>= signal-count 4))
                  (expect (= 1 read-count))
                  (expect (= 4 error-count))
                  (expect (= 1 completion-count)))))))
