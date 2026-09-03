(in-package #:nerimux/test/vcs)

(defun %inspect-fake-commit (id message)
  (vcs-kit::%make-vcs-commit :id id :message message))

(describe "vcs worktree commits (refresh-worktree-commits-async)"
  (it "%read-worktree-commits shortens the hash to 7 characters and keeps only the subject line"
    (let ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt-inspect" :path "/tmp/nerimux-inspect-commits")))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (directory &rest arguments)
               (declare (ignore arguments))
               directory))
           (vcs-kit:vcs-list-commits
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (list (%inspect-fake-commit
                      "0123456789abcdef0123456789abcdef01234567"
                      (format nil "fix a bug~%~%longer body text"))
                     (%inspect-fake-commit "fedcba9" "add a feature")))))
        (let ((commits (nerimux/vcs::%read-worktree-commits worktree)))
          (expect (= 2 (length commits)))
          (expect (string= "0123456" (car (first commits))))
          (expect (string= "fix a bug" (cdr (first commits))))
          (expect (string= "fedcba9" (car (second commits))))
          (expect (string= "add a feature" (cdr (second commits))))))))

  (it "%read-worktree-commits passes a --max-count argument bounding the log"
    (let ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt-inspect-limit" :path "/tmp/nerimux-inspect-limit"))
          (captured-arguments nil))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (directory &rest arguments)
               (declare (ignore arguments))
               directory))
           (vcs-kit:vcs-list-commits
             (lambda (repository &key arguments &allow-other-keys)
               (declare (ignore repository))
               (setf captured-arguments arguments)
               nil)))
        (nerimux/vcs::%read-worktree-commits worktree)
        (expect (member (format nil "--max-count=~D"
                                nerimux/vcs::*worktree-commit-log-limit*)
                        captured-arguments :test #'string=)))))

  (it "settles :ready and writes both slots through the callback dispatcher"
    (let ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt-inspect-async" :path "/tmp/nerimux-inspect-async"))
          (queued nil)
          (completed nil))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (directory &rest arguments)
               (declare (ignore arguments))
               directory))
           (vcs-kit:vcs-list-commits
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (list (%inspect-fake-commit "abc1234" "one commit")))))
        (let ((thread
                (nerimux/vcs:refresh-worktree-commits-async
                 nil worktree
                 :callback-dispatch (lambda (callback) (push callback queued))
                 :on-complete (lambda (result) (setf completed result)))))
          (cl-concurrent-kit:join-thread thread :timeout 2)
          (expect (null (nerimux/workspace-model:worktree-commits-state worktree)))
          (expect (= 1 (length queued)))
          (funcall (pop queued))
          (expect (eq :ready (nerimux/workspace-model:worktree-commits-state worktree)))
          (expect (equal (list (cons "abc1234" "one commit"))
                         (nerimux/workspace-model:worktree-recent-commits worktree)))
          (expect (eq worktree completed))))))

  (it "%split-diff-lines drops the trailing newline-terminated empty segment"
    (expect (equal '("line1" "line2")
                   (nerimux/vcs::%split-diff-lines
                    (format nil "line1~%line2~%"))))
    (expect (equal '("line1" "line2")
                   (nerimux/vcs::%split-diff-lines
                    (format nil "line1~%line2"))))
    (expect (null (nerimux/vcs::%split-diff-lines ""))))

  (it "settles :failed and clears recent-commits when the worker signals"
    (let ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt-inspect-failed" :path "/tmp/nerimux-inspect-failed"
                      :recent-commits (list (cons "stale12" "stale commit")))))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "no such repository")))
           (vcs-kit:vcs-list-commits
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "must not be reached"))))
        (let ((thread
                (nerimux/vcs:refresh-worktree-commits-async
                 nil worktree
                 :callback-dispatch (lambda (callback) (funcall callback)))))
          (cl-concurrent-kit:join-thread thread :timeout 2)
          (expect (eq :failed (nerimux/workspace-model:worktree-commits-state worktree)))
          (expect (null (nerimux/workspace-model:worktree-recent-commits worktree))))))))

(defun %inspect-fake-diff-result (stdout)
  (process-kit:make-process-result :stdout stdout))

