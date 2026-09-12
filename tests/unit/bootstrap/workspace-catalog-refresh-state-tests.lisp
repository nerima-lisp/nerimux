(in-package #:nerimux/test)

(describe "workspace-job"
  (it "workspace-job preserves separate operations and rejects superseded tokens and objects"
    (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
           (object (list :repository))
           (scan (nerimux::%workspace-job-begin :repository "repo" :status object))
           (fetch (nerimux::%workspace-job-begin :repository "repo" :fetch object))
           (replacement (nerimux::%workspace-job-begin :repository "repo" :status object)))
      (expect (= 2 (hash-table-count nerimux::*workspace-operation-jobs*)))
      (expect (null (nerimux::%workspace-job-update scan object :succeeded)))
      (expect (null (nerimux::%workspace-job-update replacement (list :repository) :running)))
      (expect (eq :queued (nerimux::workspace-operation-job-state replacement)))
      (expect (nerimux::%workspace-job-update fetch object :running))
      (expect (eq :running (nerimux::workspace-operation-job-state fetch)))))
  (it "workspace-job failure is terminal even when completion follows"
    (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
           (object (list :repository))
           (job (nerimux::%workspace-job-begin :repository "repo" :fetch object)))
      (nerimux::%workspace-job-update job object :running)
      (nerimux::%workspace-job-update job object :failed :outcome :offline)
      (expect (null (nerimux::%workspace-job-update job object :succeeded)))
      (expect (eq :failed (nerimux::workspace-operation-job-state job)))
      (expect (eq :offline (nerimux::workspace-operation-job-outcome job)))))
  (it "workspace-job confirmation stops ticks and cancellation retains its outcome"
    (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
           (nerimux::*workspace-job-spinner-tick* 0)
           (nerimux::*dirty* nil)
           (object (list :worktree))
           (job (nerimux::%workspace-job-begin :worktree "wt" :prune object)))
      (expect (null (nerimux::%workspace-job-tick internal-time-units-per-second)))
      (nerimux::%workspace-job-update job object :running)
      (expect (nerimux::%workspace-job-tick internal-time-units-per-second))
      (expect (search "prune:running" (gethash '(:worktree "wt") (nerimux::%workspace-job-labels))))
      (nerimux::%workspace-job-update job object :running :phase :confirming)
      (expect (null (nerimux::%workspace-job-tick (* 2 internal-time-units-per-second))))
      (expect (search "prune:running confirming" (gethash '(:worktree "wt") (nerimux::%workspace-job-labels))))
      (nerimux::%workspace-job-update job object :failed :outcome :cancelled)
      (expect (search "prune:failed cancelled" (gethash '(:worktree "wt") (nerimux::%workspace-job-labels))))))
  (it "workspace-job retires a succeeded job and reports a failure in plain words"
    (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
           (object (list :repository))
           (job (nerimux::%workspace-job-begin :repository "repo" :status object)))
      (nerimux::%workspace-job-update job object :succeeded)
      (expect (null (gethash '(:repository "repo" :status)
                             nerimux::*workspace-operation-jobs*)))
      (expect (null (gethash '(:repository "repo")
                             (nerimux::%workspace-job-labels))))
      (let ((failing (nerimux::%workspace-job-begin :repository "repo" :status object))
            (condition (make-condition 'simple-error
                                       :format-control
                                       "cannot add an fd handler for 1119: not under fd_setsize limit.")))
        (nerimux::%workspace-job-update failing object :failed :outcome condition)
        (let ((label (gethash '(:repository "repo")
                              (nerimux::%workspace-job-labels))))
          (expect (search "status:failed too many open files" label))
          (expect (null (search "fd handler" label)))))))

  (it "workspace-job forgets a failed job on the next refresh and names a write failure plainly"
    (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
           (object (list :repository))
           (create (nerimux::%workspace-job-begin :repository "repo" :create object))
           (status (nerimux::%workspace-job-begin :repository "repo" :status object))
           (condition (make-condition 'simple-error
                                      :format-control "git worktree add failed (exit 255)")))
      (nerimux::%workspace-job-update create object :failed :outcome condition)
      (let ((label (gethash '(:repository "repo") (nerimux::%workspace-job-labels))))
        (expect (search "create:failed failed" label))
        (expect (null (search "read failed" label))))
      (nerimux::%workspace-job-forget-failed)
      (expect (null (gethash '(:repository "repo" :create)
                             nerimux::*workspace-operation-jobs*)))
      (expect (eq status (gethash '(:repository "repo" :status)
                                  nerimux::*workspace-operation-jobs*)))))

  (it "workspace-job labels a plain status or scan failure as a read failure, not history"
    ;; Pre-existing behaviour: :scan and :status were already in the read
    ;; list; only the never-produced :history entry was removed (server-
    ;; multi.lisp %workspace-job-outcome-label), so this documents what the
    ;; surviving list still covers rather than fixing a bug.
    (let ((condition (make-condition 'simple-error :format-control "boom")))
      (expect (string= "read failed"
                       (nerimux::%workspace-job-outcome-label condition :status)))
      (expect (string= "read failed"
                       (nerimux::%workspace-job-outcome-label condition :scan)))
      (expect (string= "failed"
                       (nerimux::%workspace-job-outcome-label condition :create)))))

  (it "workspace-job forget-failed leaves a running job untouched"
    ;; Pre-existing behaviour: %workspace-job-forget-failed only removes
    ;; entries whose state is :failed.
    (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
           (object (list :repository))
           (job (nerimux::%workspace-job-begin :repository "repo" :status object)))
      (nerimux::%workspace-job-update job object :running)
      (nerimux::%workspace-job-forget-failed)
      (expect (eq job (gethash '(:repository "repo" :status)
                               nerimux::*workspace-operation-jobs*)))
      (expect (eq :running (nerimux::workspace-operation-job-state job)))))

  (it "workspace-job catalogue retirement uses object identity not matching ID"
    (multiple-value-bind (organizations organization repository)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore organization))
      (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
             (old (nerimux/workspace-model:make-repository :id (nerimux/workspace-model:repository-id repository)))
             (job (nerimux::%workspace-job-begin :repository (nerimux/workspace-model:repository-id old) :fetch old)))
        (nerimux::%workspace-job-retire-catalog organizations)
        (expect (eq :failed (nerimux::workspace-operation-job-state job)))
        (expect (eq :retired (nerimux::workspace-operation-job-outcome job)))
        (expect (null (nerimux::%workspace-job-update job old :succeeded))))))
  (it "workspace-job scan and status follow actual start and preserve repository errors"
    (multiple-value-bind (organizations organization repository)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore organization))
      (let ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
            (callbacks nil))
        (with-stubbed-fdefinition
            ((nerimux/vcs:refresh-workspace-organizations-async
               (lambda (&rest arguments) (setf callbacks arguments))))
          (nerimux::%workspace-refresh-organizations-async))
        (let ((scan (gethash '(:catalog :all :scan) nerimux::*workspace-operation-jobs*)))
          (expect (eq :queued (nerimux::workspace-operation-job-state scan)))
          (funcall (getf callbacks :on-start))
          (expect (eq :running (nerimux::workspace-operation-job-state scan)))
          (funcall (getf callbacks :on-catalog) organizations)
          (expect (eq :succeeded (nerimux::workspace-operation-job-state scan)))
          (let ((status (gethash (list :repository (nerimux/workspace-model:repository-id repository) :status)
                                nerimux::*workspace-operation-jobs*)))
            (expect (eq :queued (nerimux::workspace-operation-job-state status)))
            (funcall (getf callbacks :on-repository-start) repository)
            (expect (eq :running (nerimux::workspace-operation-job-state status)))
            (funcall (getf callbacks :on-repository-error) repository (make-condition 'error))
            (funcall (getf callbacks :on-complete) organizations)
            (expect (eq :failed (nerimux::workspace-operation-job-state status))))))))
  (it "workspace-job accepted empty organization succeeds while duplicate keeps its active token"
    (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
           (organization (nerimux/workspace-model:make-organization :id "empty"))
           (callbacks nil) (result :unset))
      (with-stubbed-fdefinition
          ((nerimux/vcs:fetch-organization-async
             (lambda (object &rest arguments)
               (declare (ignore object))
               (setf callbacks arguments)
               (funcall (getf arguments :on-accepted)))))
        (nerimux::%workspace-fetch-organization-async organization :on-complete (lambda (value) (setf result value))))
      (let ((job (gethash '(:organization "empty" :fetch) nerimux::*workspace-operation-jobs*)))
        (expect (eq :queued (nerimux::workspace-operation-job-state job)))
        (with-stubbed-fdefinition
            ((nerimux/vcs:fetch-organization-async
               (lambda (object &key on-complete &allow-other-keys)
                 (declare (ignore object)) (funcall on-complete nil))))
          (nerimux::%workspace-fetch-organization-async organization))
        (expect (eq job (gethash '(:organization "empty" :fetch) nerimux::*workspace-operation-jobs*)))
        (expect (eq :queued (nerimux::workspace-operation-job-state job)))
        (funcall (getf callbacks :on-complete) nil)
        (expect (eq organization result))
        (expect (eq :succeeded (nerimux::workspace-operation-job-state job))))))

  (it "workspace-job repository fetch uses the repository operation key"
    (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
           (repository (nerimux/workspace-model:make-repository :id "repo-fetch"))
           (callbacks nil)
           (result nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs:fetch-repository-async
             (lambda (object &rest arguments)
               (expect (eq repository object))
               (setf callbacks arguments)
               (funcall (getf arguments :on-accepted)))))
        (nerimux::%workspace-fetch-repository-async
         repository
         :on-complete (lambda (value) (setf result value))))
      (let ((job (gethash '(:repository "repo-fetch" :fetch)
                          nerimux::*workspace-operation-jobs*)))
        (expect job)
        (expect (eq :queued (nerimux::workspace-operation-job-state job)))
        (funcall (getf callbacks :on-start))
        (expect (eq :running (nerimux::workspace-operation-job-state job)))
        (funcall (getf callbacks :on-complete) nil)
        (expect (eq repository result))
        (expect (eq :succeeded (nerimux::workspace-operation-job-state job)))))))

(describe "workspace-job-org-fetch-error"
  (it "workspace-job-org-fetch-error preserves synchronous condition without inventing a repository"
    (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
           (nerimux::*dirty* nil)
           (organization (nerimux/workspace-model:make-organization :id "sync-error"))
           (original (make-condition 'simple-error :format-control "admission failed"))
           (callbacks nil)
           (observed nil)
           (completed-p nil)
           (caught nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs:fetch-organization-async
             (lambda (object &rest arguments)
               (expect (eq organization object))
               (setf callbacks arguments)
               (funcall (getf arguments :on-accepted))
               (error original))))
        (handler-case
            (nerimux::%workspace-fetch-organization-async
             organization
             :on-error (lambda (repository condition)
                         (push (list (nerimux/workspace-model:repository-id repository)
                                     condition) observed))
             :on-complete (lambda (result)
                            (declare (ignore result))
                            (setf completed-p t)))
          (error (condition) (setf caught condition))))
      (expect (eq original caught))
      (expect (null observed))
      (let ((job (gethash '(:organization "sync-error" :fetch)
                          nerimux::*workspace-operation-jobs*)))
        (expect (eq :failed (nerimux::workspace-operation-job-state job)))
        (expect (eq original (nerimux::workspace-operation-job-outcome job)))
        (funcall (getf callbacks :on-complete) organization)
        (expect (null completed-p))
        (expect (eq :failed (nerimux::workspace-operation-job-state job)))
        (expect (eq original (nerimux::workspace-operation-job-outcome job))))))
  (it "workspace-job-org-fetch-error preserves asynchronous repository arguments and terminal failure"
    (multiple-value-bind (organizations organization repository)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore organizations))
      (let ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (original (make-condition 'simple-error :format-control "fetch failed"))
            (callbacks nil)
            (observed nil)
            (completed-p nil))
        (with-stubbed-fdefinition
            ((nerimux/vcs:fetch-organization-async
               (lambda (object &rest arguments)
                 (expect (eq organization object))
                 (setf callbacks arguments)
                 (funcall (getf arguments :on-accepted)))))
          (nerimux::%workspace-fetch-organization-async
           organization
           :on-error (lambda (current condition)
                       (push (list current condition) observed))
           :on-complete (lambda (result)
                          (declare (ignore result))
                          (setf completed-p t))))
        (funcall (getf callbacks :on-start))
        (funcall (getf callbacks :on-error) repository original)
        (funcall (getf callbacks :on-complete) organization)
        (expect (= 1 (length observed)))
        (expect (eq repository (caar observed)))
        (expect (eq original (cadar observed)))
        (expect (null completed-p))
        (let ((job (gethash (list :organization
                                 (nerimux/workspace-model:organization-id organization)
                                 :fetch)
                           nerimux::*workspace-operation-jobs*)))
          (expect (eq :failed (nerimux::workspace-operation-job-state job)))
          (expect (eq original (nerimux::workspace-operation-job-outcome job))))))))

(describe "workspace-job-org-fetch-error ordering"
  (it "workspace-job-org-fetch-error retains partial failure across a later sibling start and completion"
    (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
           (nerimux::*dirty* nil)
           (repository-a (nerimux/workspace-model:make-repository :id "a"))
           (repository-b (nerimux/workspace-model:make-repository :id "b"))
           (repositories (list repository-a repository-b))
           (organization (nerimux/workspace-model:make-organization
                          :id "partial" :repositories repositories))
           (original (make-condition 'simple-error :format-control "a failed"))
           (callbacks nil)
           (observed nil)
           (completed-p nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs:fetch-organization-async
             (lambda (object &rest arguments)
               (expect (eq organization object))
               (setf callbacks arguments)
               (funcall (getf arguments :on-accepted)))))
        (nerimux::%workspace-fetch-organization-async
         organization
         :on-error (lambda (repository condition)
                     (push (list repository condition) observed))
         :on-complete (lambda (result)
                        (declare (ignore result))
                        (setf completed-p t))))
      (let ((job (gethash '(:organization "partial" :fetch)
                          nerimux::*workspace-operation-jobs*)))
        (funcall (getf callbacks :on-start))
        (expect (eq :running (nerimux::workspace-operation-job-state job)))
        (funcall (getf callbacks :on-error) repository-a original)
        (funcall (getf callbacks :on-start))
        (expect (eq :failed (nerimux::workspace-operation-job-state job)))
        (expect (eq original (nerimux::workspace-operation-job-outcome job)))
        (funcall (getf callbacks :on-complete) repositories)
        (expect (= 1 (length observed)))
        (expect (eq repository-a (caar observed)))
        (expect (eq original (cadar observed)))
        (expect (null completed-p))
        (expect (eq :failed (nerimux::workspace-operation-job-state job)))
        (expect (eq original (nerimux::workspace-operation-job-outcome job))))))
  (it "workspace-job-org-fetch-error before acceptance neither creates nor changes a job"
    (dolist (existing-p '(nil t))
      (let* ((nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
             (nerimux::*dirty* nil)
             (organization (nerimux/workspace-model:make-organization :id "before-accept"))
             (existing (when existing-p
                         (nerimux::%workspace-job-begin :organization "before-accept"
                                                       :fetch organization)))
             (original (make-condition 'simple-error :format-control "admission unavailable"))
             (caught nil)
             (observed nil))
        (when existing
          (nerimux::%workspace-job-update existing organization :running :outcome :prior))
        (setf nerimux::*dirty* nil)
        (with-stubbed-fdefinition
            ((nerimux/vcs:fetch-organization-async
               (lambda (object &rest arguments)
                 (declare (ignore arguments))
                 (expect (eq organization object))
                 (error original))))
          (handler-case
              (nerimux::%workspace-fetch-organization-async
               organization
               :on-error (lambda (repository condition)
                           (push (list repository condition) observed)))
            (error (condition) (setf caught condition))))
        (expect (eq original caught))
        (expect (null observed))
        (expect (null nerimux::*dirty*))
        (expect (= (if existing-p 1 0) (hash-table-count nerimux::*workspace-operation-jobs*)))
        (expect (eq existing (gethash '(:organization "before-accept" :fetch)
                                      nerimux::*workspace-operation-jobs*)))
        (when existing
          (expect (eq :running (nerimux::workspace-operation-job-state existing)))
          (expect (eq :prior (nerimux::workspace-operation-job-outcome existing))))))))

(describe "workspace-catalog-refresh-state-suite"

  (it "mark-then-settle-clears-the-refreshing-mark"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let* ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal)))
        (nerimux::%set-workspace-catalog-refresh-state organizations :mark)
        (expect (plusp (hash-table-count nerimux::*workspace-refreshing-ids*)))
        (nerimux::%set-workspace-catalog-refresh-state organizations :settle)
        (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
        (expect (zerop (hash-table-count nerimux::*workspace-stale-ids*))))))

  (it "settle-with-stale-p-moves-the-node-to-the-stale-set"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal)))
        (nerimux::%set-workspace-catalog-refresh-state organizations :mark)
        (nerimux::%set-workspace-catalog-refresh-state organizations :settle :stale-p t)
        (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
        (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*))))))

  (it "refresh-client-picker-on-complete-settles-refreshing-ids-not-re-marks-them"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* 7)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
            (conn (nerimux::%make-client-conn))
            (captured-on-complete nil)
            (completed-organizations nil))
        (setf nerimux::*clients* (list conn))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key query on-catalog on-complete on-error
                                on-repository-error on-progress callback-dispatch &allow-other-keys)
                       (declare (ignore query on-error on-repository-error
                                        on-progress callback-dispatch))
                       (setf captured-on-complete on-complete)
                       (when on-catalog (funcall on-catalog organizations))))
               (nerimux::%refresh-client-picker
                conn :on-complete (lambda (value)
                                    (setf completed-organizations value)))
               (expect (plusp (hash-table-count nerimux::*workspace-refreshing-ids*)))
               (expect (null nerimux::*workspace-scan-progress*))
               (expect (null nerimux::*workspace-catalog-loaded-p*))
               (expect captured-on-complete)
               (funcall captured-on-complete organizations)
               (expect nerimux::*workspace-catalog-loaded-p*)
               (expect (null nerimux::*workspace-scan-progress*))
               (expect (eq organizations completed-organizations))
               (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  (it "refresh-client-picker-builds-items-without-vcs"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (conn (nerimux::%make-client-conn))
            (completed nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () nil))
               (nerimux::%refresh-client-picker
                conn :on-complete
                (lambda (received)
                  (setf completed received)))
               (expect (equal organizations completed))
               (expect (equal (length (nerimux/picker:build-global-picker-items
                                       organizations))
                              (length (nerimux::client-conn-picker-items conn)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available)))))

  (it "refresh-client-picker-settles-a-synchronous-startup-error"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let* ((nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* 7)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
            (conn (nerimux::%make-client-conn))
            (nerimux::*clients* (list conn))
            (received-error nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (error "synthetic picker startup failure")))
               (nerimux::%refresh-client-picker
                conn :on-error
                (lambda (condition)
                  (setf received-error condition)))
               (expect (typep received-error 'error))
               (expect nerimux::*workspace-catalog-loaded-p*)
               (expect (null nerimux::*workspace-scan-progress*))
               (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
               (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  (it "refresh-client-picker-reports-a-live-asynchronous-error"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let* ((nerimux::*workspace-catalog-loaded-p* nil)
             (nerimux::*workspace-scan-progress* 7)
             (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
             (nerimux::*dirty* nil)
             (nerimux/vcs::*workspace-organizations* organizations)
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
             (conn (nerimux::%make-client-conn))
             (nerimux::*clients* (list conn))
             (captured-on-error nil)
             (received-error nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key on-error &allow-other-keys)
                       (setf captured-on-error on-error)))
               (nerimux::%refresh-client-picker
                conn :on-error (lambda (condition)
                                 (setf received-error condition)))
               (expect captured-on-error)
               (expect (null nerimux::*workspace-scan-progress*))
               (expect (null nerimux::*workspace-catalog-loaded-p*))
               (funcall captured-on-error (make-condition 'error))
               (expect (typep received-error 'error))
               (expect nerimux::*workspace-catalog-loaded-p*)
               (expect (null nerimux::*workspace-scan-progress*))
               (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
               (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  (it "add-client-on-progress-callback-updates-workspace-scan-progress"
    (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
          (nerimux::*workspace-catalog-loaded-p* nil)
          (nerimux::*workspace-scan-progress* nil)
          (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
          (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
          (nerimux::*clients* nil)
          (nerimux::*dirty* nil)
          (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
          (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
          (captured-on-progress nil))
      (unwind-protect
           (with-test-listener (listener path (%test-socket-path "add-client-on-progress")
                                          :backlog 4)
             (let ((client nil)
                   (server-sock nil))
               (unwind-protect
                    (progn
                      (setf client (nerimux/net:connect-to path)
                            server-sock (nerimux/net:accept-connection listener))
                      (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                            (lambda () t)
                            (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                            (lambda (&key query on-catalog on-complete on-error
                                       on-repository-error on-progress callback-dispatch &allow-other-keys)
                              (declare (ignore query on-catalog on-complete on-error
                                               on-repository-error callback-dispatch))
                              (setf captured-on-progress on-progress)))
                      (when server-sock
                        (nerimux::%add-client server-sock)))
                 (when client (ignore-errors (nerimux/net:close-socket client)))
                 (when server-sock (ignore-errors (nerimux/net:close-socket server-sock))))))
        (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
              (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async) refresh-fn))
      (expect captured-on-progress)
      (funcall captured-on-progress 7)
      (expect (eql 7 nerimux::*workspace-scan-progress*))))

  (it "add-client-refresh-callbacks-settle-and-rebind-live-clients"
    (multiple-value-bind (organizations organization repository)
        (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
            (nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* nil)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
            (captured nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key on-catalog on-complete on-error on-repository-error
                                on-progress callback-dispatch &allow-other-keys)
                       (declare (ignore callback-dispatch))
                       (setf captured (list on-catalog on-complete on-error
                                            on-repository-error on-progress))))
               (with-stubbed-fdefinition
                   ((nerimux/net:socket-stream
                      (lambda (socket)
                        (declare (ignore socket))
                        (make-two-way-stream
                         (make-string-input-stream "")
                         (make-string-output-stream))))
                    (nerimux/net:socket-fd (lambda (socket)
                                             (declare (ignore socket))
                                             1))
                    (nerimux/net:close-socket (lambda (&rest args)
                                                (declare (ignore args)))))
                 (let ((conn (nerimux::%add-client :socket)))
                   (expect conn)
                   (expect captured)
                   (funcall (fifth captured) 3)
                   (funcall (first captured) organizations)
                   (funcall (fourth captured) repository (make-condition 'error))
                   (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*)))
                   (funcall (second captured) organizations)
                   (expect nerimux::*workspace-catalog-loaded-p*)
                   (expect (null nerimux::*workspace-scan-progress*))
                   (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
                   (expect (member organization
                                   (nerimux::client-conn-picker-items conn)
                                   :key #'nerimux/picker:picker-item-organization)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  (it "add-client-does-not-start-refresh-without-vcs"
    (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
          (nerimux::*workspace-catalog-loaded-p* nil)
          (nerimux::*clients* nil)
          (nerimux::*dirty* nil)
          (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
          (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
          (refresh-started nil))
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                   (lambda () nil)
                   (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (setf refresh-started t)))
             (with-stubbed-fdefinition
                 ((nerimux/net:socket-stream
                    (lambda (socket)
                      (declare (ignore socket))
                      (make-two-way-stream
                       (make-string-input-stream "")
                       (make-string-output-stream))))
                  (nerimux/net:socket-fd
                    (lambda (socket)
                      (declare (ignore socket))
                      1)))
               (let ((conn (nerimux::%add-client :socket)))
                 (expect conn)
                 (expect (null refresh-started))
                 (expect (null nerimux::*workspace-catalog-refresh-started-p*))
                 (expect (null nerimux::*workspace-catalog-loaded-p*))
                 (expect (member conn nerimux::*clients*)))))
        (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
              (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
              refresh-fn))))

  (it "add-client-synchronous-refresh-failure-settles-the-catalog-as-stale"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
            (nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* 3)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&rest args)
                       (declare (ignore args))
                       (error "synchronous refresh startup failure")))
               (with-stubbed-fdefinition
                   ((nerimux/net:socket-stream (lambda (socket)
                                                 (declare (ignore socket))
                                                 (make-two-way-stream
                                                  (make-string-input-stream "")
                                                  (make-string-output-stream))))
                    (nerimux/net:socket-fd (lambda (socket)
                                             (declare (ignore socket))
                                             1))
                    (nerimux/net:close-socket (lambda (&rest args)
                                                (declare (ignore args)))))
                 (let ((conn (nerimux::%add-client :socket)))
                   (expect conn)
                   (expect nerimux::*workspace-catalog-loaded-p*)
                   (expect (null nerimux::*workspace-scan-progress*))
                   (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
                   (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*))))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  (it "add-client-wrapper-refresh-failure-settles-the-catalog-as-stale"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
            (nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* 5)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations))
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () t))
             (nerimux::%workspace-refresh-organizations-async
               (lambda (&rest args)
                 (declare (ignore args))
                 (error "wrapper refresh failure")))
             (nerimux/net:socket-stream
               (lambda (socket)
                 (declare (ignore socket))
                 (make-two-way-stream
                  (make-string-input-stream "")
                  (make-string-output-stream))))
             (nerimux/net:socket-fd
               (lambda (socket)
                 (declare (ignore socket))
                 1))
             (nerimux/net:close-socket
               (lambda (&rest args)
                 (declare (ignore args)))))
          (let ((conn (nerimux::%add-client :socket)))
            (expect conn)
            (expect nerimux::*workspace-catalog-loaded-p*)
            (expect (null nerimux::*workspace-scan-progress*))
            (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
            (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*))))))))

  (it "add-client-terminal-refresh-error-settles-the-catalog-as-stale"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
            (nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* 4)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
            (captured-on-error nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key on-error &allow-other-keys)
                       (setf captured-on-error on-error)))
               (with-stubbed-fdefinition
                   ((nerimux/net:socket-stream
                      (lambda (socket)
                        (declare (ignore socket))
                        (make-two-way-stream
                         (make-string-input-stream "")
                         (make-string-output-stream))))
                    (nerimux/net:socket-fd
                      (lambda (socket)
                        (declare (ignore socket))
                        1))
                    (nerimux/net:close-socket
                      (lambda (&rest args)
                        (declare (ignore args)))))
                 (let ((conn (nerimux::%add-client :socket)))
                   (expect conn)
                   (expect captured-on-error)
                   (expect (plusp (hash-table-count nerimux::*workspace-refreshing-ids*)))
                   (funcall captured-on-error (make-condition 'error))
                   (expect nerimux::*workspace-catalog-loaded-p*)
                   (expect (null nerimux::*workspace-scan-progress*))
                   (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
                   (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn))))))

  (it "drop-client-ignores-stream-errors-while-sending-bye"
    (let* ((stream (make-two-way-stream
                    (make-string-input-stream "")
                    (make-string-output-stream)))
           (conn (nerimux::%make-client-conn :stream stream))
           (nerimux::*clients* (list conn)))
      (with-stubbed-fdefinition
          ((nerimux/transport:send-frame
            (lambda (&rest args)
              (declare (ignore args))
              (error 'stream-error :stream stream))))
        (nerimux::%drop-client conn :bye t))
      (expect (null nerimux::*clients*)))))
