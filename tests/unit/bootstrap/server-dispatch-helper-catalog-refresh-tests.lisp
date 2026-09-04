(in-package #:nerimux/test)

(describe "server-dispatch-helper-catalog-refresh-suite"
  (it "settles a failed workspace catalog refresh as stale"
    (let ((nerimux::*workspace-catalog-loaded-p* nil)
          (nerimux::*workspace-scan-progress* 3)
          (dirty-count 0)
          (refresh-state nil))
      (with-stubbed-fdefinition
          ((nerimux::%set-workspace-catalog-refresh-state
             (lambda (organizations phase &key stale-p)
               (setf refresh-state (list organizations phase stale-p))))
           (nerimux::%mark-dirty
             (lambda () (incf dirty-count))))
        (nerimux::%settle-workspace-catalog-after-error
         (make-condition 'simple-error :format-control "offline")))
      (expect nerimux::*workspace-catalog-loaded-p*)
      (expect (null nerimux::*workspace-scan-progress*))
      (expect (equal (list (nerimux/vcs:workspace-organizations) :settle t)
                     refresh-state))
      (expect (= 1 dirty-count)))))