(describe "vcs worktree file diff (refresh-worktree-file-diff-async)"
  (it "%read-worktree-file-diff returns the full count and the raw lines under the cap"
    (let ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt-diff" :path "/tmp/nerimux-inspect-diff")))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (directory &rest arguments)
               (declare (ignore arguments))
               directory))
           (vcs-kit:vcs-diff
             (lambda (repository &rest arguments)
               (declare (ignore repository arguments))
               (%inspect-fake-diff-result
                (format nil "@@ -1,2 +1,2 @@~%-old line~%+new line~%")))))
        (let ((diff (nerimux/vcs::%read-worktree-file-diff worktree "src/foo.lisp")))
          (expect (= 3 (car diff)))
          (expect (equal '("@@ -1,2 +1,2 @@" "-old line" "+new line") (cdr diff)))))))

  (it "%read-worktree-file-diff passes -- PATH and a max-output-characters execution option (F3a)"
    (let ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt-diff-args" :path "/tmp/nerimux-inspect-diff-args"))
          (captured-arguments nil))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (directory &rest arguments)
               (declare (ignore arguments))
               directory))
           (vcs-kit:vcs-diff
             (lambda (repository &rest arguments)
               (declare (ignore repository))
               (setf captured-arguments arguments)
               (%inspect-fake-diff-result ""))))
        (nerimux/vcs::%read-worktree-file-diff worktree "src/bar.lisp")
        (expect (equal (list "--no-ext-diff" "--no-color" "--" "src/bar.lisp")
                       (butlast captured-arguments 2)))
        (expect (equal (list :execution-options
                             (list :max-output-characters
                                   nerimux/vcs::*worktree-diff-max-output-characters*))
                       (last captured-arguments 2))))))

  (it "%read-worktree-file-diff passes --no-ext-diff and --no-color before -- (BUG-1)"
    (let ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt-diff-no-ext" :path "/tmp/nerimux-inspect-diff-no-ext"))
          (captured-arguments nil))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (directory &rest arguments)
               (declare (ignore arguments))
               directory))
           (vcs-kit:vcs-diff
             (lambda (repository &rest arguments)
               (declare (ignore repository))
               (setf captured-arguments arguments)
               (%inspect-fake-diff-result ""))))
        (nerimux/vcs::%read-worktree-file-diff worktree "src/baz.lisp")
        (let ((no-ext-diff-position (position "--no-ext-diff" captured-arguments :test #'equal))
              (no-color-position (position "--no-color" captured-arguments :test #'equal))
              (separator-position (position "--" captured-arguments :test #'equal)))
          (expect no-ext-diff-position)
          (expect no-color-position)
          (expect separator-position)
          (expect (< no-ext-diff-position separator-position))
          (expect (< no-color-position separator-position))))))

  (it "%read-worktree-file-diff caps the returned lines at *worktree-diff-line-limit* but keeps the true total"
    (let* ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt-diff-cap" :path "/tmp/nerimux-inspect-diff-cap"))
           (raw-lines (loop for i from 1 to 250 collect (format nil "line ~D" i)))
           (stdout (format nil "~{~A~%~}" raw-lines)))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (directory &rest arguments)
               (declare (ignore arguments))
               directory))
           (vcs-kit:vcs-diff
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (%inspect-fake-diff-result stdout))))
        (let ((diff (nerimux/vcs::%read-worktree-file-diff worktree "src/big.lisp")))
          (expect (= 250 (car diff)))
          (expect (= nerimux/vcs::*worktree-diff-line-limit* (length (cdr diff))))
          (expect (string= "line 1" (first (cdr diff))))
          (expect (string= "line 200" (car (last (cdr diff)))))))))

  (it "settles :ready with total and capped lines through the callback dispatcher"
    (let ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt-diff-async" :path "/tmp/nerimux-inspect-diff-async"))
          (queued nil)
          (completed nil))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (directory &rest arguments)
               (declare (ignore arguments))
               directory))
           (vcs-kit:vcs-diff
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (%inspect-fake-diff-result (format nil "+only line~%")))))
        (let ((thread
                (nerimux/vcs:refresh-worktree-file-diff-async
                 nil worktree "src/foo.lisp"
                 :callback-dispatch (lambda (callback) (push callback queued))
                 :on-complete (lambda (result) (setf completed result)))))
          (cl-concurrent-kit:join-thread thread :timeout 2)
          (expect (null completed))
          (expect (= 1 (length queued)))
          (funcall (pop queued))
          (expect (equal (list :ready 1 "+only line") completed))))))

  (it "settles :failed when the worker signals"
    (let ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt-diff-failed" :path "/tmp/nerimux-inspect-diff-failed")))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "no such repository")))
           (vcs-kit:vcs-diff
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "must not be reached"))))
        (let ((completed :untouched))
          (let ((thread
                  (nerimux/vcs:refresh-worktree-file-diff-async
                   nil worktree "src/foo.lisp"
                   :callback-dispatch (lambda (callback) (funcall callback))
                   :on-complete (lambda (result) (setf completed result)))))
            (cl-concurrent-kit:join-thread thread :timeout 2)
            (expect (equal (list :failed) completed))))))))

