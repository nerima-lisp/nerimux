(in-package #:nerimux/test/vcs)

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
      ((vcs-kit:make-vcs-repository
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
              ((vcs-kit:vcs-fetch
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
                 ((vcs-kit:vcs-fetch
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
