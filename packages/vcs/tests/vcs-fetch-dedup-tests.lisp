(in-package #:nerimux/test/vcs)

(defun %fetch-test-git (directory &rest arguments)
  (string-trim '(#\Newline #\Return)
               (uiop:run-program (append (list "git" "-C" directory) arguments)
                                 :output :string :error-output :string)))

(defun %detached-test-create (repository)
  (let ((receipt nil) (errors nil))
    (sb-thread:join-thread
     (nerimux/vcs:create-detached-worktree-async
      repository :on-complete (lambda (value) (setf receipt value))
      :on-error (lambda (condition) (push condition errors))))
    (values receipt errors)))

(describe "vcs worktree guarded cancellation"
  (it "runs the guard before removal and permits a retry after guard rejection"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (multiple-value-bind (receipt errors) (%detached-test-create repository)
         (expect (null errors))
         (let ((worktree (nerimux/vcs:detached-worktree-result-worktree receipt))
               (path (nerimux/vcs:detached-worktree-result-path receipt))
               (guards 0) (failure nil) (completed nil))
           (sb-thread:join-thread
            (nerimux/vcs:delete-worktree-async
             worktree :force nil
             :before-delete (lambda () (incf guards) (error "identity changed"))
             :on-error (lambda (condition) (setf failure condition))))
           (expect failure)
           (expect (= 1 guards))
           (expect (probe-file path))
           (sb-thread:join-thread
            (nerimux/vcs:delete-worktree-async
             worktree :force nil :before-delete (lambda () (incf guards))
             :on-complete (lambda (value) (declare (ignore value)) (setf completed t))))
           (expect completed)
           (expect (= 2 guards))
           (expect (not (probe-file path))))))))
  (it "preserves real dirty and locked worktrees without force and removes clean controls"
    (dolist (mode '(:dirty :locked))
      (%call-with-worktree-path-repository
       (lambda (repository root)
         (declare (ignore root))
         (multiple-value-bind (receipt errors) (%detached-test-create repository)
           (expect (null errors))
           (let* ((worktree (nerimux/vcs:detached-worktree-result-worktree receipt))
                  (path (nerimux/vcs:detached-worktree-result-path receipt))
                  (dirty-file (concatenate 'string path "/untracked-test"))
                  (bare (nerimux/workspace-model:repository-local-path repository))
                  (failure nil) (completed nil))
             (ecase mode
               (:dirty (with-open-file (stream dirty-file :direction :output
                                                :if-exists :error)
                         (write-string "preserve me" stream)))
               (:locked (%fetch-test-git bare "worktree" "lock" path)))
             (sb-thread:join-thread
              (nerimux/vcs:delete-worktree-async
               worktree :force nil :before-delete (lambda () t)
               :on-error (lambda (condition) (setf failure condition))))
             (expect failure)
             (expect (probe-file path))
             (ecase mode
               (:dirty (expect (string= "preserve me" (uiop:read-file-string dirty-file)))
                       (delete-file dirty-file))
               (:locked (%fetch-test-git bare "worktree" "unlock" path)))
             (sb-thread:join-thread
              (nerimux/vcs:delete-worktree-async
               worktree :force nil :before-delete (lambda () t)
               :on-complete (lambda (value) (declare (ignore value)) (setf completed t))))
             (expect completed)
             (expect (not (probe-file path))))))))))

(describe "vcs detached workspace creation"
  (it "fetches the current main commit and creates detached timestamp-SHA paths"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (let* ((source (concatenate 'string root "source/"))
              (bare (nerimux/workspace-model:repository-local-path repository))
              (config-path (merge-pathnames "config" bare))
              (config (uiop:read-file-string config-path)))
         (%fetch-test-git source "-c" "user.name=Test" "-c"
                          "user.email=test@example.invalid" "-c"
                          "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null"
                          "commit" "--allow-empty" "-m" "new main")
         (multiple-value-bind (receipt errors) (%detached-test-create repository)
           (expect (null errors))
           (expect receipt)
           (let ((path (nerimux/vcs:detached-worktree-result-path receipt))
                 (head (%fetch-test-git source "rev-parse" "HEAD")))
             (expect (string= head (nerimux/vcs:detached-worktree-result-head receipt)))
             (expect (string= head (%fetch-test-git path "rev-parse" "HEAD")))
             (expect (string= "" (%fetch-test-git path "branch" "--show-current")))
             (expect (search (concatenate 'string "-" (%fetch-test-git path "rev-parse" "--short" "HEAD")) path))
             (expect (nerimux/vcs:detached-worktree-result-worktree receipt))
             (expect (null (nerimux/vcs:detached-worktree-result-refresh-error receipt)))
             (expect (string= config (uiop:read-file-string config-path)))))))))
  (it "creates from the local branch rather than an unconfirmed tracking ref"
    ;; This asserted that a failed fetch aborted the create. It no longer does
    ;; (review/R3: the branch %REPOSITORY-DEFAULT-BRANCH names need not exist on
    ;; the remote at all, and aborting made create unusable on such a clone),
    ;; so what is asserted now is the part that always mattered: the start point
    ;; is not read from a tracking ref the failed fetch could not confirm.
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (let* ((source (concatenate 'string root "source/"))
              (bare (nerimux/workspace-model:repository-local-path repository))
              (local-head (%fetch-test-git bare "rev-parse" "refs/heads/main")))
         (%fetch-test-git source "-c" "user.name=Test" "-c"
                          "user.email=test@example.invalid" "-c"
                          "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null"
                          "commit" "--allow-empty" "-m" "tracking ref tip")
         (%fetch-test-git bare "fetch" "origin" "+refs/heads/main:refs/remotes/origin/main")
         (let ((tracking-head (%fetch-test-git bare "rev-parse" "refs/remotes/origin/main")))
           (expect (not (string= local-head tracking-head)))
           (%fetch-test-git (concatenate 'string root "source/") "branch" "-m" "other")
           (multiple-value-bind (receipt errors) (%detached-test-create repository)
             (expect (null errors))
             (expect receipt)
             (expect (nerimux/vcs:detached-worktree-result-fetch-error receipt))
             (expect (string= local-head
                              (nerimux/vcs:detached-worktree-result-head receipt)))
             (expect (not (string= tracking-head
                                   (nerimux/vcs:detached-worktree-result-head receipt))))
             (expect (string= local-head
                              (%fetch-test-git
                               (nerimux/vcs:detached-worktree-result-path receipt)
                               "rev-parse" "HEAD")))))
         (%fetch-test-git (concatenate 'string root "source/") "branch" "-m" "main")
         (multiple-value-bind (receipt errors) (%detached-test-create repository)
           (expect (null errors))
           (expect receipt)
           (expect (null (nerimux/vcs:detached-worktree-result-fetch-error receipt))))))))
  (it "returns a receipt and releases reservation when both dispatch attempts fail"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (let ((dispatches 0) (cancelled nil) (pending nil)
             (completed 0) (failed 0))
         (multiple-value-bind (receipt failure)
             (sb-thread:join-thread
              (nerimux/vcs:create-detached-worktree-async
               repository
               :on-complete (lambda (value) (declare (ignore value)) (incf completed))
               :on-error (lambda (condition) (declare (ignore condition)) (incf failed))
               :callback-dispatch
               (lambda (callback)
                 (push callback cancelled)
                 (incf dispatches)
                 (error "dispatch failed"))))
           (expect receipt)
           (expect failure)
           (expect (= 2 dispatches))
           (expect (string= (nerimux/vcs:detached-worktree-result-head receipt)
                            (%fetch-test-git (nerimux/vcs:detached-worktree-result-path receipt)
                                             "rev-parse" "HEAD")))
           (let ((second (sb-thread:join-thread
                          (nerimux/vcs:create-detached-worktree-async
                           repository :callback-dispatch
                           (lambda (callback) (push callback pending))))))
             (expect second)
             (dolist (callback cancelled) (funcall callback))
             (expect (= 0 completed))
             (expect (= 0 failed))
             (expect (null (nerimux/vcs:create-detached-worktree-async repository)))
             (expect (= 1 (length pending)))
             (funcall (pop pending))
             (expect (not (string= (nerimux/vcs:detached-worktree-result-path receipt)
                                   (nerimux/vcs:detached-worktree-result-path second))))))))))
  (it "keeps reservation while an already started callback survives dispatch failure"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (let ((entered (sb-thread:make-semaphore :count 0))
             (resume (sb-thread:make-semaphore :count 0))
             (delivery nil) (dispatches 0) (applications 0)
             (original (symbol-function 'nerimux/vcs::%apply-detached-worktree-result)))
         (with-stubbed-fdefinition
             ((nerimux/vcs::%apply-detached-worktree-result
               (lambda (repository result)
                 (sb-thread:signal-semaphore entered)
                 (sb-thread:wait-on-semaphore resume)
                 (incf applications)
                 (funcall original repository result))))
           (unwind-protect
                (progn
                  (multiple-value-bind (receipt failure)
                      (sb-thread:join-thread
                       (nerimux/vcs:create-detached-worktree-async
                        repository :callback-dispatch
                        (lambda (callback)
                          (when (= 1 (incf dispatches))
                            (setf delivery (sb-thread:make-thread callback))
                            (sb-thread:wait-on-semaphore entered))
                          (error "dispatch failed after delivery started"))))
                    (expect receipt)
                    (expect failure))
                  (expect (= 2 dispatches))
                  (expect (= 0 applications))
                  (expect (null (nerimux/vcs:create-detached-worktree-async repository))))
             (sb-thread:signal-semaphore resume)
             (when delivery (sb-thread:join-thread delivery)))
           (expect (= 1 applications)))
         (multiple-value-bind (receipt errors) (%detached-test-create repository)
           (expect receipt)
           (expect (null errors)))))))
  (it "retains the created path when refresh reading fails"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (with-stubbed-fdefinition
           ((nerimux/vcs::%read-repository-refresh
             (lambda (&rest arguments) (declare (ignore arguments)) (error "read failed"))))
         (multiple-value-bind (receipt errors) (%detached-test-create repository)
           (expect (null errors))
           (expect (nerimux/vcs:detached-worktree-result-refresh-error receipt))
           (expect (probe-file (nerimux/vcs:detached-worktree-result-path receipt)))
           (expect (string= (nerimux/vcs:detached-worktree-result-head receipt)
                            (%fetch-test-git (nerimux/vcs:detached-worktree-result-path receipt)
                                             "rev-parse" "HEAD"))))))))
  (it "retains the created path when refresh application fails"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (with-stubbed-fdefinition
           ((nerimux/vcs::%apply-repository-refresh
             (lambda (&rest arguments) (declare (ignore arguments)) (error "apply failed"))))
         (multiple-value-bind (receipt errors) (%detached-test-create repository)
           (expect (null errors))
           (expect (nerimux/vcs:detached-worktree-result-refresh-error receipt))
           (expect (probe-file (nerimux/vcs:detached-worktree-result-path receipt))))))))
  (it "rejects duplicate creation until dispatch delivery and releases after delivery"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (let ((queued nil) (receipt nil) (errors nil) (attempts 0)
             (original (symbol-function 'nerimux/vcs::%fetch-default-branch)))
         (with-stubbed-fdefinition
             ((nerimux/vcs::%fetch-default-branch
               (lambda (repository branch)
                 (incf attempts)
                 (funcall original repository branch))))
           (sb-thread:join-thread
            (nerimux/vcs:create-detached-worktree-async
             repository :callback-dispatch (lambda (callback) (push callback queued))
             :on-complete (lambda (value) (setf receipt value))))
           (expect (null receipt))
           (expect (= 1 (length queued)))
           (expect (null (nerimux/vcs:create-detached-worktree-async
                          (nerimux/workspace-model:make-repository
                           :specification "workspace-owner/duplicate"
                           :local-path (nerimux/workspace-model:repository-local-path repository))
                          :on-error (lambda (condition) (push condition errors)))))
           (expect (= 1 (length errors)))
           (expect (= 1 attempts))
           (funcall (pop queued))
           (expect receipt)
           (multiple-value-bind (second second-errors) (%detached-test-create repository)
             (expect (null second-errors))
             (expect second)
             (expect (= 2 attempts))
             (expect (not (string= (nerimux/vcs:detached-worktree-result-path receipt)
                                   (nerimux/vcs:detached-worktree-result-path second))))))))))
  (it "fetches the named default branch explicitly and disables interactive authentication"
    (let ((arguments nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%repository-backend (lambda (repository) repository))
           (nerimux/vcs::%repository-origin-p (lambda (repository)
                                                (declare (ignore repository))
                                                t)))
        (with-stubbed-fdefinition
            ((vcs-kit:vcs-fetch (lambda (repository &rest args)
                                 (expect (eq repository :repository))
                                 (setf arguments args))))
          (nerimux/vcs::%fetch-default-branch :repository "main")))
      (expect (equal (subseq arguments 0 2)
                     '("origin" "+refs/heads/main:refs/remotes/origin/main")))
      (expect (eq :execution-options (third arguments)))
      (expect (equal '(("GIT_TERMINAL_PROMPT" . "0") ("GIT_ASKPASS" . "true")
                       ("SSH_ASKPASS" . "true") ("GIT_SSH_COMMAND" . "ssh -oBatchMode=yes"))
                     (getf (fourth arguments) :environment-update))))))

(defun %check-bare-fetch (async-p)
  (%call-with-worktree-path-repository
   (lambda (repository root)
     (let* ((bare (concatenate 'string root "repository.git/"))
            (source (concatenate 'string root "source/"))
            (config (uiop:read-file-string (concatenate 'string bare "config")))
            (old-tip (%fetch-test-git bare "rev-parse" "main"))
            (errors nil)
            (completed 0))
       (%fetch-test-git source "-c" "user.name=Test"
                        "-c" "user.email=test@example.invalid"
                        "-c" "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null"
                        "commit" "--allow-empty" "-m" "advance")
       (let ((new-tip (%fetch-test-git source "rev-parse" "HEAD")))
         (expect (not (string= old-tip new-tip)))
         (if async-p
             (sb-thread:join-thread
              (nerimux/vcs:fetch-repository-async
               repository
               :on-error (lambda (condition) (push condition errors))
               :on-complete (lambda (value) (declare (ignore value))
                              (incf completed))))
             (progn (nerimux/vcs::fetch-repository repository) (incf completed)))
         (expect (null errors))
         (expect (= 1 completed))
         (expect (string= old-tip (%fetch-test-git bare "rev-parse" "main")))
         (expect (string= config (uiop:read-file-string
                                  (concatenate 'string bare "config"))))
         (expect (string= new-tip (%fetch-test-git bare "rev-parse" "origin/main")))
         (expect (string= new-tip (%fetch-test-git bare "rev-parse" "origin/HEAD")))
         (let ((path (concatenate 'string root "created")))
           (expect (nerimux/vcs:create-worktree repository :branch "from-fetch" :path path))
           (expect (string= new-tip (%fetch-test-git path "rev-parse" "HEAD")))))))))

(describe "renderer-suite/vcs-fetch-bare-real-git"
  (it "fetches an unconfigured bare origin before synchronous default creation"
    (%check-bare-fetch nil))
  (it "fetches an unconfigured bare origin before asynchronous default creation"
    (%check-bare-fetch t)))

(describe "renderer-suite/vcs-fetch-bare-controls"
  (it "preserves configured fetch selection including empty refspecs and local remotes"
    (dolist (setting '(("remote.origin.fetch" "")
                       ("remote.origin.fetch" "+refs/heads/main:refs/remotes/custom/main")
                       ("branch.main.remote" ".")
                       ("branch.main.remote" "other")
                       ("branch.main.remote" "")
                       ("fetch.all" "true")))
      (%call-with-worktree-path-repository
       (lambda (repository root)
         (let ((bare (concatenate 'string root "repository.git/"))
               (calls nil))
           (apply #'%fetch-test-git bare "config" setting)
           (with-stubbed-fdefinition
            ((vcs-kit:vcs-fetch
              (lambda (backend &rest arguments)
                (declare (ignore backend))
                (push arguments calls)
                (error "fetch boundary reached"))))
            (ignore-errors (nerimux/vcs::fetch-repository repository)))
           (expect (equal '(nil) calls)))))))
  (it "keeps plain fetch for nonbare, multiple, renamed, and absent remotes"
    (dolist (mode '(:nonbare :multiple :renamed :absent))
      (%call-with-worktree-path-repository
       (lambda (repository root)
         (let ((bare (concatenate 'string root "repository.git/"))
               (calls nil))
           (ecase mode
             (:nonbare
              (setf repository
                    (nerimux/workspace-model:make-repository
                     :specification "test/source"
                     :local-path (concatenate 'string root "source/"))))
             (:multiple (%fetch-test-git bare "remote" "add" "other"
                                         (concatenate 'string root "source/")))
             (:renamed (%fetch-test-git bare "remote" "rename" "origin" "other"))
             (:absent (%fetch-test-git bare "remote" "remove" "origin")))
           (with-stubbed-fdefinition
            ((vcs-kit:vcs-fetch
              (lambda (backend &rest arguments)
                (declare (ignore backend))
                (push arguments calls)
                (error "fetch boundary reached"))))
            (ignore-errors (nerimux/vcs::fetch-repository repository)))
           (expect (equal '(nil) calls)))))))
  (it "preserves a direct origin HEAD ref"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (let* ((bare (concatenate 'string root "repository.git/"))
              (tip (%fetch-test-git bare "rev-parse" "main")))
         (%fetch-test-git bare "update-ref" "refs/remotes/origin/HEAD" tip)
         (nerimux/vcs::fetch-repository repository)
         (expect (string= tip (%fetch-test-git bare "rev-parse" "origin/HEAD")))
         (expect (null (ignore-errors
                         (%fetch-test-git bare "symbolic-ref"
                                          "refs/remotes/origin/HEAD"))))))))
  (it "rejects malformed boolean configuration before fetching"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (%fetch-test-git (concatenate 'string root "repository.git/")
                        "config" "fetch.all" "not-a-bool")
       (let ((called nil) (failure nil))
         (with-stubbed-fdefinition
          ((vcs-kit:vcs-fetch
            (lambda (&rest arguments) (declare (ignore arguments)) (setf called t))))
          (handler-case (nerimux/vcs::fetch-repository repository)
            (error (condition) (setf failure condition))))
         (expect (typep failure 'vcs-kit:vcs-command-exit-error))
         (expect (not called))))))
  (it "preserves an existing symbolic HEAD even when its target is absent"
    (dolist (target '("refs/remotes/origin/main" "refs/remotes/origin/missing"))
      (%call-with-worktree-path-repository
       (lambda (repository root)
         (let ((bare (concatenate 'string root "repository.git/")))
           (%fetch-test-git bare "symbolic-ref" "refs/remotes/origin/HEAD" target)
           (nerimux/vcs::fetch-repository repository)
           (expect (string= target (%fetch-test-git bare "symbolic-ref"
                                                    "refs/remotes/origin/HEAD"))))))))
  (it "reports set-head failure after fetching and releases the asynchronous fetch key"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (let ((bare (concatenate 'string root "repository.git/"))
             (source (concatenate 'string root "source/"))
             (failures nil) (completions 0))
         (%fetch-test-git source "symbolic-ref" "HEAD" "refs/heads/missing")
         (dotimes (attempt 2)
           (sb-thread:join-thread
            (nerimux/vcs:fetch-repository-async
             repository :on-error (lambda (condition) (push condition failures))
             :on-complete (lambda (value) (declare (ignore value))
                            (incf completions)))))
         (expect (= 2 (length failures)))
         (expect (every (lambda (condition)
                          (typep condition 'vcs-kit:vcs-command-exit-error)) failures))
         (expect (= 2 completions))
         (expect (string= (%fetch-test-git bare "rev-parse" "main")
                          (%fetch-test-git bare "rev-parse" "origin/main"))))))))

(defstruct %job-fetch-fixture
  repositories organization queue threads events failures
  (lock (sb-thread:make-mutex))
  (entered (make-hash-table :test #'eq))
  (resume (make-hash-table :test #'eq))
  (io-threads nil))

(defun %job-fetch-drain (fixture)
  (loop for callback = (sb-thread:with-mutex ((%job-fetch-fixture-lock fixture))
                        (pop (%job-fetch-fixture-queue fixture)))
        while callback do (funcall callback)))

(defun %job-fetch-start (fixture target &rest callbacks)
  (let ((result
          (apply (if (eq target (%job-fetch-fixture-organization fixture))
                     #'nerimux/vcs:fetch-organization-async
                     #'nerimux/vcs:fetch-repository-async)
                 target
                 :callback-dispatch
                 (lambda (callback)
                   (sb-thread:with-mutex ((%job-fetch-fixture-lock fixture))
                     (setf (%job-fetch-fixture-queue fixture)
                           (nconc (%job-fetch-fixture-queue fixture)
                                  (list callback)))))
                 callbacks)))
    (setf (%job-fetch-fixture-threads fixture)
          (append (%job-fetch-fixture-threads fixture)
                  (if (listp result) result (list result))))
    result))

(defun %job-fetch-await (fixture repository)
  (expect (sb-thread:wait-on-semaphore
           (gethash repository (%job-fetch-fixture-entered fixture)) :timeout 2)))

(defun %job-fetch-release (fixture repository)
  (sb-thread:signal-semaphore
   (gethash repository (%job-fetch-fixture-resume fixture))))

(defun %job-fetch-join (fixture)
  (dolist (thread (%job-fetch-fixture-threads fixture))
    (sb-thread:join-thread thread :timeout 2)
    (expect (not (sb-thread:thread-alive-p thread))))
  (setf (%job-fetch-fixture-threads fixture) nil))

(defun %call-with-job-fetch-fixture (count function)
  (let* ((repositories
           (loop repeat count collect
             (nerimux/workspace-model:make-repository
              :specification (format nil "workspace-owner/~A" (gensym "fetch-job-"))
              :local-path (namestring (uiop:getcwd)))))
         (fixture
           (make-%job-fetch-fixture
            :repositories repositories
            :organization (nerimux/workspace-model:make-organization
                           :host "workspace-owner" :name (string (gensym "job-org-"))
                           :repositories repositories))))
    (dolist (repository repositories)
      (setf (gethash repository (%job-fetch-fixture-entered fixture))
            (sb-thread:make-semaphore :count 0)
            (gethash repository (%job-fetch-fixture-resume fixture))
            (sb-thread:make-semaphore :count 0)))
    (with-stubbed-fdefinition
     ((nerimux/vcs::%bare-origin-fetch-p
       (lambda (&rest arguments) (declare (ignore arguments)) nil))
      (vcs-kit:make-vcs-repository
       (lambda (&rest arguments) (declare (ignore arguments)) :job-backend))
      (vcs-kit:vcs-fetch
       (lambda (&rest arguments)
         (declare (ignore arguments))
         (sb-thread:with-mutex ((%job-fetch-fixture-lock fixture))
           (push sb-thread:*current-thread* (%job-fetch-fixture-io-threads fixture)))
         t))
      (nerimux/vcs::%read-repository-status
       (lambda (repository)
         (sb-thread:signal-semaphore
          (gethash repository (%job-fetch-fixture-entered fixture)))
         (sb-thread:wait-on-semaphore
          (gethash repository (%job-fetch-fixture-resume fixture)))
         (when (member repository (%job-fetch-fixture-failures fixture))
           (error "workspace-job-fetch status I/O failure"))
         nil)))
     (unwind-protect (funcall function fixture)
       (dolist (repository repositories)
         (%job-fetch-release fixture repository))
       (%job-fetch-join fixture)
       (%job-fetch-drain fixture)))))

(describe "renderer-suite/workspace-job-fetch"
  (it "workspace-job-fetch repository admission worker start and duplicate are distinct"
    (%call-with-job-fetch-fixture
     1 (lambda (f)
         (let ((repo (first (%job-fetch-fixture-repositories f)))
               (events nil) (caller sb-thread:*current-thread*))
           (expect (%job-fetch-start
                    f repo :on-accepted (lambda () (push :accepted events)
                                         (expect (eq caller sb-thread:*current-thread*)))
                    :on-start (lambda () (push :started events))
                    :on-complete (lambda (result) (push result events))))
           (%job-fetch-await f repo)
           (expect (equal '(:accepted) events))
           (expect (not (eq caller (first (%job-fetch-fixture-io-threads f)))))
           (expect (null (%job-fetch-start
                          f repo :on-accepted (lambda () (push :wrong events))
                          :on-deduplicated (lambda () (push :duplicate events))
                          :on-complete (lambda (result) (push result events)))))
           (%job-fetch-drain f)
           (expect (equal '(nil :duplicate :started :accepted) events))
           (%job-fetch-release f repo)
           (%job-fetch-join f)
           (%job-fetch-drain f)
           (expect (equal (list repo nil :duplicate :started :accepted) events))
           (expect (= 1 (length (%job-fetch-fixture-io-threads f))))))))
  (it "workspace-job-fetch repository error retains admission until completion then retries"
    (%call-with-job-fetch-fixture
     1 (lambda (f)
         (let ((repo (first (%job-fetch-fixture-repositories f))) (events nil))
           (setf (%job-fetch-fixture-failures f) (list repo))
           (%job-fetch-start
            f repo :on-start (lambda () (push :started events))
            :on-error (lambda (condition)
                        (expect (typep condition 'error))
                        (push :error events)
                        (expect (null (%job-fetch-start
                                       f repo :on-deduplicated
                                       (lambda () (push :duplicate events))))))
            :on-complete (lambda (result) (expect (eq repo result))
                           (push :complete events)))
           (%job-fetch-await f repo)
           (%job-fetch-release f repo)
           (%job-fetch-join f)
           (%job-fetch-drain f)
           (expect (equal '(:duplicate :complete :error :started) events))
           (setf (%job-fetch-fixture-failures f) nil)
           (expect (%job-fetch-start f repo :on-accepted (lambda () (push :retry events))
                                    :on-complete (lambda (result) (push result events))))
           (%job-fetch-await f repo)
           (%job-fetch-release f repo)
           (%job-fetch-join f)
           (%job-fetch-drain f)
           (expect (equal (list repo :retry :duplicate :complete :error :started) events))
           (expect (= 2 (length (%job-fetch-fixture-io-threads f))))))))
  (it "workspace-job-fetch organization starts each worker and completes once in input order"
    (%call-with-job-fetch-fixture
     2 (lambda (f)
         (let ((repos (%job-fetch-fixture-repositories f))
               (org (%job-fetch-fixture-organization f)) (accepted 0) (started 0)
               (duplicate 0) (results nil))
           (expect (= 2 (length (%job-fetch-start
                                 f org :on-accepted (lambda () (incf accepted))
                                 :on-start (lambda () (incf started))
                                 :on-complete (lambda (result) (push result results))))))
           (dolist (repo repos) (%job-fetch-await f repo))
           (expect (= 1 accepted))
           (expect (zerop started))
           (expect (null (%job-fetch-start f org :on-deduplicated
                                          (lambda () (incf duplicate)))))
           (%job-fetch-drain f)
           (expect (= 2 started))
           (expect (= 1 duplicate))
           (expect (null results))
           (dolist (repo (reverse repos)) (%job-fetch-release f repo))
           (%job-fetch-join f)
           (%job-fetch-drain f)
           (expect (equal (list repos) results))
           (expect (= 2 (length (%job-fetch-fixture-io-threads f))))))))
  (it "workspace-job-fetch organization partial error waits for siblings before retry"
    (%call-with-job-fetch-fixture
     2 (lambda (f)
         (let* ((repos (%job-fetch-fixture-repositories f)) (failed (first repos))
                (org (%job-fetch-fixture-organization f)) (errors nil) (results nil))
           (setf (%job-fetch-fixture-failures f) (list failed))
           (let ((threads (%job-fetch-start
                           f org :on-error (lambda (repo condition)
                                             (expect (typep condition 'error))
                                             (push repo errors))
                           :on-complete (lambda (result) (push result results)))))
             (dolist (repo repos) (%job-fetch-await f repo))
             (%job-fetch-release f failed)
             (sb-thread:join-thread (first threads) :timeout 2)
             (expect (not (sb-thread:thread-alive-p (first threads))))
             (%job-fetch-drain f)
             (expect (equal (list failed) errors))
             (expect (null results))
             (expect (null (%job-fetch-start f org)))
             (%job-fetch-release f (second repos))
             (%job-fetch-join f)
             (%job-fetch-drain f))
           (expect (equal (list repos) results))
           (setf (%job-fetch-fixture-failures f) nil)
           (expect (= 2 (length (%job-fetch-start f org :on-complete
                                                 (lambda (result) (push result results))))))
           (dolist (repo repos) (%job-fetch-await f repo) (%job-fetch-release f repo))
           (%job-fetch-join f)
           (%job-fetch-drain f)
           (expect (equal (list repos repos) results))
           (expect (= 4 (length (%job-fetch-fixture-io-threads f))))))))
  (it "workspace-job-fetch empty organization admits without worker and deduplicates until dispatch"
    (%call-with-job-fetch-fixture
     0 (lambda (f)
         (let ((org (%job-fetch-fixture-organization f)) (events nil))
           (flet ((start ()
                    (%job-fetch-start f org :on-accepted (lambda () (push :accepted events))
                                      :on-start (lambda () (push :wrong events))
                                      :on-deduplicated (lambda () (push :duplicate events))
                                      :on-complete (lambda (result) (push result events)))))
             (expect (null (start)))
             (expect (equal '(:accepted) events))
             (expect (null (start)))
             (%job-fetch-drain f)
             (expect (equal '(nil :duplicate nil :accepted) events))
             (expect (null (start)))
             (%job-fetch-drain f)
             (expect (equal '(nil :accepted nil :duplicate nil :accepted) events))
             (expect (null (%job-fetch-fixture-io-threads f))))))))
  (it "workspace-job-fetch accepted callback errors release repository and organization admission"
    (%call-with-job-fetch-fixture
     1 (lambda (f)
         (let ((repo (first (%job-fetch-fixture-repositories f))))
           (dolist (target (list repo (%job-fetch-fixture-organization f)))
             (let ((caught nil) (complete 0))
               (handler-case
                   (%job-fetch-start f target :on-accepted
                                     (lambda () (error "workspace-job-fetch acceptance failure")))
                 (simple-error (condition) (setf caught condition)))
               (expect caught)
               (expect (null (%job-fetch-fixture-threads f)))
               (expect (%job-fetch-start f target :on-complete
                                        (lambda (result) (declare (ignore result)) (incf complete))))
               (%job-fetch-await f repo)
               (%job-fetch-release f repo)
               (%job-fetch-join f)
               (%job-fetch-drain f)
               (expect (= 1 complete))))
           (expect (= 2 (length (%job-fetch-fixture-io-threads f))))))))
  (it "workspace-job-fetch queued start callback error permits later settlement and retry"
    (%call-with-job-fetch-fixture
     1 (lambda (f)
         (let ((repo (first (%job-fetch-fixture-repositories f))) (caught nil) (complete 0))
           (%job-fetch-start f repo :on-start
                             (lambda () (error "workspace-job-fetch queued start failure"))
                             :on-complete (lambda (result) (expect (eq repo result)) (incf complete)))
           (%job-fetch-await f repo)
           (%job-fetch-release f repo)
           (%job-fetch-join f)
           (handler-case (%job-fetch-drain f)
             (simple-error (condition) (setf caught condition)))
           (expect caught)
           (expect (zerop complete))
           (%job-fetch-drain f)
           (expect (= 1 complete))
           (expect (%job-fetch-start f repo :on-complete
                                    (lambda (result) (expect (eq repo result)) (incf complete))))
           (%job-fetch-await f repo)
           (%job-fetch-release f repo)
           (%job-fetch-join f)
           (%job-fetch-drain f)
           (expect (= 2 complete))
           (expect (= 2 (length (%job-fetch-fixture-io-threads f)))))))))

(defun %delayed-vcs-fetch (call-log delay-seconds)
  "Return a direct VCS-FETCH stub that records each real fetch invocation."
  (lambda (repository &rest arguments)
    (declare (ignore repository arguments))
    (sleep delay-seconds)
    (push t (cdr call-log))
    t))

(defmacro with-mocked-vcs-fetch ((call-log &key (delay 0.3)) &body body)
  "Replace the direct cl-vcs-kit fetch boundary for BODY."
  `(let ((,call-log (list :log)))
     (with-stubbed-fdefinition
      ((nerimux/vcs::%bare-origin-fetch-p
        (lambda (&rest arguments) (declare (ignore arguments)) nil))
       (vcs-kit:make-vcs-repository
        (lambda (&rest arguments)
          (declare (ignore arguments))
          :fake-backend-repository))
       (vcs-kit:vcs-fetch (%delayed-vcs-fetch ,call-log ,delay)))
      ,@body)))

(defun %poll-until (predicate &key (timeout-seconds 2.0))
  "Poll PREDICATE every 10ms until it returns true or TIMEOUT-SECONDS elapses.
   Returns the predicate's final value."
  (let ((deadline
         (+ (get-internal-real-time)
            (round (* timeout-seconds internal-time-units-per-second)))))
    (loop for result = (funcall predicate)
          when result
            return result
          while (< (get-internal-real-time) deadline)
          do (sleep 0.01)
          finally (return (funcall predicate)))))

(describe "renderer-suite/vcs-fetch-dedup-repository"

  (it "does not start a second real fetch while one is already in flight for the same repository"
    (with-mocked-vcs-fetch (call-log :delay 0.3)
      (let* ((repository
               (nerimux/workspace-model:make-repository
                :specification "workspace-owner/dedup-repo"
                :local-path "/tmp/nerimux-fetch-dedup-repo"))
             (first-result :pending)
             (second-result :pending))
        (nerimux/vcs:fetch-repository-async
         repository
         :on-complete (lambda (result) (setf first-result result)))
        (nerimux/vcs:fetch-repository-async
         repository
         :on-complete (lambda (result) (setf second-result result)))
        (expect (null second-result))
        (expect (eq :pending first-result))
        (expect (%poll-until (lambda () (not (eq :pending first-result)))))
        (expect (eq repository first-result))
        (expect (= 1 (length (cdr call-log))))))))

(describe "renderer-suite/vcs-fetch-dedup-repository-recovery"

  (it "allows a fresh fetch for the same repository once the prior one has completed"
    (with-mocked-vcs-fetch (call-log :delay 0.05)
      (let* ((repository
               (nerimux/workspace-model:make-repository
                :specification "workspace-owner/dedup-repo-recovery"
                :local-path "/tmp/nerimux-fetch-dedup-recovery"))
             (first-done nil)
             (second-result :pending))
        (nerimux/vcs:fetch-repository-async
         repository :on-complete (lambda (result)
                                   (declare (ignore result))
                                   (setf first-done t)))
        (expect (%poll-until (lambda () first-done)))
        (nerimux/vcs:fetch-repository-async
         repository :on-complete (lambda (result) (setf second-result result)))
        (expect (%poll-until (lambda () (not (eq :pending second-result)))))
        (expect (eq repository second-result))
        (expect (= 2 (length (cdr call-log))))))))

(describe "renderer-suite/vcs-fetch-dedup-repository-error-lifecycle"
          (it
           "holds the repository key through error notification and releases it on completion"
           (let* ((repository
                   (nerimux/workspace-model:make-repository :specification
                                                            "workspace-owner/dedup-repo-failure"
                                                            :local-path
                                                            "/tmp/nerimux-fetch-dedup-repo-failure"))
                  (first-error nil)
                  (first-complete nil)
                  (duplicate-error nil)
                  (duplicate-result :pending)
                  (second-error nil)
                  (second-complete nil)
                  (attempts 0))
             (with-stubbed-fdefinition
              ((nerimux/vcs::%bare-origin-fetch-p
                (lambda (&rest arguments) (declare (ignore arguments)) nil))
               (vcs-kit:vcs-fetch
                (lambda (backend &rest arguments)
                  (declare (ignore backend arguments))
                  (incf attempts)
                  (error "synthetic repository fetch failure"))))
              (nerimux/vcs:fetch-repository-async repository
                                                  :on-error
                                                  (lambda (condition)
                                                    (setf first-error condition)
                                                    (nerimux/vcs:fetch-repository-async
                                                     repository
                                                     :on-error
                                                     (lambda 
                                                         (duplicate-condition)
                                                       (setf duplicate-error duplicate-condition))
                                                     :on-complete
                                                     (lambda (result)
                                                       (setf duplicate-result result))))
                                                  :on-complete
                                                  (lambda (result)
                                                    (declare (ignore result))
                                                    (setf first-complete t)))
              (expect
               (%poll-until
                (lambda ()
                  first-complete)))
              (expect first-error)
              (expect (null duplicate-result))
              (expect (null duplicate-error))
              (expect (= 1 attempts))
              (nerimux/vcs:fetch-repository-async repository
                                                  :on-error
                                                  (lambda (condition)
                                                    (setf second-error condition))
                                                  :on-complete
                                                  (lambda (result)
                                                    (declare (ignore result))
                                                    (setf second-complete t)))
              (expect
               (%poll-until
                (lambda ()
                  second-complete)))
              (expect second-error)
              (expect (= 2 attempts))))))

(describe "renderer-suite/vcs-fetch-dedup-organization"

  (it "does not start a second organization-wide fetch while one is already in flight"
    (with-mocked-vcs-fetch (call-log :delay 0.3)
      (let* ((repository
               (nerimux/workspace-model:make-repository
                :specification "workspace-owner/dedup-org-repo"
                :local-path "/tmp/nerimux-fetch-dedup-org"))
             (organization
               (nerimux/workspace-model:make-organization
                :host "workspace-owner" :name "dedup-org"
                :repositories (list repository)))
             (first-result :pending)
             (second-result :pending))
        (nerimux/vcs:fetch-organization-async
         organization
         :on-complete (lambda (result) (setf first-result result)))
        (nerimux/vcs:fetch-organization-async
         organization
         :on-complete (lambda (result) (setf second-result result)))
        (expect (null second-result))
        (expect (%poll-until (lambda () (not (eq :pending first-result)))))
        (expect (equal (list repository) first-result))
        (expect (= 1 (length (cdr call-log))))))))

(describe "renderer-suite/vcs-fetch-dedup-organization-recovery"
          (it "releases the organization key after a repository fetch fails"
              (let* ((repository
                      (nerimux/workspace-model:make-repository :specification
                                                               "workspace-owner/dedup-org-failure"
                                                               :local-path
                                                               "/tmp/nerimux-fetch-dedup-org-failure"))
                     (organization
                      (nerimux/workspace-model:make-organization :host
                                                                 "workspace-owner"
                                                                 :name
                                                                 "dedup-org-failure"
                                                                 :repositories
                                                                 (list
                                                                  repository)))
                     (first-error nil)
                     (first-complete nil)
                     (second-error nil)
                     (second-complete nil)
                     (attempts 0))
                (with-stubbed-fdefinition
                 ((nerimux/vcs::%bare-origin-fetch-p
                   (lambda (&rest arguments) (declare (ignore arguments)) nil))
                  (vcs-kit:vcs-fetch
                   (lambda (backend &rest arguments)
                     (declare (ignore backend arguments))
                     (incf attempts)
                     (error "synthetic organization fetch failure"))))
                 (nerimux/vcs:fetch-organization-async organization
                                                       :on-error
                                                       (lambda 
                                                           (failed-repository
                                                            condition)
                                                         (declare (ignore
                                                                   failed-repository))
                                                         (setf first-error condition))
                                                       :on-complete
                                                       (lambda (repositories)
                                                         (declare (ignore
                                                                   repositories))
                                                         (setf first-complete t)))
                 (expect
                  (%poll-until
                   (lambda ()
                     first-complete)))
                 (expect first-error)
                 (nerimux/vcs:fetch-organization-async organization
                                                       :on-error
                                                       (lambda 
                                                           (failed-repository
                                                            condition)
                                                         (declare (ignore
                                                                   failed-repository))
                                                         (setf second-error condition))
                                                       :on-complete
                                                       (lambda (repositories)
                                                         (declare (ignore
                                                                   repositories))
                                                         (setf second-complete t)))
                 (expect
                  (%poll-until
                   (lambda ()
                     second-complete)))
                 (expect second-error)
                 (expect (= 2 attempts))))))
