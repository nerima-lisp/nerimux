(in-package #:nerimux/test/vcs)

(describe "vcs clone path boundaries"
          (it
           "rejects an owner symlink that redirects the ghq destination outside its root"
           (let* ((base (%fresh-clone-fixture-directory))
                  (root (merge-pathnames "ghq-root/" base))
                  (host-directory (merge-pathnames "github.com/" root))
                  (outside-directory (merge-pathnames "outside/" base))
                  (owner-link (merge-pathnames "owner" host-directory))
                  (run-called-p nil))
             (unwind-protect
                 (progn
                   (ensure-directories-exist host-directory)
                   (ensure-directories-exist outside-directory)
                   (sb-posix:symlink (namestring outside-directory)
                                     (namestring owner-link))
                   (with-stubbed-fdefinition
                    ((nerimux/vcs::%run-ghq-get
                      (lambda (arguments environment)
                        (declare (ignore arguments environment))
                        (setf run-called-p t)
                        (values "" "" 0))))
                    (multiple-value-bind (result condition)
                        (%clone-attempt "https://github.com/owner/repository"
                                        (namestring root)
                                        (sb-ext:posix-environ))
                      (expect (null result))
                      (expect condition)
                      (expect
                       (search "escapes"
                               (nerimux/vcs:clone-error-reason condition)))
                      (expect (not run-called-p)))))
               (when (probe-file base)
                 (uiop:delete-directory-tree base :validate t))))))
