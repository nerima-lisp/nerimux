(in-package #:nerimux/test)

(describe "server-multi-suite"
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

  (it "overview-tree-filter-key-enters-filter-mode-without-forcing-pane-view"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :filter (nerimux::client-conn-modal conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (setf (nerimux::client-conn-tree-scroll conn) 7)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "ab" :encoding :utf-8))
        (expect (string= "ab" (nerimux::client-conn-tree-filter conn)))
        (expect (zerop (nerimux::client-conn-tree-scroll conn)))
        (setf (nerimux::client-conn-tree-scroll conn) 3)
        (nerimux::%handle-multi-key-message s conn #(8))
        (expect (string= "a" (nerimux::client-conn-tree-filter conn)))
        (expect (zerop (nerimux::client-conn-tree-scroll conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "xyz" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (string= "xyz" (nerimux::client-conn-tree-filter conn))))))

  (it "overview-tree-filter-key-starts-empty-again-after-a-previous-accept"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "abc" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (string= "abc" (nerimux::client-conn-tree-filter conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :filter (nerimux::client-conn-modal conn)))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "z" :encoding :utf-8))
        (expect (string= "z" (nerimux::client-conn-tree-filter conn))))))

  (it "overview-tree-filter-mode-absorbs-np-as-query-text-not-navigation"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-np-absorb" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-np-absorb" :organization organization
                :specification "github.com/team/repo-np-absorb"))
             (conn (%make-test-conn))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn repository)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :filter (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "np" :encoding :utf-8))
        (expect (string= "np" (nerimux::client-conn-tree-filter conn)))
        (expect (eq repository (nerimux::client-conn-selected-tree-object conn))))))

  (it "overview-tree-filter-editing-rejects-invalid-input-and-respects-the-cap"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-tree-filter conn) nil
              (nerimux::client-conn-tree-scroll conn) 4)
        (expect (null (nerimux::%client-tree-filter-buffer-delete-character conn)))
        (expect (null (nerimux::%client-tree-filter-buffer-append conn #(1))))
        (expect (null (nerimux::%client-tree-filter-buffer-append conn #(10))))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        (setf (nerimux::client-conn-tree-filter conn)
              (make-string nerimux::+max-tree-filter-length+
                           :initial-element #\x))
        (expect (null (nerimux::%client-tree-filter-buffer-append conn #(121))))
        (expect (= nerimux::+max-tree-filter-length+
                   (length (nerimux::client-conn-tree-filter conn)))))))


  (it "tree-top-and-tree-bottom-commands-use-the-filtered-row-set"
    (with-fake-session (s)
      (let* ((org-noise
               (nerimux/workspace-model:make-organization
                :id "org-top-bottom-noise" :host "github.com" :name "noise"))
             (org-buried
               (nerimux/workspace-model:make-organization
                :id "org-top-bottom-buried" :host "github.com" :name "buried"))
             (repo-noise
               (nerimux/workspace-model:make-repository
                :id "repo-top-bottom-noise" :organization org-noise
                :specification "github.com/noise/repo"))
             (repo-buried
               (nerimux/workspace-model:make-repository
                :id "repo-top-bottom-buried" :organization org-buried
                :specification "github.com/buried/repo"))
             (worktree-noise
               (nerimux/workspace-model:make-worktree
                :id "wt-top-bottom-noise" :repository repo-noise
                :path "/tmp/top-bottom-noise" :branch "attention-noise"
                :dirty-p t))
             (worktree-buried
               (nerimux/workspace-model:make-worktree
                :id "wt-top-bottom-buried" :repository repo-buried
                :path "/tmp/top-bottom-buried" :branch "only-match"))
             (conn (%make-test-conn))
             (nerimux/vcs::*workspace-organizations*
               (list org-noise org-buried)))
        (nerimux/workspace-model:organization-add-repository org-noise repo-noise)
        (nerimux/workspace-model:organization-add-repository org-buried repo-buried)
        (nerimux/workspace-model:repository-add-worktree repo-noise worktree-noise)
        (nerimux/workspace-model:repository-add-worktree repo-buried worktree-buried)
        (expect (nerimux::%handle-client-ui-command s conn :tree-top nil nil))
        (expect (eq :attention (nerimux::client-conn-selected-tree-object conn)))
        (expect (nerimux::%handle-client-ui-command s conn :tree-bottom nil nil))
        (expect (eq repo-buried (nerimux::client-conn-selected-tree-object conn)))
        (setf (nerimux::client-conn-tree-filter conn) "only-match")
        (expect (nerimux::%handle-client-ui-command s conn :tree-top nil nil))
        (expect (eq :repositories (nerimux::client-conn-selected-tree-object conn)))
        (expect (nerimux::%handle-client-ui-command s conn :tree-bottom nil nil))
        (expect (eq worktree-buried (nerimux::client-conn-selected-tree-object conn))))))

  (it "tab-key-toggles-the-selected-section-header-and-repository-row"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-tab" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-tab" :organization organization
                :specification "github.com/team/repo-tab"))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn :repositories)
        (nerimux::%handle-multi-key-message s conn #(9))
        (expect (gethash (list :section :repositories)
                         nerimux::*workspace-collapsed-node-ids*))
        (nerimux::%handle-multi-key-message s conn #(9))
        (expect (null (gethash (list :section :repositories)
                               nerimux::*workspace-collapsed-node-ids*)))
        (nerimux::%set-client-selected-tree-object conn repository)
        (nerimux::%handle-multi-key-message s conn #(9))
        (expect (gethash (list :repository (nerimux/workspace-model:repository-id repository))
                         nerimux::*workspace-expanded-node-ids*)))))

  (it "h-and-l-toggle-the-selected-organization-row"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-hl" :host "github.com" :name "team"))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn organization)
        (nerimux::%client-tree-collapse-selected conn)
        (expect (gethash (list :organization
                               (nerimux/workspace-model:organization-id organization))
                         nerimux::*workspace-collapsed-node-ids*))
        (nerimux::%client-tree-expand-selected conn)
        (expect (null (gethash (list :organization
                                     (nerimux/workspace-model:organization-id organization))
                               nerimux::*workspace-collapsed-node-ids*))))))

  (it "meta-n-and-meta-p-jump-the-selection-across-section-headers"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-mnp-keys" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-mnp-keys" :organization organization
                :specification "github.com/team/repo-mnp-keys"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-mnp-keys" :repository repository :path "/tmp/mnp-keys"
                :branch "mnp-keys" :dirty-p t))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (nerimux::%handle-multi-key-message s conn #(27))
        (nerimux::%handle-multi-key-message s conn #(110))
        (expect (eq :repositories (nerimux::client-conn-selected-tree-object conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (nerimux::%handle-multi-key-message s conn #(112))
        (expect (eq :attention (nerimux::client-conn-selected-tree-object conn))))))

  (it "tab-key-expands-and-collapses-a-worktree-rows-inline-detail"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-tab-wt" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-tab-wt" :organization organization
                :specification "github.com/team/repo-tab-wt"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-tab-wt" :repository repository :path "/tmp/tab-wt"
                :branch "tab-wt" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (flet ((entries ()
                 (nerimux/renderer::%workspace-flat-tree-entries
                  (list organization) nerimux::*workspace-collapsed-node-ids*
                  :expanded-node-ids nerimux::*workspace-expanded-node-ids*)))
          (expect (null (find :file (entries) :key #'fourth)))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                           nerimux::*workspace-expanded-node-ids*))
          (let ((file-entry (find :file (entries) :key #'fourth)))
            (expect file-entry)
            (expect (equal (list :file (nerimux/workspace-model:worktree-id worktree)
                                 "src/foo.lisp" " M")
                           (third file-entry))))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (null (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                                 nerimux::*workspace-expanded-node-ids*)))
          (expect (null (find :file (entries) :key #'fourth)))))))

  (it "selection-survives-re-flatten-on-a-file-row"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-file-reflatten" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-file-reflatten" :organization organization
                :specification "github.com/team/repo-file-reflatten"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-file-reflatten" :repository repository
                :path "/tmp/file-reflatten" :branch "file-reflatten" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (file-identity
               (list :file (nerimux/workspace-model:worktree-id worktree)
                     "src/foo.lisp" " M")))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (setf (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                       nerimux::*workspace-expanded-node-ids*)
              t)
        (nerimux::%set-client-selected-tree-object conn (copy-list file-identity))
        (nerimux::%select-client-tree-relative conn 0)
        (expect (equal file-identity
                       (nerimux::client-conn-selected-tree-object conn))))))

  (it "a-file-row-selection-survives-a-catalog-refresh-rebind-by-re-anchoring-on-its-worktree"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-file-rebind" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-file-rebind" :organization organization
                :specification "github.com/team/repo-file-rebind"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-file-rebind" :repository repository
                :path "/tmp/file-rebind" :branch "file-rebind" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux::*last-selected-worktree-token* nil)
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (nerimux::%handle-multi-key-message s conn #(9)) ; Tab: expand the worktree
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "n" :encoding :utf-8)) ; move onto the :file row
        (let ((selected (nerimux::client-conn-selected-tree-object conn)))
          (expect (consp selected))
          (expect (eq :file (first selected))))
        (nerimux::%rebind-client-selection conn (list organization))
        (expect (eq worktree (nerimux::client-conn-selected-tree-object conn)))
        (expect (eq worktree (nerimux::client-conn-selected-worktree conn))))))

  (it "a-worktree-selection-survives-a-stable-id-catalog-refresh-with-fresh-structs"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-stable-refresh" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-stable-refresh" :organization organization
              :specification "github.com/team/repo-stable-refresh"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-stable-refresh" :repository repository
              :path "/tmp/stable-refresh" :branch "stable-refresh"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* nil))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (setf (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-selected-tree-object conn worktree)
      (let* ((new-worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-stable-refresh" :path "/tmp/stable-refresh"
                :branch "stable-refresh"))
             (new-repository
               (nerimux/workspace-model:make-repository
                :id "repo-stable-refresh"
                :specification "github.com/team/repo-stable-refresh"))
             (new-organization
               (nerimux/workspace-model:make-organization
                :id "org-stable-refresh" :host "github.com" :name "team")))
        (nerimux/workspace-model:organization-add-repository new-organization new-repository)
        (nerimux/workspace-model:repository-add-worktree new-repository new-worktree)
        (expect (not (eq new-worktree worktree)))
        (nerimux::%rebind-client-selection conn (list new-organization))
        (expect (eq new-worktree (nerimux::client-conn-selected-tree-object conn)))
        (expect (eq new-worktree (nerimux::client-conn-selected-worktree conn))))))

  (it "a-file-row-selection-re-anchors-onto-the-new-worktree-across-a-stable-id-refresh"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-stable-file-refresh" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-stable-file-refresh" :organization organization
              :specification "github.com/team/repo-stable-file-refresh"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-stable-file-refresh" :repository repository
              :path "/tmp/stable-file-refresh" :branch "stable-file-refresh"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* nil)
           (file-object (list :file "wt-stable-file-refresh" "src/foo.lisp" " M")))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (setf (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-selected-tree-object conn file-object)
      (let* ((new-worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-stable-file-refresh" :path "/tmp/stable-file-refresh"
                :branch "stable-file-refresh"))
             (new-repository
               (nerimux/workspace-model:make-repository
                :id "repo-stable-file-refresh"
                :specification "github.com/team/repo-stable-file-refresh"))
             (new-organization
               (nerimux/workspace-model:make-organization
                :id "org-stable-file-refresh" :host "github.com" :name "team")))
        (nerimux/workspace-model:organization-add-repository new-organization new-repository)
        (nerimux/workspace-model:repository-add-worktree new-repository new-worktree)
        (nerimux::%rebind-client-selection conn (list new-organization))
        (expect (eq new-worktree (nerimux::client-conn-selected-tree-object conn)))
        (expect (eq new-worktree (nerimux::client-conn-selected-worktree conn))))))

  (it "tab-key-on-a-file-row-expands-to-pending-and-dedups-the-fetch-across-collapse-reexpand"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-diff-tab" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-diff-tab" :organization organization
                :specification "github.com/team/repo-diff-tab"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-diff-tab" :repository repository :path "/tmp/diff-tab"
                :branch "diff-tab" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (wt-id (nerimux/workspace-model:worktree-id worktree))
             (file-object (list :file wt-id "src/foo.lisp" " M"))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (call-count 0))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn file-object)
        (with-stubbed-fdefinition
            ((nerimux/vcs:refresh-worktree-file-diff-async
               (lambda (repository worktree path &key on-complete on-error
                                                        callback-dispatch)
                 (declare (ignore repository worktree path on-complete on-error
                                  callback-dispatch))
                 (incf call-count)
                 nil)))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (gethash (list :file-diff wt-id "src/foo.lisp")
                           nerimux::*workspace-expanded-node-ids*))
          (expect (equal (list :pending 0 nil)
                         (gethash (list wt-id "src/foo.lisp")
                                  nerimux::*workspace-file-diffs*)))
          (expect (= 1 call-count))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (null (gethash (list :file-diff wt-id "src/foo.lisp")
                                 nerimux::*workspace-expanded-node-ids*)))
          (expect (equal (list :pending 0 nil)
                         (gethash (list wt-id "src/foo.lisp")
                                  nerimux::*workspace-file-diffs*)))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (gethash (list :file-diff wt-id "src/foo.lisp")
                           nerimux::*workspace-expanded-node-ids*))
          (expect (= 1 call-count))))))

  (it "tab-key-on-a-file-row-shows-cached-diff-lines-without-fetching-and-collapses-on-second-tab"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-diff-cached" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-diff-cached" :organization organization
                :specification "github.com/team/repo-diff-cached"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-diff-cached" :repository repository :path "/tmp/diff-cached"
                :branch "diff-cached" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (wt-id (nerimux/workspace-model:worktree-id worktree))
             (file-object (list :file wt-id "src/foo.lisp" " M"))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (setf (gethash (list :worktree wt-id) nerimux::*workspace-expanded-node-ids*) t)
        (setf (gethash (list wt-id "src/foo.lisp") nerimux::*workspace-file-diffs*)
              (list :ready 1 (list "+only line")))
        (nerimux::%set-client-selected-tree-object conn file-object)
        (with-stubbed-fdefinition
            ((nerimux/vcs:refresh-worktree-file-diff-async
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error "must not be reached: a :ready cache entry must not refetch"))))
          (flet ((diff-entries ()
                   (remove-if-not
                    (lambda (entry) (eq (fourth entry) :diff-line))
                    (nerimux/renderer::%workspace-flat-tree-entries
                     (list organization) nerimux::*workspace-collapsed-node-ids*
                     :expanded-node-ids nerimux::*workspace-expanded-node-ids*
                     :file-diffs nerimux::*workspace-file-diffs*))))
            (expect (null (diff-entries)))
            (nerimux::%handle-multi-key-message s conn #(9))
            (let ((entries (diff-entries)))
              (expect (= 1 (length entries)))
              (expect (string= "+only line" (second (first entries)))))
            (nerimux::%handle-multi-key-message s conn #(9))
            (expect (null (diff-entries))))))))


  (it "?-then-k-opens-the-help-view-and-swallows-other-keys-until-q-closes-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(63)) ; ?
        (expect (eq :transient (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(107)) ; k
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(110)) ; n
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(113)) ; q
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "?-then-k-also-opens-from-the-repolist-view-and-enter-or-esc-close-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(13)) ; Enter
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (nerimux::%handle-multi-key-message s conn #(27)) ; Esc
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "the rendered client frame shows the help view's sections while it is up"
    (with-fake-session (s)
      (let ((conn (%make-test-conn :rows 40 :cols 110)))
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (multiple-value-bind (type payload)
            (nerimux/protocol::decode-frame (nerimux::%render-client-frame s conn))
          (expect (= nerimux::+msg-frame+ type))
          (let ((visible (strip-sgr (nerimux/protocol::decode-text payload))))
            (expect (search "Navigate" visible))
            (expect (search "Prefix C-q" visible))
            (expect (search "Scrollback" visible))
            (expect (null (search "Modes" visible))))))))

  (it "opening a confirm-view while modal is :help replaces it outright"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn :rows 40 :cols 110))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-modal conn) :help)
        (nerimux::%open-confirm-view conn "WORKTREE DELETE"
                                     '(("worktree" . "feature/x"))
                                     (lambda () nil))
        (expect (eq :confirm (nerimux::client-conn-modal conn)))
        (multiple-value-bind (type payload)
            (nerimux/protocol::decode-frame (nerimux::%render-client-frame s conn))
          (declare (ignore type))
          (let ((visible (strip-sgr (nerimux/protocol::decode-text payload))))
            (expect (search "WORKTREE DELETE" visible))
            (expect (not (search "Prefix C-q" visible)))))
        (nerimux::%handle-multi-key-message s conn #(110)) ; n
        (expect (not (nerimux::client-conn-confirm-view conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "?-reaches-a-focused-pane-directly-in-pane-view-instead-of-opening-the-transient"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux::window-active-pane (nerimux::session-active-window s)))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 9999)
        (setf (nerimux::client-conn-view conn) :pane
              (nerimux::client-conn-focus conn) pane)
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-write
               (lambda (fd payload) (push (list fd payload) writes))))
          (nerimux::%handle-multi-key-message s conn #(63))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (equalp (list (list 9999 #(63))) writes))))))

  (it "an-ordinary-byte-reaches-a-focused-pane-directly-in-pane-view-fr-007"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux::window-active-pane (nerimux::session-active-window s)))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 9999)
        (setf (nerimux::client-conn-view conn) :pane
              (nerimux::client-conn-focus conn) pane)
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-write
               (lambda (fd payload) (push (list fd payload) writes))))
          (nerimux::%handle-multi-key-message s conn #(110)) ; n
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (eq :pane (nerimux::client-conn-view conn)))
          (expect (equalp (list (list 9999 #(110))) writes))))))

  (it "a-modal-owns-the-key-and-the-view-underneath-never-sees-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist
              (nerimux::client-conn-modal conn) :help)
        (nerimux::%handle-multi-key-message s conn #(110)) ; n: "next row" in :repolist
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (expect (null (nerimux::client-conn-selected-tree-object conn))))))

  (it "a single repository's status failure marks only that repository stale, not the whole catalog"
    (let* ((healthy-path (%vcs-operations-existing-path))
           (failing-path
             (namestring
              (merge-pathnames "nerimux-bug2-failing-status/"
                               (host-kit:temporary-directory))))
           (healthy-entry
             (vcs-kit:make-ghq-repository-entry
              :specification "bug2-host/team/healthy" :path healthy-path))
           (failing-entry
             (vcs-kit:make-ghq-repository-entry
              :specification "bug2-host/team/failing" :path failing-path))
           (available (fdefinition 'nerimux/vcs:vcs-package-available-p)))
      (ensure-directories-exist failing-path)
      (let ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* nil)
            (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
            (nerimux::*workspace-file-diffs-order* nil)
            (conn (nerimux::%make-client-conn)))
        (unwind-protect
             (progn
               (setf nerimux::*main-thread-callbacks* nil)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t))
               (with-stubbed-fdefinition
                   ((vcs-kit:ghq-list-repositories
                      (lambda (&key query)
                        (declare (ignore query))
                        (list healthy-entry failing-entry)))
                    (vcs-kit:make-vcs-repository
                      (lambda (directory &rest arguments)
                        (declare (ignore arguments))
                        directory))
                    (vcs-kit:vcs-list-worktrees
                      (lambda (directory)
                        (list (%vcs-operations-fake-worktree
                               directory :branch "main" :head "head"))))
                    (vcs-kit:vcs-status-structured
                      (lambda (directory &rest arguments)
                        (declare (ignore arguments))
                        (if (string= directory failing-path)
                            (error "synthetic status failure for BUG-2")
                            (%vcs-operations-status-snapshot
                             :branch-head "head" :ahead 0 :behind 0)))))
                 (nerimux::%refresh-client-picker conn)
                 (let ((deadline (+ (get-internal-real-time)
                                    (* 2 internal-time-units-per-second))))
                   (loop until (and (plusp (length (nerimux/vcs:workspace-organizations)))
                                    (zerop (hash-table-count
                                            nerimux::*workspace-refreshing-ids*)))
                         while (< (get-internal-real-time) deadline)
                         do (nerimux::%drain-main-thread-callbacks)
                            (sleep 0.01))
                   (nerimux::%drain-main-thread-callbacks))
                 (expect (plusp (length (nerimux/vcs:workspace-organizations))))
                 (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
                 (let* ((organizations (nerimux/vcs:workspace-organizations))
                        (repositories
                          (and organizations
                               (nerimux/workspace-model:organization-repositories
                                (first organizations))))
                        (healthy-repository
                          (find healthy-path repositories
                                :key #'nerimux/workspace-model:repository-local-path
                                :test #'string=))
                        (failing-repository
                          (find failing-path repositories
                                :key #'nerimux/workspace-model:repository-local-path
                                :test #'string=)))
                   (expect healthy-repository)
                   (expect failing-repository)
                   (expect (gethash (list :repository
                                          (nerimux/workspace-model:repository-id
                                           failing-repository))
                                    nerimux::*workspace-stale-ids*))
                   (dolist (worktree (nerimux/workspace-model:repository-worktrees
                                      failing-repository))
                     (expect (gethash (list :worktree
                                            (nerimux/workspace-model:worktree-id worktree))
                                      nerimux::*workspace-stale-ids*)))
                   (expect (not (gethash (list :repository
                                               (nerimux/workspace-model:repository-id
                                                healthy-repository))
                                         nerimux::*workspace-stale-ids*)))
                   (dolist (worktree (nerimux/workspace-model:repository-worktrees
                                      healthy-repository))
                     (expect (not (gethash (list :worktree
                                                 (nerimux/workspace-model:worktree-id worktree))
                                           nerimux::*workspace-stale-ids*)))))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available)
          (setf nerimux::*main-thread-callbacks* nil)
          (ignore-errors (sb-posix:rmdir failing-path))))))

  (it "status-view-discard-key-confirms-before-writing"
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
                :id "wt-discard-confirm" :repository repository
                :path "/tmp/wt-discard-confirm" :branch "main"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (calls nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :status
              (nerimux::client-conn-selected-worktree conn) worktree)
        (nerimux::%set-client-selected-tree-object
         conn (list :file "wt-discard-confirm" "src/foo.lisp" " M"))
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () nil))
             (nerimux/vcs:git-write-operation-async
               (lambda (received-repository operation arguments
                        &key callback-dispatch on-complete on-error)
                 (declare (ignore callback-dispatch on-error))
                 (push (list received-repository operation arguments) calls)
                 (when on-complete (funcall on-complete t ""))
                 t)))
          (nerimux::%handle-multi-key-message s conn "k")
          (expect (null calls))
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (expect (nerimux::client-conn-confirm-action conn))
          (nerimux::%handle-multi-key-message s conn "y")
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (equal (list (list repository :restore (list "--" "src/foo.lisp")))
                         calls)))))))