(describe "vcs worktree diff line content limits (F3b/F5)"
          (it
           "truncates a single long retained line to *worktree-text-max-characters*"
           (let ((worktree
                  (nerimux/workspace-model:make-worktree :id
                                                         "wt-diff-line-cap"
                                                         :path
                                                         "/tmp/nerimux-inspect-diff-line-cap"))
                 (long-line (make-string 10000 :initial-element #\a)))
             (with-stubbed-fdefinition
              ((vcs-kit:make-vcs-repository
                (lambda (directory &rest arguments)
                  (declare (ignore arguments))
                  directory))
               (vcs-kit:vcs-diff
                (lambda (&rest arguments)
                  (declare (ignore arguments))
                  (%inspect-fake-diff-result (format nil "~A~%" long-line)))))
              (let ((diff
                     (nerimux/vcs::%read-worktree-file-diff worktree
                                                            "src/big-line.lisp")))
                (expect (= 1 (length (cdr diff))))
                (expect
                 (= nerimux/vcs::*worktree-text-max-characters*
                    (length (first (cdr diff)))))
                (expect
                 (string=
                  (subseq long-line
                          0
                          nerimux/vcs::*worktree-text-max-characters*)
                  (first (cdr diff))))))))
          (it
           "drops an ESC byte from a retained diff line, matching the finding's own example"
           (let ((worktree
                  (nerimux/workspace-model:make-worktree :id
                                                         "wt-diff-esc"
                                                         :path
                                                         "/tmp/nerimux-inspect-diff-esc")))
             (with-stubbed-fdefinition
              ((vcs-kit:make-vcs-repository
                (lambda (directory &rest arguments)
                  (declare (ignore arguments))
                  directory))
               (vcs-kit:vcs-diff
                (lambda (&rest arguments)
                  (declare (ignore arguments))
                  (%inspect-fake-diff-result
                   (format nil "a~C[31mb~%" (code-char 27))))))
              (let ((diff
                     (nerimux/vcs::%read-worktree-file-diff worktree
                                                            "src/esc.lisp")))
                (expect (string= "a[31mb" (first (cdr diff))))
                (expect
                 (notany
                  (lambda (character)
                    (< (char-code character) 32))
                  (first (cdr diff))))))))
          (it "turns Tab into a single space while dropping other C0 controls"
              (let ((worktree
                     (nerimux/workspace-model:make-worktree :id
                                                            "wt-diff-tab"
                                                            :path
                                                            "/tmp/nerimux-inspect-diff-tab")))
                (with-stubbed-fdefinition
                 ((vcs-kit:make-vcs-repository
                   (lambda (directory &rest arguments)
                     (declare (ignore arguments))
                     directory))
                  (vcs-kit:vcs-diff
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (%inspect-fake-diff-result
                      (format nil "a~Cb~Cc~%" (code-char 27) (code-char 9))))))
                 (let ((diff
                        (nerimux/vcs::%read-worktree-file-diff worktree
                                                               "src/tab.lisp")))
                   (expect (string= "ab c" (first (cdr diff)))))))))

(describe "vcs worktree commit subject content limits (F3b/F5)"
          (it
           "truncates a newline-less commit message to *worktree-text-max-characters*"
           (let ((worktree
                  (nerimux/workspace-model:make-worktree :id
                                                         "wt-commit-cap"
                                                         :path
                                                         "/tmp/nerimux-inspect-commit-cap"))
                 (long-message (make-string 10000 :initial-element #\b)))
             (with-stubbed-fdefinition
              ((vcs-kit:make-vcs-repository
                (lambda (directory &rest arguments)
                  (declare (ignore arguments))
                  directory))
               (vcs-kit:vcs-list-commits
                (lambda (&rest arguments)
                  (declare (ignore arguments))
                  (list (%inspect-fake-commit "abc1234" long-message)))))
              (let ((commits (nerimux/vcs::%read-worktree-commits worktree)))
                (expect
                 (= nerimux/vcs::*worktree-text-max-characters*
                    (length (cdr (first commits)))))
                (expect
                 (string=
                  (subseq long-message
                          0
                          nerimux/vcs::*worktree-text-max-characters*)
                  (cdr (first commits))))))))
          (it "strips control characters from a commit subject"
              (let ((worktree
                     (nerimux/workspace-model:make-worktree :id
                                                            "wt-commit-control"
                                                            :path
                                                            "/tmp/nerimux-inspect-commit-control")))
                (with-stubbed-fdefinition
                 ((vcs-kit:make-vcs-repository
                   (lambda (directory &rest arguments)
                     (declare (ignore arguments))
                     directory))
                  (vcs-kit:vcs-list-commits
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (list
                      (%inspect-fake-commit "abc1234"
                                            (format nil
                                                    "a~C[31mb"
                                                    (code-char 27)))))))
                 (let ((commits (nerimux/vcs::%read-worktree-commits worktree)))
                   (expect (string= "a[31mb" (cdr (first commits)))))))))

(describe "vcs worktree commits settlement target (F2)"
  (it "redirects settlement to the catalog's current struct when a rebuild replaced the captured one"
    (let* ((previous (nerimux/vcs:workspace-organizations))
           (organization (nerimux/workspace-model:make-organization
                          :id "org-f2" :host "vcs-host" :name "f2-owner"))
           (repository (nerimux/workspace-model:make-repository
                        :id "repo-f2" :organization organization
                        :specification "f2-owner/project"
                        :local-path "/tmp/nerimux-f2-repo"))
           (struct-a (nerimux/workspace-model:make-worktree
                      :id "wt-f2-shared" :repository repository
                      :path "/tmp/nerimux-f2-repo/wt" :branch "feature/f2"))
           (struct-b (nerimux/workspace-model:make-worktree
                      :id "wt-f2-shared" :repository repository
                      :path "/tmp/nerimux-f2-repo/wt" :branch "feature/f2"))
           (queued nil)
           (completed :untouched))
      (unwind-protect
          (progn
            (nerimux/workspace-model:organization-add-repository organization repository)
            (nerimux/workspace-model:repository-add-worktree repository struct-a)
            (nerimux/vcs:set-workspace-organizations (list organization))
            (with-stubbed-fdefinition
                ((vcs-kit:make-vcs-repository
                   (lambda (directory &rest arguments)
                     (declare (ignore arguments))
                     directory))
                 (vcs-kit:vcs-list-commits
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (list (%inspect-fake-commit "abc1234" "settled onto b")))))
              (let ((thread
                      (nerimux/vcs:refresh-worktree-commits-async
                       nil struct-a
                       :callback-dispatch (lambda (callback) (push callback queued))
                       :on-complete (lambda (result) (setf completed result)))))
                (setf (nerimux/workspace-model:repository-worktrees repository) nil)
                (nerimux/workspace-model:repository-add-worktree repository struct-b)
                (cl-concurrent-kit:join-thread thread :timeout 2)
                (expect (= 1 (length queued)))
                (funcall (pop queued))
                (expect (eq :ready (nerimux/workspace-model:worktree-commits-state struct-b)))
                (expect (equal (list (cons "abc1234" "settled onto b"))
                               (nerimux/workspace-model:worktree-recent-commits struct-b)))
                (expect (null (nerimux/workspace-model:worktree-commits-state struct-a)))
                (expect (eq struct-b completed)))))
        (nerimux/vcs:set-workspace-organizations previous)))))
