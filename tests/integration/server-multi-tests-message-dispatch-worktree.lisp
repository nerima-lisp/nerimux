(in-package #:nerimux/test)

(describe "server-multi-suite"

  (it "worktree-create-now-reports-synchronous-vcs-errors"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo" :organization organization
              :specification "github.com/team/repo"))
           (conn (%make-test-conn))
           (create-fn (fdefinition 'nerimux/vcs:create-worktree-async)))
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux/vcs:create-worktree-async)
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (error "synthetic create failure")))
             (expect (nerimux::%client-create-worktree-now
                      repository "feature/test" conn nil)))
        (setf (fdefinition 'nerimux/vcs:create-worktree-async) create-fn))))

  (it "worktree-create-now-focuses-the-new-worktree-in-an-active-session"
    (with-fake-session (session)
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
                :path "/tmp/feature" :branch "feature/test"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (create-fn (fdefinition 'nerimux/vcs:create-worktree-async))
             (focus-fn (fdefinition 'nerimux::%focus-selected-client-worktree))
             (focused nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:create-worktree-async)
                     (lambda (received-repository &key on-complete
                               &allow-other-keys)
                       (expect (eq repository received-repository))
                       (funcall on-complete worktree)
                       t)
                     (fdefinition 'nerimux::%focus-selected-client-worktree)
                     (lambda (received-session received-conn)
                       (setf focused (list received-session received-conn))
                       t))
               (expect (nerimux::%client-create-worktree-now
                        repository "feature/test" conn session))
               (expect (equal (list session conn) focused))
               (expect (eq worktree
                           (nerimux::client-conn-selected-worktree conn))))
          (setf (fdefinition 'nerimux/vcs:create-worktree-async) create-fn
                (fdefinition 'nerimux::%focus-selected-client-worktree) focus-fn)))))

  (it "overview-worktree-prune-confirm-without-confirm-is-rejected"
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
                       (funcall on-complete "")
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-prune-confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (string= "worktree prune requires --confirm"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (equal (list worktree)
                              (nerimux/workspace-model:repository-worktrees repository)))
               (expect (nerimux::%client-ui-keys-p conn)))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  (it "overview-worktree-prune-confirm-without-preview-is-rejected"
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
                (cl-codec-kit:string-to-octets
                 "wt-prune-confirm --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect
                (string=
                 "worktree prune requires a preview first: run wt-prune, then wt-prune-confirm --confirm"
                 (first (nerimux::client-conn-message-log conn))))
               (expect (equal (list worktree)
                              (nerimux/workspace-model:repository-worktrees repository)))
               (expect (nerimux::%client-ui-keys-p conn)))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  (it "multi-picker-regex-toggle-is-client-local"
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
                :branch "feature/picker"))
             (conn (%make-test-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-query conn) "feature/.+")
        (expect (null (nerimux::client-conn-picker-regex-p conn)))
        (expect (null (nerimux::%client-picker-visible-items conn)))
        (nerimux::%handle-multi-key-message s conn #(18))
        (expect (nerimux::client-conn-picker-regex-p conn))
        (expect (= 1 (length (nerimux::%client-picker-visible-items conn))))
        (expect (nerimux::%handle-client-ui-command
                 s conn :picker-regex "off" nil))
        (expect (null (nerimux::client-conn-picker-regex-p conn)))
        (expect (null (nerimux::%client-picker-visible-items conn))))))

  (it "multi-picker-key-input-filters-by-query-and-selects-worktree"
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
                :branch "feature/picker"))
             (conn (%make-test-conn))
             (pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s))))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux/pane:worktree-add-pane worktree pane)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (loop for character across "feature"
              do (nerimux::%handle-multi-key-message
                  s conn (vector (char-code character))))
        (expect (string= "feature" (nerimux::client-conn-picker-query conn)))
        (expect (= 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq pane (nerimux::client-conn-focus conn))))))

)
