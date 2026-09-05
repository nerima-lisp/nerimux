(in-package #:nerimux/test)

(describe "server-dispatch-helper-status-suite"
  (it "status-write-reports-transient-write-errors"
    (let ((conn (nerimux::%make-client-conn))
          (notifications nil))
      (with-stubbed-fdefinition
          ((nerimux::%run-transient-git-write
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "write failed")))
           (nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message notifications))))
        (expect (nerimux::%client-run-status-write
                 conn :repository :stage '("--" "file")))
        (expect (= 1 (length notifications)))
        (expect (search "git stage: failed:" (first notifications))))))

  (it "status-write-reports-missing-repository"
    (let ((conn (nerimux::%make-client-conn))
          (notifications nil))
      (with-stubbed-fdefinition
          ((nerimux::%run-transient-git-write
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "write should not run")))
           (nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message notifications))))
        (expect (nerimux::%client-run-status-write
                 conn nil :stage '("--" "file")))
        (expect (equal '("no repository selected") notifications))))))
