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
                                    (nerimux::%client-esc-swallow-consume conn
                                                                          #(91)))
                                   (expect
                                    (nerimux::%client-esc-swallow-consume conn
                                                                          #(65)))
                                   (expect
                                    (null
                                     (nerimux::%client-esc-swallow-consume conn
                                                                           #(65))))
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
                                                         :prompt
                                                         :read-view
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
                                                      view))))
                                     (expect
                                      (notany
                                       (lambda (action) (search "origin/" (second action)))
                                       (nerimux/renderer:transient-view-actions
                                        view))))
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
                                        (funcall on-complete
                                                 nil
                                                 (format nil
                                                         "~%fatal: No configured push destination.~%more")))))
                                  (nerimux::%run-transient-git-action conn #\P :push nil nil nil)
                                  (let ((message (first (nerimux::client-conn-message-log conn))))
                                    (expect (search "git push failed: fatal: No configured push destination."
                                                    message))
                                    (expect (search "$ shows the full log" message))
                                    (expect (< (length message) 100))))
                                (multiple-value-bind (repository worktree
                                                                 ignored-conn)
                                    (%make-worktree-operation-fixture)
                                  (declare (ignore repository ignored-conn))
                                  (nerimux::%set-client-selected-tree-object
                                   conn
                                   worktree)
                                  (expect
                                   (string= "no upstream"
                                            (nerimux::%transient-subtitle #\P conn)))
                                  (setf (nerimux/workspace-model:worktree-status worktree)
                                        (vcs-kit::%make-vcs-status-snapshot
                                         :branch-head "feature/errors"
                                         :branch-upstream "origin/feature/errors"))
                                  (expect
                                   (string=
                                    "feature/errors → origin/feature/errors"
                                    (nerimux::%transient-subtitle #\P conn)))
                                  (expect
                                   (string=
                                    "origin/feature/errors → feature/errors"
                                    (nerimux::%transient-subtitle #\F conn)))
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
                      (expect (string= "git push failed: boom  $ shows the full log"
                                       (first (nerimux::client-conn-message-log conn)))))))))

          (it "routes read-only views through client bytes and closes them"
              (with-fake-session (s)
                (let ((conn (%make-test-conn))
                      (nerimux::*clients* nil))
                  (setf nerimux::*clients* (list conn))
                  (multiple-value-bind (repository worktree ignored-conn)
                      (%make-worktree-operation-fixture)
                    (declare (ignore repository ignored-conn))
                    (nerimux::%set-client-selected-tree-object conn worktree)
                    (with-stubbed-fdefinition
                        ((nerimux/vcs:vcs-package-available-p (lambda () t))
                         (nerimux/vcs:read-worktree-log-async
                           (lambda (received &key on-complete on-error callback-dispatch)
                             (declare (ignore received on-error callback-dispatch))
                             (funcall on-complete "commit abc\nsubject"))))
                      (labels ((send-text (text)
                                 (dolist (byte (coerce
                                                (cl-codec-kit:string-to-octets
                                                 text
                                                 :encoding :utf-8)
                                                'list))
                                   (nerimux::%handle-multi-key-message
                                    s conn (vector byte)))))
                        (setf (nerimux::client-conn-view conn) :status)
                        (nerimux::%open-client-transient conn #\l)
                        (nerimux::%handle-multi-key-message s conn #(108))
                        (expect (eq :read-view (nerimux::client-conn-modal conn)))
                        (expect (string= "commit abc\nsubject"
                                         (nerimux/renderer:read-view-content
                                          (nerimux::client-conn-read-view conn))))
                        (nerimux::%handle-multi-key-message s conn #(47))
                        (send-text "commit")
                        (nerimux::%handle-multi-key-message s conn #(13))
                        (expect (eq :read-view (nerimux::client-conn-modal conn)))
                        (expect (string= "commit"
                                         (nerimux/renderer:read-view-query
                                          (nerimux::client-conn-read-view conn))))
                        (nerimux::%handle-multi-key-message s conn #(113))
                        (expect (null (nerimux::client-conn-modal conn))))))))

          (it "submits commit branch tag and remote prompts from client bytes"
              (with-fake-session (s)
                (let ((conn (%make-test-conn))
                      (nerimux::*clients* nil)
                      (calls nil))
                  (setf nerimux::*clients* (list conn))
                  (multiple-value-bind (repository worktree ignored-conn)
                      (%make-worktree-operation-fixture)
                    (declare (ignore ignored-conn))
                    (nerimux::%set-client-selected-tree-object conn worktree)
                    (with-stubbed-fdefinition
                        ((nerimux/vcs:vcs-package-available-p (lambda () t))
                         (nerimux/vcs:git-write-operation-async
                           (lambda (received operation args &key on-complete on-error callback-dispatch)
                             (declare (ignore on-error callback-dispatch))
                             (push (list received operation args) calls)
                             (funcall on-complete t "done"))))
                      (labels ((send (payload)
                               (nerimux::%handle-multi-key-message s conn payload))
                             (send-text (text)
                               (dolist (byte (coerce
                                              (cl-codec-kit:string-to-octets
                                               text
                                               :encoding :utf-8)
                                              'list))
                                 (send (vector byte))))
                             (submit-one-line (menu action text)
                               (nerimux::%open-client-transient conn menu)
                               (send action)
                               (send-text text)
                               (send #(13))))
                        (setf (nerimux::client-conn-view conn) :status)
                        (nerimux::%open-client-transient conn #\c)
                        (send #(99))
                        (send-text "message")
                        (send #(19))
                        (submit-one-line #\b #(99) "feature/new")
                        (submit-one-line #\t #(116) "v1.2")
                        (submit-one-line #\P #(101) "upstream")
                        (expect (= 4 (length calls)))
                        (expect (equal (list repository :commit '("--message" "message"))
                                       (find :commit calls :key #'second)))
                        (expect (equal (list repository :branch '("feature/new"))
                                       (find :branch calls :key #'second)))
                        (expect (equal (list repository :tag '("v1.2"))
                                       (find :tag calls :key #'second)))
                        (expect (equal (list repository :push '("upstream"))
                                       (find :push calls :key #'second))))))))))

          (it "rejects a text-prompt value that starts with - for every git-argument kind"
              ;; S3: a value beginning with `-` becomes an option to the git
              ;; subprocess (`--abort` into merge, `--force` into push) rather
              ;; than the name it looks like.
              (with-fake-session (s)
                (dolist (kind '(:branch-create :tag-create :merge-branch
                                :branch-delete :remote-push))
                  (let ((conn (%make-test-conn))
                        (nerimux::*clients* nil)
                        (calls nil))
                    (setf nerimux::*clients* (list conn))
                    (multiple-value-bind (repository worktree ignored-conn)
                        (%make-worktree-operation-fixture)
                      (declare (ignore ignored-conn repository))
                      (nerimux::%set-client-selected-tree-object conn worktree)
                      (with-stubbed-fdefinition
                          ((nerimux/vcs:vcs-package-available-p (lambda () t))
                           (nerimux/vcs:git-write-operation-async
                             (lambda (received operation args &key on-complete
                                               on-error callback-dispatch)
                               (declare (ignore received operation args
                                                on-complete on-error
                                                callback-dispatch))
                               (push t calls))))
                        (nerimux::%open-client-text-prompt conn kind)
                        (cl-tui-kit/widgets:handle-widget-event
                         (nerimux::client-conn-text-prompt-widget conn)
                         (cl-tui-kit/core:make-text-input-event "-force"))
                        (nerimux::%submit-client-text-prompt conn)
                        (expect (null calls))
                        ;; For :branch-delete a bare non-empty value opens a
                        ;; confirm view rather than calling git-write-operation
                        ;; -async directly, so NULL CALLS alone would not
                        ;; distinguish the rejected case from that path; the
                        ;; prompt staying open (never cleared) does.
                        (expect
                         (eq :text-prompt (nerimux::client-conn-modal conn)))
                        (expect
                         (string= "a name cannot start with -"
                                  (first (nerimux::client-conn-message-log
                                          conn))))))))))

          (it "strips an SGR escape sequence from a commit message before it reaches the notification"
              ;; S4: %transient-argument-text feeds user-typed text straight
              ;; into %client-notify, so a commit message carrying an SGR
              ;; sequence would otherwise recolour the client's message strip.
              (with-fake-session (s)
                (let ((conn (%make-test-conn))
                      (nerimux::*clients* nil))
                  (setf nerimux::*clients* (list conn))
                  (multiple-value-bind (repository worktree ignored-conn)
                      (%make-worktree-operation-fixture)
                    (declare (ignore repository ignored-conn))
                    (nerimux::%set-client-selected-tree-object conn worktree)
                    (with-stubbed-fdefinition
                        ((nerimux/vcs:vcs-package-available-p (lambda () t))
                         (nerimux/vcs:git-write-operation-async
                           (lambda (received operation args &key on-complete
                                             on-error callback-dispatch)
                             (declare (ignore received operation args on-error
                                              callback-dispatch))
                             (funcall on-complete t "done"))))
                      (nerimux::%open-client-text-prompt conn :commit-message)
                      (cl-tui-kit/widgets:handle-widget-event
                       (nerimux::client-conn-text-prompt-widget conn)
                       (cl-tui-kit/core:make-text-input-event
                        (format nil "danger~C[31mred" (code-char 27))))
                      (nerimux::%submit-client-text-prompt conn)
                      (let ((notified (first (nerimux::client-conn-message-log
                                              conn))))
                        (expect (not (find (code-char 27) notified)))
                        (expect (not (search "[31m" notified)))
                        (expect (string= "committed: dangerred" notified))))))))

          (it "keeps multiline prompt paste on the client byte path"
              (with-fake-session (s)
                (let ((conn (%make-test-conn))
                      (nerimux::*clients* nil)
                      (calls nil))
                  (setf nerimux::*clients* (list conn))
                  (multiple-value-bind (repository worktree ignored-conn)
                      (%make-worktree-operation-fixture)
                    (declare (ignore ignored-conn))
                    (nerimux::%set-client-selected-tree-object conn worktree)
                    (with-stubbed-fdefinition
                        ((nerimux/vcs:vcs-package-available-p (lambda () t))
                         (nerimux/vcs:git-write-operation-async
                           (lambda (received operation args &key on-complete on-error callback-dispatch)
                             (declare (ignore on-error callback-dispatch))
                             (push (list received operation args) calls)
                             (funcall on-complete t "done"))))
                      (labels ((send-text (text)
                                 (dolist (byte (coerce
                                                (cl-codec-kit:string-to-octets
                                                 text
                                                 :encoding :utf-8)
                                                'list))
                                   (nerimux::%handle-multi-client-message
                                    nerimux::+msg-key+
                                    (vector byte)
                                    s
                                    conn))))
                        (setf (nerimux::client-conn-view conn) :status)
                        (nerimux::%open-client-transient conn #\c)
                        (nerimux::%handle-multi-key-message s conn #(99))
                        (send-text (concatenate 'string
                                                (string #\Escape)
                                                "[200~first"
                                                (string #\Newline)
                                                "second"
                                                (string #\Escape)
                                                "[201~"))
                        (expect (eq :text-prompt
                                    (nerimux::client-conn-modal conn)))
                        (expect
                         (string= (concatenate 'string
                                               "first"
                                               (string #\Newline)
                                               "second")
                                  (cl-tui-kit/widgets:input-widget-value
                                   (nerimux::client-conn-text-prompt-widget conn))))
                        (nerimux::%handle-multi-key-message s conn #(19))
                        (expect
                         (equal (list repository :commit
                                      (list "--message"
                                            (concatenate 'string
                                                         "first"
                                                         (string #\Newline)
                                                         "second")))
                                (first calls))))))))))

(describe "transient outcome messages and nested menus"
  (it "names the commit subject on success and git's own first line on failure"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (outcome nil))
        (setf nerimux::*clients* (list conn))
        (multiple-value-bind (repository ignored-worktree ignored-conn)
            (%make-worktree-operation-fixture)
          (declare (ignore ignored-worktree ignored-conn))
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () t))
               (nerimux::%refresh-client-picker
                 (lambda (ignored-connection)
                   (declare (ignore ignored-connection))))
               (nerimux/vcs:git-write-operation-async
                 (lambda (received operation args &key on-complete on-error
                                   callback-dispatch)
                   (declare (ignore received operation args on-error
                                    callback-dispatch))
                   (funcall on-complete t "[main abc1234] subject line"))))
            (nerimux::%run-transient-git-write
             conn repository :commit
             (list "--message"
                   (format nil "subject line~%~%body line two")))
            (setf outcome (first (nerimux::client-conn-message-log conn)))
            (expect (string= "committed: subject line" outcome))
            (expect (null (find #\Newline
                                (first (first (nerimux::client-conn-process-log
                                               conn)))))))))))

  (it "steps back one level on q and closes the whole stack on Esc"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil))
        (setf nerimux::*clients* (list conn))
        (multiple-value-bind (repository worktree ignored-conn)
            (%make-worktree-operation-fixture)
          (declare (ignore repository ignored-conn))
          (nerimux::%set-client-selected-tree-object conn worktree)
          (setf (nerimux::client-conn-view conn) :status)
          (nerimux::%open-client-transient conn #\?)
          (nerimux::%handle-multi-key-message s conn #(99))
          (expect (string= "Commit"
                           (nerimux/renderer:transient-view-title
                            (nerimux::client-conn-transient-view conn))))
          (nerimux::%handle-multi-key-message s conn #(113))
          (expect (string= "Dispatch"
                           (nerimux/renderer:transient-view-title
                            (nerimux::client-conn-transient-view conn))))
          (nerimux::%handle-multi-key-message s conn #(113))
          (expect (null (nerimux::client-conn-transient-view conn)))
          (nerimux::%open-client-transient conn #\?)
          (nerimux::%handle-multi-key-message s conn #(99))
          (nerimux::%handle-multi-key-message s conn #(27))
          (expect (null (nerimux::client-conn-transient-view conn)))))))

  (it "opens the branch and tag listings as read views"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil))
        (setf nerimux::*clients* (list conn))
        (multiple-value-bind (repository worktree ignored-conn)
            (%make-worktree-operation-fixture)
          (declare (ignore repository ignored-conn))
          (nerimux::%set-client-selected-tree-object conn worktree)
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () t))
               (nerimux/vcs:read-worktree-branches-async
                 (lambda (received &key on-complete on-error callback-dispatch)
                   (declare (ignore received on-error callback-dispatch))
                   (funcall on-complete (format nil "* main -> origin/main~%"))))
               (nerimux/vcs:read-worktree-tags-async
                 (lambda (received &key on-complete on-error callback-dispatch)
                   (declare (ignore received on-error callback-dispatch))
                   (funcall on-complete (format nil "v1.0 first release~%")))))
            (nerimux::%open-client-read-view conn :branches)
            (expect (eq :read-view (nerimux::client-conn-modal conn)))
            (expect (string= "GIT BRANCHES"
                             (nerimux/renderer:read-view-title
                              (nerimux::client-conn-read-view conn))))
            (expect (search "origin/main"
                            (nerimux/renderer:read-view-content
                             (nerimux::client-conn-read-view conn))))
            (nerimux::%close-client-read-view conn)
            (nerimux::%open-client-read-view conn :tags)
            (expect (string= "GIT TAGS"
                             (nerimux/renderer:read-view-title
                              (nerimux::client-conn-read-view conn))))
            (expect (search "v1.0"
                            (nerimux/renderer:read-view-content
                             (nerimux::client-conn-read-view conn)))))))))

  (it "confirms a branch delete before running it and merges a named branch outright"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (calls nil))
        (setf nerimux::*clients* (list conn))
        (multiple-value-bind (repository worktree ignored-conn)
            (%make-worktree-operation-fixture)
          (declare (ignore ignored-conn))
          (nerimux::%set-client-selected-tree-object conn worktree)
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () t))
               (nerimux::%refresh-client-picker
                 (lambda (ignored-connection)
                   (declare (ignore ignored-connection))))
               (nerimux/vcs:git-write-operation-async
                 (lambda (received operation args &key on-complete on-error
                                   callback-dispatch)
                   (declare (ignore on-error callback-dispatch))
                   (push (list received operation args) calls)
                   (funcall on-complete t "done"))))
            (nerimux::%open-client-text-prompt conn :branch-delete)
            (cl-tui-kit/widgets:handle-widget-event
             (nerimux::client-conn-text-prompt-widget conn)
             (cl-tui-kit/core:make-text-input-event "feature/old"))
            (nerimux::%submit-client-text-prompt conn)
            (expect (eq :confirm (nerimux::client-conn-modal conn)))
            (expect (null calls))
            (funcall (nerimux::client-conn-confirm-action conn))
            (expect (equal (list repository :branch (list "-D" "feature/old"))
                           (first calls)))
            (nerimux::%open-client-text-prompt conn :merge-branch)
            (cl-tui-kit/widgets:handle-widget-event
             (nerimux::client-conn-text-prompt-widget conn)
             (cl-tui-kit/core:make-text-input-event "feature/new"))
            (nerimux::%submit-client-text-prompt conn)
            (expect (equal (list repository :merge (list "feature/new"))
                           (first calls)))))))))
