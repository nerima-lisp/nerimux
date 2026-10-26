(in-package #:nerimux/test/vcs)

(defun %catalog-test-write-file (path text)
  (with-open-file (stream path :direction :output :if-exists :supersede
                                :if-does-not-exist :create)
    (write-string text stream)))

(defun %catalog-test-commit (directory message)
  (%worktree-path-test-git
   directory "-c" "user.name=Test" "-c" "user.email=test@example.invalid"
   "-c" "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null"
   "commit" "-am" message))

(defun %catalog-test-find-worktree (repository path)
  (find path
        (nerimux/workspace-model:repository-worktrees repository)
        :key #'nerimux/workspace-model:worktree-path
        :test (lambda (left right)
                (string= (string-right-trim "/" left)
                         (string-right-trim "/" right)))))

(defun %catalog-test-render-worktree-state (worktree)
  (asdf:load-system "nerimux-renderer")
  (uiop:symbol-call :nerimux/renderer '#:%worktree-state-tag worktree))

(describe "F2 L2-07 real Git worktree status"
  (it "renders conflict before dirty and preserves dirty-only status"
    (%call-with-worktree-path-repository
     (lambda (ignored root)
       (declare (ignore ignored))
       (let* ((source (concatenate 'string root "source/"))
              (control (concatenate 'string root "control/"))
              (repository
                (nerimux/workspace-model:make-repository
                 :specification "local/conflict-fixture"
                 :local-path source)))
         (%catalog-test-write-file
          (concatenate 'string source ".gitattributes")
          (format nil "conflict.txt merge=binary~%"))
         (%catalog-test-write-file (concatenate 'string source "conflict.txt")
                                   "base\n")
         (%worktree-path-test-git source "add" ".gitattributes" "conflict.txt")
         (%catalog-test-commit source "base")
         (let ((merge-attribute
                (%worktree-path-test-git
                 source "check-attr" "merge" "--" "conflict.txt")))
           (unless (string= "conflict.txt: merge: binary" merge-attribute)
             (format *error-output* "merge attribute: ~S~%" merge-attribute))
           (expect (string= "conflict.txt: merge: binary" merge-attribute)))
         (%worktree-path-test-git source "worktree" "add" "-b"
                                   "dirty-only" control "HEAD")
         (%catalog-test-write-file (concatenate 'string control "dirty.txt")
                                   "dirty\n")
         (%worktree-path-test-git source "checkout" "-b" "feature")
         (%catalog-test-write-file (concatenate 'string source "conflict.txt")
                                   "feature\n")
         (%worktree-path-test-git source "add" "conflict.txt")
         (%catalog-test-commit source "feature change")
         (%worktree-path-test-git source "checkout" "main")
         (%catalog-test-write-file (concatenate 'string source "conflict.txt")
                                   "main\n")
         (%worktree-path-test-git source "add" "conflict.txt")
         (%catalog-test-commit source "main change")
         (multiple-value-bind (stdout stderr exit-code)
             (uiop:run-program
              (list "git" "-C" source "merge" "feature")
              :environment *worktree-path-test-git-environment*
              :output :string :error-output :string :ignore-error-status t)
           (unless (= 1 exit-code)
             (format *error-output*
                     "git merge exit code ~D~%stdout:~%~A~%stderr:~%~A~%"
                     exit-code stdout stderr))
           (expect (= 1 exit-code)))
         (%catalog-test-write-file
          (concatenate 'string source "dirty-after-conflict.txt") "dirty\n")
         (nerimux/vcs::%apply-repository-worktrees
          repository (nerimux/vcs::%git-worktree-list source) nil)
         (nerimux/vcs:refresh-repository-status repository)
         (let ((conflict (%catalog-test-find-worktree repository source))
               (dirty-only (%catalog-test-find-worktree repository control)))
           (expect conflict)
           (expect dirty-only)
           (expect (nerimux/workspace-model:worktree-conflict-p conflict))
           (expect (nerimux/workspace-model:worktree-dirty-p conflict))
           (expect (string= "CONFLICT"
                            (%catalog-test-render-worktree-state conflict)))
           (expect (nerimux/workspace-model:worktree-dirty-p dirty-only))
           (expect (not (nerimux/workspace-model:worktree-conflict-p dirty-only)))
           (expect (string= "DIRTY"
                            (%catalog-test-render-worktree-state dirty-only)))))))))

(describe "F2 L2-11 catalog activity ordering"
  (it "orders the recently focused worktree first and leaves it stable while rendering"
    (%call-with-worktree-path-repository
     (lambda (ignored root)
       (declare (ignore ignored))
       (let* ((source (concatenate 'string root "source/"))
              (older (concatenate 'string root "20260101T000000-abcdef0/"))
              (newer (concatenate 'string root "20260102T000000-bcdef01"))
              (previous (nerimux/vcs:workspace-organizations))
              (entry
                (vcs-kit:make-ghq-repository-entry
                 :specification "example.invalid/team/project"
                 :path source :backend :git)))
         (unwind-protect
              (progn
                (%worktree-path-test-git source "worktree" "add" "-b"
                                          "activity-older" older "HEAD")
                (%worktree-path-test-git source "worktree" "add" "-b"
                                          "activity-newer" newer "HEAD")
                (with-stubbed-fdefinition
                    ((vcs-kit:ghq-list-repositories
                       (lambda (&key query)
                         (declare (ignore query))
                         (list entry))))
                  (nerimux/vcs:set-workspace-organizations
                   (nerimux/vcs:scan-repositories)))
                (let* ((organization (first (nerimux/vcs:workspace-organizations)))
                       (repository
                         (first
                          (nerimux/workspace-model:organization-repositories
                           organization)))
                       (older-worktree
                         (%catalog-test-find-worktree repository older))
                       (newer-worktree
                         (%catalog-test-find-worktree repository newer))
                       (older-pane (nerimux/pane:make-pane :id 741))
                       (newer-pane (nerimux/pane:make-pane :id 742)))
                  (expect older-worktree)
                  (expect newer-worktree)
                  (nerimux/pane:worktree-add-pane older-worktree older-pane)
                  (nerimux/pane:worktree-add-pane newer-worktree newer-pane)
                  (nerimux/pane:pane-mark-output older-pane #(110))
                  (sleep 1.1)
                  (nerimux/pane:pane-mark-focused newer-pane)
                  (with-stubbed-fdefinition
                      ((vcs-kit:ghq-list-repositories
                         (lambda (&key query)
                           (declare (ignore query))
                           (list entry))))
                    (nerimux/vcs:set-workspace-organizations
                     (nerimux/vcs:scan-repositories)))
                  (let* ((published-organization
                           (first (nerimux/vcs:workspace-organizations)))
                         (published-repository
                           (first
                            (nerimux/workspace-model:organization-repositories
                             published-organization)))
                         (before
                           (mapcar #'nerimux/workspace-model:worktree-path
                                   (nerimux/workspace-model:repository-worktrees
                                    published-repository))))
                    (expect (string= newer
                                     (nerimux/workspace-model:worktree-path
                                      (first
                                       (nerimux/workspace-model:repository-worktrees
                                        published-repository)))))
                    (asdf:load-system "nerimux-renderer")
                    (uiop:symbol-call :nerimux/renderer '#:workspace-tree-objects
                                      (list published-organization) nil)
                    (uiop:symbol-call :nerimux/renderer '#:workspace-tree-objects
                                      (list published-organization) nil)
                    (expect (equal before
                                   (mapcar #'nerimux/workspace-model:worktree-path
                                           (nerimux/workspace-model:repository-worktrees
                                            published-repository)))))))
           (nerimux/vcs:set-workspace-organizations previous)))))))
(describe "F2 L2-09 catalog unreadable checkout"
  (it "keeps a linked checkout read error separate from missing after workspace refresh"
    (%call-with-worktree-path-repository
     (lambda (ignored root)
       (declare (ignore ignored))
       (let* ((source (concatenate 'string root "source/"))
              (linked (concatenate 'string root "read-error-checkout/"))
              (entry
                (vcs-kit:make-ghq-repository-entry
                 :specification "example.invalid/team/read-error"
                 :path source
                 :backend :git))
              (previous (nerimux/vcs:workspace-organizations)))
         (labels ((refresh-catalog ()
                    (let ((finished (sb-thread:make-semaphore :count 0))
                          (organizations nil)
                          (catalog-error nil))
                      (nerimux/vcs:refresh-workspace-organizations-async
                       :on-complete
                       (lambda (current)
                         (setf organizations current)
                         (sb-thread:signal-semaphore finished))
                       :on-error
                       (lambda (condition)
                         (setf catalog-error condition)
                         (sb-thread:signal-semaphore finished)))
                      (unless (sb-thread:wait-on-semaphore finished :timeout 30)
                        (error "workspace catalog refresh did not complete"))
                      (values organizations catalog-error)))
                  (find-repository (organizations path)
                    (loop for organization in organizations
                          thereis
                          (find-if
                           (lambda (repository)
                             (string=
                              (string-right-trim "/" path)
                              (string-right-trim
                               "/"
                               (nerimux/workspace-model:repository-local-path
                                repository))))
                           (nerimux/workspace-model:organization-repositories
                            organization))))
                  (rendered-rows (organization repository)
                    (asdf:load-system "nerimux-renderer")
                    (let ((expanded (make-hash-table :test #'equal)))
                      (setf
                       (gethash
                        (list :repository
                              (nerimux/workspace-model:repository-id repository))
                        expanded)
                       t)
                      (let* ((frame
                               (uiop:symbol-call
                                :nerimux/renderer
                                '#:render-workspace-overview-to-tui-string
                                (list organization) 24 100
                                :expanded-node-ids expanded))
                             (surface
                               (uiop:symbol-call
                                :nerimux/renderer
                                '#:%surface-from-ansi-frame frame 24 100))
                             (plain
                               (uiop:symbol-call
                                :cl-tui-kit/core '#:surface-string surface)))
                        (uiop:split-string
                         plain :separator (list (code-char 10)))))))
           (unwind-protect
                (with-stubbed-fdefinition
                    ((vcs-kit:ghq-list-repositories
                      (lambda (&key query)
                        (declare (ignore query))
                        (list entry))))
                  (progn
                    (%worktree-path-test-git
                     source "worktree" "add" "-b" "read-error-fixture"
                     linked "HEAD")
                    (multiple-value-bind (organizations catalog-error)
                        (refresh-catalog)
                      (expect organizations)
                      (expect (null catalog-error)))
                    (let* ((initial-organizations
                             (nerimux/vcs:workspace-organizations))
                           (initial-organization
                             (first initial-organizations))
                           (initial-repository
                             (find-repository initial-organizations source))
                           (worktree
                             (%catalog-test-find-worktree
                              initial-repository linked)))
                      (expect initial-organization)
                      (expect initial-repository)
                      (expect worktree)
                      (expect
                       (not
                        (string=
                         (nerimux/workspace-model:worktree-id worktree)
                         (nerimux/workspace-model:worktree-id
                          (nerimux/workspace-model:repository-main-worktree
                           initial-repository)))))
                      (expect
                       (not
                        (nerimux/workspace-model:worktree-dirty-p worktree)))
                      (expect
                       (not
                        (nerimux/workspace-model:worktree-conflict-p worktree)))
                      (setf
                       (nerimux/workspace-model:worktree-completed-p worktree)
                       t)
                      (multiple-value-bind (classification reason)
                          (nerimux/workspace-model:worktree-prune-classification
                           worktree)
                        (declare (ignore reason))
                        (expect (eq :candidate classification)))
                      (let* ((worktree-id
                              (nerimux/workspace-model:worktree-id worktree))
                             (status-before
                              (nerimux/workspace-model:worktree-status worktree)))
                        (unwind-protect
                             (progn
                               (uiop:run-program
                                (list "chmod" "000"
                                      (string-right-trim "/" linked))
                                :output :string :error-output :string)
                               (multiple-value-bind (stdout stderr exit-code)
                                   (uiop:run-program
                                    (list "git" "-C" linked "status" "--short")
                                    :environment
                                    *worktree-path-test-git-environment*
                                    :output :string
                                    :error-output :string
                                    :ignore-error-status t)
                                 (declare (ignore stdout stderr))
                                 (expect
                                  (and (integerp exit-code)
                                       (not (zerop exit-code)))))
                               (multiple-value-bind (organizations catalog-error)
                                   (refresh-catalog)
                                 (expect organizations)
                                 (expect (null catalog-error)))
                               (let* ((organizations
                                        (nerimux/vcs:workspace-organizations))
                                      (organization (first organizations))
                                      (repository
                                        (find-repository organizations source))
                                      (unreadable
                                        (%catalog-test-find-worktree
                                         repository linked)))
                                 (expect organization)
                                 (expect repository)
                                 (expect unreadable)
                                 (progn
                                  (expect
                                   (string=
                                    worktree-id
                                    (nerimux/workspace-model:worktree-id
                                     unreadable)))
                                  (expect status-before))
                                 (expect
                                  (nerimux/workspace-model:worktree-completed-p
                                   unreadable))
                                 (expect
                                  (uiop:symbol-call
                                   :nerimux/workspace-model
                                   '#:worktree-read-error-p unreadable))
                                 (progn
                                  (expect
                                   (not
                                    (nerimux/workspace-model:worktree-missing-p
                                     unreadable)))
                                  (expect
                                   (eq
                                    status-before
                                    (nerimux/workspace-model:worktree-status
                                     unreadable)))
                                  (expect
                                   (not
                                    (uiop:symbol-call
                                     :nerimux/pane
                                     (quote #:worktree-removal-candidate-p)
                                     unreadable))))
                                 (expect
                                  (not
                                   (nerimux/workspace-model:repository-missing-p
                                    repository)))
                                 (let* ((rows
                                          (rendered-rows organization repository))
                                        (checkout-row
                                          (find-if
                                           (lambda (line)
                                             (search "read-error-fixture" line))
                                           rows))
                                        (repository-row
                                          (find-if
                                           (lambda (line)
                                             (and (search "read-error" line)
                                                  (not
                                                   (search
                                                    "read-error-fixture"
                                                    line))))
                                           rows)))
                                   (expect checkout-row)
                                   (expect repository-row)
                                   (expect (search "✗" checkout-row))
                                   (expect (search "!" repository-row)))
                                 (multiple-value-bind (classification reason)
                                     (nerimux/workspace-model:worktree-prune-classification
                                      unreadable)
                                   (expect (eq :excluded classification))
                                   (expect (eq :read-error reason)))))
                          (uiop:run-program
                           (list "chmod" "700" (string-right-trim "/" linked))
                           :output :string :error-output :string))))))
             (nerimux/vcs:set-workspace-organizations previous))))))))

