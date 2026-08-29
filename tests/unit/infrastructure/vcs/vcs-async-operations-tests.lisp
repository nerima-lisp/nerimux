(in-package #:nerimux/test)

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
          (completed nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%delete-worktree-command
             (lambda (&rest arguments)
               (declare (ignore arguments))
               :repository))
           (nerimux/vcs::%capture-worktree-operation-result
             (lambda (repository result)
               (declare (ignore repository result))
               :snapshot))
           (nerimux/vcs::%apply-worktree-operation-result
             (lambda (snapshot)
               (declare (ignore snapshot))
               (incf refresh-count)
               t)))
        (let ((thread
                (nerimux/vcs:delete-worktree-async
                 nil
                 :callback-dispatch (lambda (callback) (push callback queued))
                 :on-complete (lambda (result) (setf completed result)))))
          ;; Bounded, like every other join in tests/ (vcs-operations-tests.lisp:24,
          ;; vcs-tests.lisp:174, helpers-loop-fixtures.lisp:55 all use 2s): an
          ;; unbounded join here blocks the whole runner, not just this case, if
          ;; the worker ever fails to finish.  Bare seconds, not a
          ;; CL-DATE-KIT:DURATION -- the DURATION rule in development-rules.md is
          ;; scoped to CL-CONCURRENT-KIT:WITH-TIMEOUT, while JOIN-THREAD's
          ;; :TIMEOUT forwards straight to SB-THREAD:JOIN-THREAD, which takes
          ;; seconds.
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
                   (lambda (repository result)
                     (declare (ignore repository))
                     result))
                 (nerimux/vcs::%apply-worktree-operation-result
                   (lambda (result) result)))
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
  (it "fetches through the adapter and refreshes status"
    (let* ((repository
             (nerimux/workspace-model:make-repository
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
