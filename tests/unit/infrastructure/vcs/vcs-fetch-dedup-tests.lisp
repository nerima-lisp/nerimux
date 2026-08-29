(in-package #:nerimux/test)

;;;; Direct unit tests for FETCH-REPOSITORY-ASYNC / FETCH-ORGANIZATION-ASYNC's
;;;; duplicate-fetch suppression in vcs-fetch.lisp, the R7.1 requirement:
;;;; "進行中の同一対象への重複実行を抑止する" (a fetch already running for a
;;;; target is not started again).
;;;;
;;;; *IN-PROGRESS-FETCHES* + *FETCH-LOCK* implement this: %FETCH-BEGIN claims
;;;; a (:repository id) or (:organization id) key and returns T only if it
;;;; was not already claimed; a call made while a fetch is in flight for the
;;;; same key invokes its ON-COMPLETE immediately with NIL and starts no
;;;; thread at all -- the in-flight fetch's own callback is the one that
;;;; eventually reports the real result. These tests replace the direct
;;;; VCS-KIT:VCS-FETCH boundary so the first fetch can be held open long enough
;;;; for a second call to observe it in flight.
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
          (vcs-kit:vcs-fetch
            (%delayed-vcs-fetch ,call-log ,delay)))
       ,@body)))

(defun %poll-until (predicate &key (timeout-seconds 2.0))
  "Poll PREDICATE every 10ms until it returns true or TIMEOUT-SECONDS elapses.
   Returns the predicate's final value."
  (let ((deadline (+ (get-internal-real-time)
                     (round (* timeout-seconds internal-time-units-per-second)))))
    (loop for result = (funcall predicate)
          when result return result
          while (< (get-internal-real-time) deadline)
          do (sleep 0.01)
          finally (return (funcall predicate)))))

(describe "renderer-suite/vcs-fetch-dedup-repository"

  ;; R7.1: a fetch issued for a repository while an earlier fetch for the
  ;; SAME repository is still running does not start a second real fetch --
  ;; its ON-COMPLETE fires immediately with NIL, and the in-flight fetch is
  ;; the only one that ever calls VCS-KIT:VCS-FETCH.
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
        ;; Issued while the first fetch is still sleeping inside the mock.
        (nerimux/vcs:fetch-repository-async
         repository
         :on-complete (lambda (result) (setf second-result result)))
        ;; The duplicate's callback must have already fired -- %FETCH-BEGIN
        ;; is checked synchronously in the caller's own thread before any
        ;; worker is spawned, so this needs no polling at all.
        (expect (null second-result))
        (expect (eq :pending first-result))
        ;; Now wait for the real (first) fetch to finish.
        (expect (%poll-until (lambda () (not (eq :pending first-result)))))
        (expect (eq repository first-result))
        ;; Exactly one real VCS-FETCH call happened -- the duplicate never
        ;; reached VCS-KIT:VCS-FETCH at all.
        (expect (= 1 (length (cdr call-log))))))))

(describe "renderer-suite/vcs-fetch-dedup-repository-recovery"

  ;; Once the in-flight fetch completes, the key is released
  ;; (%FETCH-END, called from the completion callback) -- a later fetch for
  ;; the same repository is not suppressed and actually runs.
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

  (it "holds the repository key through error notification and releases it on completion"
    (let* ((repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/dedup-repo-failure"
              :local-path "/tmp/nerimux-fetch-dedup-repo-failure"))
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
        (nerimux/vcs:fetch-repository-async
         repository
         :on-error (lambda (condition)
                     (setf first-error condition)
                     (nerimux/vcs:fetch-repository-async
                      repository
                      :on-error (lambda (duplicate-condition)
                                  (setf duplicate-error duplicate-condition))
                      :on-complete (lambda (result)
                                     (setf duplicate-result result))))
         :on-complete (lambda (result)
                        (declare (ignore result))
                        (setf first-complete t)))
        (expect (%poll-until (lambda () first-complete)))
        (expect first-error)
        (expect (null duplicate-result))
        (expect (null duplicate-error))
        (expect (= 1 attempts))
        (nerimux/vcs:fetch-repository-async
         repository
         :on-error (lambda (condition)
                     (setf second-error condition))
         :on-complete (lambda (result)
                        (declare (ignore result))
                        (setf second-complete t)))
        (expect (%poll-until (lambda () second-complete)))
        (expect second-error)
        (expect (= 2 attempts))))))

(describe "renderer-suite/vcs-fetch-dedup-organization"

  ;; R7.1's other target: C-q C-f fetches every repository under an
  ;; organization. The dedup key is (:organization id), independent from the
  ;; (:repository id) key above -- a repository-level and an
  ;; organization-level fetch of the same underlying repository do not
  ;; collide with each other's in-progress marker.
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
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/dedup-org-failure"
              :local-path "/tmp/nerimux-fetch-dedup-org-failure"))
           (organization
             (nerimux/workspace-model:make-organization
              :host "workspace-owner" :name "dedup-org-failure"
              :repositories (list repository)))
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
        (nerimux/vcs:fetch-organization-async
         organization
         :on-error (lambda (failed-repository condition)
                     (declare (ignore failed-repository))
                     (setf first-error condition))
         :on-complete (lambda (repositories)
                        (declare (ignore repositories))
                        (setf first-complete t)))
        (expect (%poll-until (lambda () first-complete)))
        (expect first-error)
        (nerimux/vcs:fetch-organization-async
         organization
         :on-error (lambda (failed-repository condition)
                     (declare (ignore failed-repository))
                     (setf second-error condition))
         :on-complete (lambda (repositories)
                        (declare (ignore repositories))
                        (setf second-complete t)))
        (expect (%poll-until (lambda () second-complete)))
        (expect second-error)
        (expect (= 2 attempts))))))
