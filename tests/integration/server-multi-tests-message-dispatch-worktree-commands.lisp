(in-package #:nerimux/test)

(describe "server-multi-worktree-command-suite"
  (it "kill-command-replies-drops-client-and-forwards-success"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (requests nil)
            (frames nil)
            (drops nil))
        (with-stubbed-fdefinition
            ((nerimux::%server-kill-request
              (lambda (session force)
                (push (list session force) requests)
                (values :ok nil)))
             (nerimux::send-frame
              (lambda (stream frame)
                (push (list stream frame) frames)))
             (nerimux::%drop-client
              (lambda (client)
                (push client drops))))
          (expect (eq :quit
                      (nerimux::%handle-client-ui-command
                       s conn :kill nil '("--force"))))
          (expect (equal (list (list s t)) requests))
          (expect (equal (list conn) drops))
          (expect (= 1 (length frames)))))))

  (it "kill-command-replies-denied-and-still-drops-client"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (frames nil)
            (drops nil))
        (with-stubbed-fdefinition
            ((nerimux::%server-kill-request
              (lambda (session force)
                (declare (ignore session force))
                (values :denied '("active clients remain"))))
             (nerimux::send-frame
              (lambda (stream frame)
                (declare (ignore stream))
                (push frame frames)))
             (nerimux::%drop-client
              (lambda (client)
                (push client drops))))
          (expect (eq t
                      (nerimux::%handle-client-ui-command
                       s conn :kill nil nil)))
          (expect (= 1 (length frames)))
          (multiple-value-bind (type payload)
              (nerimux/protocol::decode-frame (first frames))
            (expect (= nerimux::+msg-reply+ type))
            (expect (search "DENIED" (nerimux/protocol::decode-text payload))))
          (expect (equal (list conn) drops))))))

  (it "forwarded-kill-command-propagates-quit-disposition"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (with-stubbed-fdefinition
            ((nerimux::%handle-client-kill-command
              (lambda (session client args)
                (declare (ignore session client args))
                :quit)))
          (expect (eq :quit
                      (nerimux::%handle-multi-command-message
                       s conn
                       (nerimux/protocol::encode-command-payload :kill))))))))

  (it "overview-shortcut-opens-worktree-picker"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (refresh (fdefinition
                       'nerimux/vcs:refresh-workspace-organizations-async))
             (organizations (fdefinition 'nerimux/vcs:workspace-organizations)))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:workspace-organizations)
                     (lambda () nil)
                     (fdefinition
                      'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key on-complete on-error callback-dispatch)
                       (declare (ignore on-error callback-dispatch))
                       (funcall on-complete nil)))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%handle-multi-key-message s conn #(16))
               (expect (eq :picker (nerimux::client-conn-modal conn)))
               (expect (string= ""
                                (nerimux::client-conn-picker-query conn))))
          (setf (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh
                (fdefinition 'nerimux/vcs:workspace-organizations)
                organizations)))))

  (it "wt-create-command-with-an-explicit-branch-reaches-the-vcs-layer"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (create (fdefinition 'nerimux/vcs:create-worktree-async))
             (call nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:create-worktree-async)
                     (lambda (received-repository
                              &key branch path force on-complete on-error
                                callback-dispatch)
                       (declare (ignore path force on-complete on-error
                                       callback-dispatch))
                       (setf call (list received-repository branch))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58)) ; :
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-create --branch feature/explicit --confirm"
                 :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository "feature/explicit") call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "overview-worktree-delete-dispatches-and-restores-overview"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/doomed"))
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree
                              &key force on-complete on-error callback-dispatch)
                       (declare (ignore on-complete on-error callback-dispatch))
                       (setf call (list received-worktree force))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58)) ; :
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-delete --confirm" :encoding :utf-8))
               (expect (eq :command (nerimux::client-conn-modal conn)))
               (expect (string= "wt-delete --confirm"
                                (nerimux::client-conn-command-buffer conn)))
               (nerimux::%handle-multi-key-message s conn #(127))
               (expect (string= "wt-delete --confir"
                                (nerimux::client-conn-command-buffer conn)))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "m" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list worktree nil) call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn)))
               (expect (string= "" (nerimux::client-conn-command-buffer conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

  (it "overview-worktree-delete-without-confirm-is-rejected"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/no-confirm"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree
                              &key force on-complete on-error callback-dispatch)
                       (declare (ignore force on-complete on-error
                                       callback-dispatch))
                       (setf call received-worktree)
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-delete" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (string= "worktree delete requires --confirm"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

  (it "overview-worktree-delete-without-selection-is-rejected"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree
                              &key force on-complete on-error callback-dispatch)
                       (declare (ignore force on-complete on-error
                                       callback-dispatch))
                       (setf call received-worktree)
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-delete --confirm"
                 :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (string= "worktree delete requires a worktree"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))


  (it "wt-lock-and-wt-unlock-commands-reach-the-vcs-layer"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "feature" :repository repository
                :path "/tmp/feature" :branch "feature/lockme"))
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (lock-fn (fdefinition 'nerimux/vcs:lock-worktree-async))
             (unlock-fn (fdefinition 'nerimux/vcs:unlock-worktree-async))
             (lock-call nil)
             (unlock-call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:lock-worktree-async)
                     (lambda (received-worktree
                              &key reason on-complete on-error callback-dispatch)
                       (declare (ignore on-error callback-dispatch))
                       (setf lock-call (list received-worktree reason))
                       (funcall on-complete t)
                       t)
                     (fdefinition 'nerimux/vcs:unlock-worktree-async)
                     (lambda (received-worktree
                              &key on-complete on-error callback-dispatch)
                       (declare (ignore on-error callback-dispatch))
                       (setf unlock-call received-worktree)
                       (funcall on-complete t)
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58)) ; :
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-lock --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list worktree nil) lock-call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn)))
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-unlock --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (eq worktree unlock-call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:lock-worktree-async) lock-fn
                (fdefinition 'nerimux/vcs:unlock-worktree-async) unlock-fn)))))

  (it "the-w-transient-reaches-the-real-worktree-operations"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil))
        (setf nerimux::*clients* (list conn))
        (setf (nerimux::client-conn-view conn) :status)
        (dolist (probe '((#(99)  . "select a repository first")   ; w c
                         (#(107) . "select a worktree to delete") ; w k
                         (#(108) . "select a worktree to lock")   ; w l
                         (#(117) . "select a worktree to unlock"))) ; w u
          (destructuring-bind (key . expected) probe
            (nerimux::%handle-multi-key-message
             s conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
            (expect (eq :transient (nerimux::client-conn-modal conn)))
            (nerimux::%handle-multi-key-message s conn key)
            (expect (string= expected
                             (first (nerimux::client-conn-message-log conn))))
            (expect (null (nerimux::client-conn-modal conn)))))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(67)) ; C
        (expect (search "wt-create"
                        (first (nerimux::client-conn-message-log conn)))))))

  (it "every-transient-call-handler-accepts-the-arguments-the-dispatcher-passes"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (checked 0))
        (setf nerimux::*clients* (list conn))
        (dolist (definition nerimux::+transient-definitions+)
          (destructuring-bind (title arguments actions) (cdr definition)
            (declare (ignore title arguments))
            (dolist (action actions)
              (let ((handler (third action)))
                (when (eq :call (first handler))
                  (incf checked)
                  (funcall (second handler) s conn))))))
        (expect (plusp checked)))))

  (it "overview-worktree-prune-preview-does-not-mutate"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "stale"
                :repository repository
                :path "/tmp/stale"
                :branch "feature/stale"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (prune-fn (fdefinition 'nerimux/vcs:prune-worktrees-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error
                                callback-dispatch)
                       (declare (ignore verbose on-error callback-dispatch))
                       (setf call (list received-repository dry-run))
                       (unless dry-run
                         (setf (nerimux/workspace-model:repository-worktrees
                                received-repository)
                               nil))
                       (funcall on-complete "Would remove /tmp/stale")
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-prune" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository t) call))
               (expect (equal (list worktree)
                              (nerimux/workspace-model:repository-worktrees repository)))
               (expect (string= "worktree prune preview: Would remove /tmp/stale"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  (it "overview-worktree-prune-confirm-mutates"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "stale"
                :repository repository
                :path "/tmp/stale"
                :branch "feature/stale"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (prune-fn (fdefinition 'nerimux/vcs:prune-worktrees-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error
                                callback-dispatch)
                       (declare (ignore verbose on-error callback-dispatch))
                       (setf call (list received-repository dry-run))
                       (unless dry-run
                         (setf (nerimux/workspace-model:repository-worktrees
                                received-repository)
                               nil))
                       (funcall on-complete "")
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-prune" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository t) call))
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-prune-confirm --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository nil) call))
               (expect (null (nerimux/workspace-model:repository-worktrees repository)))
               (expect (string= "worktrees pruned"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

)
