(in-package #:nerimux/test)

(describe "server-dispatch-helper-refresh-suite"
  (it "settles asynchronous refreshes when startup fails synchronously"
    (let* ((worktree (nerimux/workspace-model:make-worktree
                      :id "refresh" :path "/tmp/refresh" :branch "main"))
           (dirty-count 0)
           (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal)))
      (with-stubbed-fdefinition
          ((nerimux/vcs:refresh-worktree-commits-async
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "thread unavailable")))
           (nerimux/vcs:refresh-worktree-file-diff-async
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "thread unavailable")))
           (nerimux::%mark-dirty (lambda () (incf dirty-count))))
        (nerimux::%client-start-worktree-commits-refresh worktree)
        (nerimux::%client-start-worktree-file-diff-refresh worktree "README.md")
        (expect (eq :failed
                    (nerimux/workspace-model:worktree-commits-state worktree)))
        (expect (equal (list :failed 0 nil)
                       (gethash (list "refresh" "README.md")
                                nerimux::*workspace-file-diffs*)))
        (expect (= 2 dirty-count)))))

  (it "settles asynchronous refreshes when workers report errors through CPS"
    (let* ((worktree (nerimux/workspace-model:make-worktree
                      :id "callback-refresh" :path "/tmp/callback-refresh"
                      :branch "main"))
           (dirty-count 0)
           (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal)))
      (with-stubbed-fdefinition
          ((nerimux/vcs:refresh-worktree-commits-async
           (lambda (&rest arguments)
               (funcall (getf (cddr arguments) :callback-dispatch)
                        (lambda ()
                          (funcall (getf (cddr arguments) :on-error)
                                   (make-condition 'simple-error
                                                   :format-control "commit worker failed"))))))
           (nerimux/vcs:refresh-worktree-file-diff-async
             (lambda (&rest arguments)
               (funcall (getf (cdddr arguments) :callback-dispatch)
                        (lambda ()
                          (funcall (getf (cdddr arguments) :on-error)
                                   (make-condition 'simple-error
                                                   :format-control "diff worker failed"))))))
           (nerimux::%enqueue-main-thread-callback
             (lambda (thunk) (funcall thunk)))
           (nerimux::%mark-dirty (lambda () (incf dirty-count))))
        (nerimux::%client-start-worktree-commits-refresh worktree)
        (nerimux::%client-start-worktree-file-diff-refresh
         worktree "README.md")
        (expect (= 2 dirty-count))
        (expect (equal (list :failed 0 nil)
                       (gethash (list "callback-refresh" "README.md")
                                nerimux::*workspace-file-diffs*))))))

  (it "stores successful and unsuccessful file diff results from CPS"
    (let* ((worktree (nerimux/workspace-model:make-worktree
                      :id "callback-results" :path "/tmp/callback-results"
                      :branch "main"))
           (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
           (nerimux::*dirty* nil)
           (results (list (list :ready 7 "+added" "-removed")
                          (list :unexpected 0 nil))))
      (with-stubbed-fdefinition
          ((nerimux/vcs:refresh-worktree-file-diff-async
             (lambda (&rest arguments)
               (let ((on-complete (getf (cdddr arguments) :on-complete)))
                 (funcall on-complete (pop results)))))
           (nerimux::%mark-dirty (lambda () (setf nerimux::*dirty* t))))
        (nerimux::%client-start-worktree-file-diff-refresh
         worktree "README.md")
        (nerimux::%client-start-worktree-file-diff-refresh
         worktree "CHANGELOG.md")
        (expect (equal (list :ready 7 (list "+added" "-removed"))
                       (gethash (list "callback-results" "README.md")
                                nerimux::*workspace-file-diffs*)))
        (expect (equal (list :failed 0 nil)
                       (gethash (list "callback-results" "CHANGELOG.md")
                                nerimux::*workspace-file-diffs*)))
        (expect nerimux::*dirty*))))

  )
