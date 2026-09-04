(in-package #:nerimux/test)

(describe "transient data and process log suite"
          (it "covers-meta-sequence-and-process-log-boundaries"
              (with-fake-session (s)
                                 (let ((conn (%make-test-conn))
                                       (nerimux::*client-meta-pending*
                                        (make-hash-table :test #'eq)))
                                   (dolist (key '(#\n #\p))
                                     (setf (gethash conn
                                                    nerimux::*client-meta-pending*) :second)
                                     (nerimux::%client-meta-pending-consume conn
                                                                            (string
                                                                             key))
                                     (expect
                                      (null
                                       (gethash conn
                                                nerimux::*client-meta-pending*))))
                                   (setf (gethash conn
                                                  nerimux::*client-meta-pending*) :second)
                                   (nerimux::%client-meta-pending-consume conn
                                                                          "[")
                                   (expect
                                    (eq :csi-third
                                        (gethash conn
                                                 nerimux::*client-meta-pending*)))
                                   (nerimux::%client-meta-pending-consume conn
                                                                          "Z")
                                   (expect
                                    (null
                                     (gethash conn
                                              nerimux::*client-meta-pending*)))
                                   (setf (gethash conn
                                                  nerimux::*client-meta-pending*) :csi-third)
                                   (nerimux::%client-meta-pending-consume conn
                                                                          "A")
                                   (expect
                                    (null
                                     (gethash conn
                                              nerimux::*client-meta-pending*)))
                                   (setf (nerimux::client-conn-process-log conn) '("one"
                                                                                   "two"))
                                   (nerimux::%scroll-client-process-log conn 99)
                                   (expect
                                    (= 1
                                       (nerimux::client-conn-process-log-scroll
                                        conn)))
                                   (nerimux::%scroll-client-process-log conn
                                                                        -99)
                                   (expect
                                    (zerop
                                     (nerimux::client-conn-process-log-scroll
                                      conn))))))
          (it "covers-visibility-and-process-log-state-machines"
              (with-fake-session (s)
                                 (let ((conn (%make-test-conn)))
                                   (expect
                                    (nerimux::%client-set-visibility-level conn
                                                                           0))
                                   (expect
                                    (= 2
                                       (nerimux::client-conn-visibility-level
                                        conn)))
                                   (dolist (expected '(3 4 1 2))
                                     (nerimux::%client-cycle-visibility conn)
                                     (expect
                                      (= expected
                                         (nerimux::client-conn-visibility-level
                                          conn))))
                                   (nerimux::%client-cycle-visibility conn)
                                   (expect
                                    (= 3
                                       (nerimux::client-conn-visibility-level
                                        conn)))
                                   (setf (nerimux::client-conn-process-log conn) (list
                                                                                  "first"
                                                                                  "second"
                                                                                  "third"))
                                   (nerimux::%handle-process-log-key conn "n")
                                   (expect
                                    (= 1
                                       (nerimux::client-conn-process-log-scroll
                                        conn)))
                                   (nerimux::%handle-process-log-key conn "p")
                                   (expect
                                    (= 0
                                       (nerimux::client-conn-process-log-scroll
                                        conn)))
                                   (setf (nerimux::client-conn-modal conn) :process-log)
                                   (nerimux::%handle-process-log-key conn #(27))
                                   (expect
                                    (null (nerimux::client-conn-modal conn)))
                                   (expect
                                    (nerimux::%client-esc-swallow-consume conn))
                                   (expect
                                    (nerimux::%client-esc-swallow-consume conn))
                                   (expect
                                    (null
                                     (nerimux::%client-esc-swallow-consume conn)))
                                   (setf (nerimux::client-conn-modal conn) :process-log)
                                   (nerimux::%handle-multi-key-message s
                                                                       conn
                                                                       "q")
                                   (expect
                                    (null (nerimux::client-conn-modal conn)))
                                   (setf (nerimux::client-conn-view conn) :status)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (eq :repolist
                                        (nerimux::client-conn-view conn))))))
          (it "steps-back-through-transient-filter-and-live-focus-boundaries"
              (with-fake-session (s)
                                 (let* ((conn (%make-test-conn))
                                        (pane (first (nerimux::all-panes s))))
                                   (setf (nerimux::client-conn-modal conn) :transient
                                         (nerimux::client-conn-transient-view
                                          conn) :transient-data)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (null (nerimux::client-conn-modal conn)))
                                   (expect
                                    (null
                                     (nerimux::client-conn-transient-view conn)))
                                   (setf (nerimux::client-conn-tree-filter conn) "feature"
                                         (nerimux::client-conn-view conn) :status)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (null
                                     (nerimux::client-conn-tree-filter conn)))
                                   (expect
                                    (eq :status
                                        (nerimux::client-conn-view conn)))
                                   (setf (nerimux::client-conn-focus conn) pane)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (eq :pane (nerimux::client-conn-view conn)))
                                   (setf (nerimux::client-conn-view conn) :repolist
                                         (nerimux::client-conn-focus conn) nil)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (eq :repolist
                                        (nerimux::client-conn-view conn)))
                                   (setf (nerimux::client-conn-focus conn) pane)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (eq :pane (nerimux::client-conn-view conn))))))
          (it "transient-command-data-and-process-log-share-stable-contracts"
              (with-fake-session (s)
                                 (let ((conn (%make-test-conn)))
                                   (dolist 
                                       (definition
                                        nerimux::+transient-definitions+)
                                     (let ((menu (cdr definition)))
                                       (expect (characterp (car definition)))
                                       (expect (stringp (first menu)))
                                       (expect (listp (second menu)))
                                       (dolist (action (third menu))
                                         (expect (characterp (first action)))
                                         (expect (stringp (second action)))
                                         (expect
                                          (member (first (third action))
                                                  '(:git :call
                                                         :open-transient
                                                         :help
                                                         :stub))))))
                                   (expect
                                    (string= "git push --force"
                                             (nerimux::%transient-command-text
                                              :push
                                              '("--force"))))
                                   (expect
                                    (null (nerimux::%transient-branch conn)))
                                   (expect
                                    (null
                                     (nerimux::%transient-subtitle #\P conn)))
                                   (expect
                                    (string= "on ?"
                                             (nerimux::%transient-action-display-description
                                              conn
                                              "on ~A")))
                                   (expect
                                    (equal '((#\f "--force" "--force" nil #\P))
                                           (nerimux::%transient-render-arguments
                                            #\P
                                            conn
                                            '((#\f . "--force")))))
                                   (nerimux::%client-transient-toggle-flag conn
                                                                           #\P
                                                                           "--force")
                                   (expect
                                    (equal '("--force")
                                           (nerimux::%client-transient-active-flags
                                            conn
                                            #\P)))
                                   (nerimux::%client-transient-toggle-flag conn
                                                                           #\P
                                                                           "--force")
                                   (expect
                                    (null
                                     (nerimux::%client-transient-active-flags
                                      conn
                                      #\P)))
                                   (dotimes 
                                       (index
                                        (1+ nerimux::+max-process-log-entries+))
                                     (nerimux::%client-log-process conn
                                                                   (format nil
                                                                           "git ~D"
                                                                           index)
                                                                   t
                                                                   nil))
                                   (expect
                                    (= nerimux::+max-process-log-entries+
                                       (length
                                        (nerimux::client-conn-process-log conn))))
                                   (expect
                                    (equal '("git 20" "0" "")
                                           (first
                                            (nerimux::client-conn-process-log
                                             conn)))))))
          (it "transient-rendering-and-dismissal-cover-the-modal-contract"
              (with-fake-session (s)
                                 (let ((conn (%make-test-conn)))
                                   (expect
                                    (null
                                     (nerimux::%open-client-transient conn #\~)))
                                   (expect
                                    (nerimux::%open-client-transient conn #\P))
                                   (let ((view
                                          (nerimux::client-conn-transient-view
                                           conn)))
                                     (expect
                                      (eq :transient
                                          (nerimux::client-conn-modal conn)))
                                     (expect
                                      (string= "Push"
                                               (nerimux/renderer:transient-view-title
                                                view)))
                                     (expect
                                      (equal '(#\p #\e)
                                             (mapcar #'first
                                                     (nerimux/renderer:transient-view-actions
                                                      view)))))
                                   (nerimux::%handle-client-transient-key-payload
                                    s
                                    conn
                                    #(102))
                                   (expect
                                    (equal '("--force-with-lease")
                                           (nerimux::%client-transient-active-flags
                                            conn
                                            #\P)))
                                   (nerimux::%run-transient-action s
                                                                   conn
                                                                   (list
                                                                    :open-transient
                                                                    #\P))
                                   (expect
                                    (eq :transient
                                        (nerimux::client-conn-modal conn)))
                                   (nerimux::%run-transient-action s
                                                                   conn
                                                                   (list :git
                                                                         #\P
                                                                         :push
                                                                         nil
                                                                         nil
                                                                         nil))
                                   (expect
                                    (null (nerimux::client-conn-modal conn)))
                                   (nerimux::%handle-client-transient-key-payload
                                    s
                                    conn
                                    #(122))
                                   (nerimux::%handle-client-transient-key-payload
                                    s
                                    conn
                                    #(113))
                                   (expect
                                    (null (nerimux::client-conn-modal conn)))
                                   (nerimux::%open-client-transient conn #\P)
                                   (nerimux::%handle-client-transient-key-payload
                                    s
                                    conn
                                    #(27))
                                   (expect
                                    (null
                                     (nerimux::client-conn-transient-view conn))))))
          (it
           "transient-actions-cover-preconditions-confirmation-and-direct-execution"
           (with-fake-session (s)
                              (let ((conn (%make-test-conn))
                                    (nerimux::*clients* nil))
                                (setf nerimux::*clients* (list conn))
                                (nerimux::%run-transient-git-action conn
                                                                    #\P
                                                                    :push
                                                                    nil
                                                                    nil
                                                                    nil)
                                (expect
                                 (equal "no repository selected"
                                        (first
                                         (nerimux::client-conn-message-log conn))))
                                (let* ((organization
                                        (nerimux/workspace-model:make-organization
                                         :id
                                         "org-transient"
                                         :host
                                         "github.com"
                                         :name
                                         "team"))
                                       (repository
                                        (nerimux/workspace-model:make-repository
                                         :id
                                         "repo-transient"
                                         :organization
                                         organization
                                         :specification
                                         "github.com/team/repo-transient"))
                                       (calls nil))
                                  (nerimux/workspace-model:organization-add-repository
                                   organization
                                   repository)
                                  (nerimux::%set-client-selected-tree-object
                                   conn
                                   repository)
                                  (with-stubbed-fdefinition
                                   ((nerimux/vcs:vcs-package-available-p
                                     (lambda ()
                                       nil)))
                                   (nerimux::%run-transient-git-action conn
                                                                       #\P
                                                                       :push
                                                                       nil
                                                                       nil
                                                                       nil)
                                   (expect
                                    (equal "VCS unavailable"
                                           (first
                                            (nerimux::client-conn-message-log
                                             conn)))))
                                  (with-stubbed-fdefinition
                                   ((nerimux/vcs:vcs-package-available-p
                                     (lambda ()
                                       t))
                                    (nerimux::%refresh-client-picker
                                     (lambda (ignored-connection)
                                       (declare (ignore ignored-connection))))
                                    (nerimux/vcs:git-write-operation-async
                                     (lambda 
                                         (received operation
                                                   args
                                                   &key
                                                   on-complete
                                                   on-error
                                                   callback-dispatch)
                                       (declare (ignore callback-dispatch
                                                        on-error))
                                       (push (list received operation args)
                                             calls)
                                       (funcall on-complete t "done")
                                       t)))
                                   (nerimux::%run-transient-git-action conn
                                                                       #\P
                                                                       :push
                                                                       '("--force")
                                                                       t
                                                                       nil)
                                   (expect
                                    (eq :confirm
                                        (nerimux::client-conn-modal conn)))
                                   (funcall
                                    (nerimux::client-conn-confirm-action conn))
                                   (expect
                                    (equal
                                     (list (list repository :push '("--force")))
                                     calls))
                                   (nerimux::%run-transient-git-action conn
                                                                       #\P
                                                                       :push
                                                                       nil
                                                                       nil
                                                                       nil)
                                   (expect (= 2 (length calls)))
                                   (nerimux::%client-transient-toggle-flag conn
                                                                           #\P
                                                                           "--force")
                                   (nerimux::%run-transient-git-action conn
                                                                       #\P
                                                                       :push
                                                                       nil
                                                                       nil
                                                                       '("--force"))
                                   (expect
                                    (eq :confirm
                                        (nerimux::client-conn-modal conn)))
                                   (funcall
                                    (nerimux::client-conn-confirm-action conn))
                                   (expect (= 3 (length calls)))
                                   (nerimux::%client-transient-toggle-flag conn
                                                                           #\P
                                                                           "--force")))
                                (with-stubbed-fdefinition
                                    ((nerimux/vcs:vcs-package-available-p (lambda () t))
                                     (nerimux/vcs:git-write-operation-async
                                      (lambda (received operation args &key on-complete
                                                       on-error callback-dispatch)
                                        (declare (ignore received operation args on-error
                                                                callback-dispatch))
                                        (funcall on-complete nil "failed"))))
                                  (nerimux::%run-transient-git-action conn #\P :push nil nil nil)
                                  (expect (string= "git push: failed"
                                                   (first (nerimux::client-conn-message-log conn)))))
                                (multiple-value-bind (repository worktree
                                                                 ignored-conn) 
                                    (%make-worktree-operation-fixture)
                                  (declare (ignore repository ignored-conn))
                                  (nerimux::%set-client-selected-tree-object
                                   conn
                                   worktree)
                                  (expect
                                   (string=
                                    "feature/errors -> origin/feature/errors"
                                    (nerimux::%transient-subtitle #\P conn)))
                                (expect
                                 (string= "on feature/errors"
                                          (nerimux::%transient-subtitle #\x
                                                                        conn)))))))
          (it "records transient write failures through the shared process log"
              (with-fake-session (s)
                (let ((conn (%make-test-conn))
                      (nerimux::*clients* nil))
                  (setf nerimux::*clients* (list conn))
                  (multiple-value-bind (repository ignored-worktree ignored-conn)
                      (%make-worktree-operation-fixture)
                    (declare (ignore ignored-worktree ignored-conn))
                    (nerimux::%set-client-selected-tree-object conn repository)
                    (with-stubbed-fdefinition
                        ((nerimux/vcs:vcs-package-available-p (lambda () t))
                         (nerimux/vcs:git-write-operation-async
                           (lambda (received operation args &key on-complete on-error
                                            callback-dispatch)
                             (declare (ignore received operation args on-complete
                                                     callback-dispatch))
                             (funcall on-error (make-condition 'simple-error
                                                               :format-control "boom")))))
                      (nerimux::%run-transient-git-action conn #\P :push nil nil nil)
                      (expect (equal '("git push" "1" "boom")
                                     (first (nerimux::client-conn-process-log conn))))
                      (expect (string= "git push: failed: boom"
                                       (first (nerimux::client-conn-message-log conn))))))))))

