(in-package #:nerimux/test)
(describe "server-multi-worktree-branch-picker"
  (it "branch-picker-opens-with-sanitized-filterable-candidates"
    (with-fake-session (session)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "branch-picker-org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "branch-picker-repo" :organization organization
                :specification "github.com/team/repo"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (candidates
               (list
                (list :branch (format nil "feature/control~C[31mred" (code-char 27))
                      :kind :local :worktree nil)
                (list :branch "feature/remote" :kind :remote
                      :remote "origin" :worktree :already-checked-out))))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux::%set-client-selected-tree-object conn repository)
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () t))
             (nerimux/vcs:list-worktree-branch-candidates-async
              (lambda (received-repository &key on-complete on-error
                                               callback-dispatch)
                (declare (ignore callback-dispatch))
                (expect (eq repository received-repository))
                (expect on-error)
                (funcall on-complete candidates)
                :branch-scan)))
          (nerimux::%handle-multi-key-message
           session conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
          (nerimux::%handle-multi-key-message session conn #(98))
          (expect (eq :picker (nerimux::client-conn-modal conn)))
          (let* ((items (nerimux::client-conn-picker-items conn))
                 (labels (mapcar #'nerimux/picker:picker-item-label items)))
            (expect (= 2 (length items)))
            (expect (every (lambda (item)
                             (eq :branch (nerimux/picker:picker-item-kind item)))
                           items))
            (expect (some (lambda (label) (search "feature/controlred" label))
                          labels))
            (expect (some (lambda (label) (search "in worktree" label))
                          labels))
            (expect (not (some (lambda (label)
                                 (position (code-char 27) label))
                               labels)))
            (expect (= 1
                       (length
                        (nerimux/picker:filter-global-picker-items
                         items "origin")))))))))
  (it "branch-picker-selects-local-and-remote-through-worktree-create"
    (with-fake-session (session)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "branch-picker-select-org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "branch-picker-select-repo" :organization organization
                :specification "github.com/team/repo"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (candidates
               (list (list :branch "feature/local" :kind :local :worktree nil)
                     (list :branch "feature/remote" :kind :remote
                           :remote "origin" :worktree :checked-out)))
             (calls nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux::%set-client-selected-tree-object conn repository)
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () t))
             (nerimux/vcs:list-worktree-branch-candidates-async
              (lambda (received-repository &key on-complete on-error
                                               callback-dispatch)
                (declare (ignore callback-dispatch))
                (expect (eq repository received-repository))
                (expect on-error)
                (funcall on-complete candidates)
                :branch-scan))
             (nerimux::%client-create-worktree-now
              (lambda (received-repository branch received-conn received-session
                       &rest options)
                (declare (ignore options))
                (push (list received-repository branch received-conn received-session)
                      calls)
                t)))
          (flet ((open-branch-picker ()
                   (nerimux::%handle-multi-key-message
                    session conn
                    (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
                   (nerimux::%handle-multi-key-message session conn #(98))))
            (open-branch-picker)
            (nerimux::%set-client-picker-query conn "feature/local")
            (nerimux::%handle-multi-key-message session conn #(13))
            (expect (equal (list repository "feature/local" conn session)
                           (first calls)))
            (expect (null (nerimux::client-conn-modal conn)))
            (open-branch-picker)
            (nerimux::%set-client-picker-query conn "origin/feature/remote")
            (nerimux::%handle-multi-key-message session conn #(13))
            (expect (equal (list repository "origin/feature/remote" conn session)
                           (first calls)))
            (expect (= 2 (length calls)))
            (expect (null (nerimux::client-conn-modal conn))))))))
  (it "branch-picker-preserves-raw-query-without-parsing-boolean-options"
    (with-fake-session (session)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "branch-picker-confirm-org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "branch-picker-confirm-repo" :organization organization
                :specification "github.com/team/repo"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (raw-branch "feature/raw-name")
             (create-call nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux::%set-client-selected-tree-object conn repository)
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () t))
             (nerimux/vcs:list-worktree-branch-candidates-async
              (lambda (received-repository &key on-complete on-error
                                               callback-dispatch)
                (declare (ignore received-repository on-error callback-dispatch))
                (funcall on-complete nil)
                :branch-scan))
             (nerimux/vcs:create-worktree-async
              (lambda (received-repository &key branch path force on-complete on-error
                                                   callback-dispatch &allow-other-keys)
                (declare (ignore path on-complete on-error callback-dispatch))
                (setf create-call (list received-repository branch force))
                t)))
          (nerimux::%handle-multi-key-message
           session conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
          (nerimux::%handle-multi-key-message session conn #(98))
          (nerimux::%set-client-picker-query conn raw-branch)
          (nerimux::%handle-multi-key-message session conn #(13))
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (expect (equal (cons "branch" raw-branch)
                         (assoc "branch"
                                (nerimux/renderer:confirm-view-fields
                                 (nerimux::client-conn-confirm-view conn))
                                :test #'string=)))
          (nerimux::%handle-multi-key-message session conn #(121))
          (expect (equal (list repository raw-branch nil) create-call))
          (expect (search "opening worktree feature/raw-name"
                          (first (nerimux::client-conn-message-log conn))))
          (expect (null (nerimux::client-conn-modal conn)))
          (let ((branch "force"))
            (setf create-call nil)
            (nerimux::%handle-multi-key-message
             session conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
            (nerimux::%handle-multi-key-message session conn #(98))
            (nerimux::%set-client-picker-query conn branch)
            (nerimux::%handle-multi-key-message session conn #(13))
            (expect (eq :confirm (nerimux::client-conn-modal conn)))
            (expect (equal (cons "branch" branch)
                           (assoc "branch"
                                  (nerimux/renderer:confirm-view-fields
                                   (nerimux::client-conn-confirm-view conn))
                                  :test #'string=)))
            (nerimux::%handle-multi-key-message session conn #(121))
            (expect (equal (list repository branch nil) create-call))
            (expect (null (nerimux::client-conn-modal conn))))
          (nerimux::%handle-multi-key-message
           session conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
          (nerimux::%handle-multi-key-message session conn #(98))
          (nerimux::%set-client-picker-query conn "-new-branch")
          (nerimux::%handle-multi-key-message session conn #(13))
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (nerimux::%handle-multi-key-message session conn #(121))
          (expect (search "a name cannot start with -"
                          (first (nerimux::client-conn-message-log conn))))
          (expect (null (nerimux::client-conn-modal conn)))))))
  (it "branch-picker-rejects-c0-c1-and-bidi-controls-before-confirmation"
    (with-fake-session (session)
      (let* ((repository
               (nerimux/workspace-model:make-repository
                :id "branch-picker-invalid-query-repo"
                :specification "github.com/team/repo"))
             (conn (%make-test-conn))
             (confirmation-count 0)
             (notification nil))
        (with-stubbed-fdefinition
            ((nerimux::%close-client-picker
              (lambda (connection &key keep-view session)
                (declare (ignore connection keep-view session))
                t))
             (nerimux::%open-confirm-view
              (lambda (&rest arguments)
                (declare (ignore arguments))
                (incf confirmation-count)
                t))
             (nerimux::%client-notify
              (lambda (connection message)
                (declare (ignore connection))
                (setf notification message)
                t)))
          (dolist (code
                   (list #x0001 #x001b #x0085 #x061c #x200e #x200f
                         #x202a #x202b #x202c #x202d #x202e
                         #x2066 #x2067 #x2068 #x2069))
            (setf confirmation-count 0
                  notification nil
                  (nerimux::client-conn-picker-repository conn) repository
                  (nerimux::client-conn-picker-query conn)
                  (format nil "feature/~Cbranch" (code-char code)))
            (expect
             (null (nerimux::%select-client-branch-picker-item
                    session conn nil)))
            (expect (zerop confirmation-count))
            (expect
             (search "branch name contains control characters"
                     notification))))))));


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

  (it "colon-kill-refused-by-the-pane-rule-reports-and-keeps-the-client"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (frames nil)
            (drops nil))
        (setf nerimux::*clients* (list conn))
        (with-stubbed-fdefinition
            ((nerimux::%server-kill-request
              (lambda (session force)
                (declare (ignore session force))
                (values :denied '("pane 1 (pid 24433)" "pane 2 (pid 39885)"))))
             (nerimux::send-frame
              (lambda (stream frame) (push (list stream frame) frames)))
             (nerimux::%drop-client
              (lambda (client) (push client drops))))
          (let ((nerimux::*client-command-line-p* t))
            (expect (eq t (nerimux::%handle-client-ui-command
                           s conn :kill nil nil))))
          (expect (null drops))
          (expect (null frames))
          (expect (string= "kill refused: 2 panes still open, retry with :kill --force"
                           (first (nerimux::client-conn-message-log conn))))))))

  (it "colon-kill-accepted-still-stops-the-server"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (drops nil))
        (with-stubbed-fdefinition
            ((nerimux::%server-kill-request
              (lambda (session force)
                (declare (ignore session force))
                (values :ok nil)))
             (nerimux::%drop-client
              (lambda (client) (push client drops))))
          (let ((nerimux::*client-command-line-p* t))
            (expect (eq :quit (nerimux::%handle-client-ui-command
                               s conn :kill nil '("--force")))))
          (expect (null drops))))))

  (it "colon-workspace-prune-guides-to-w-p"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (calls nil)
            (notifications nil))
        (with-stubbed-fdefinition
            ((nerimux::%client-notify
              (lambda (client message)
                (declare (ignore client))
                (push message notifications)))
             (nerimux::%client-prune-workspaces
              (lambda (&rest arguments)
                (push arguments calls)))
             (nerimux::%confirm-client-prune-workspaces
              (lambda (&rest arguments)
                (push arguments calls))))
          (expect (eq t (nerimux::%handle-client-ui-command
                         s conn :workspace-prune nil nil)))
          (expect (equal (list "deprecated command: workspace-prune; use w p")
                         notifications))
          (expect (null calls))
          (expect (null (nerimux::client-conn-modal conn)))))))

  (it "colon-wt-complete-reports-its-outcome-and-toggles-back"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization :id "org"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "feature" :repository repository :path "/tmp/feature"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (let ((nerimux/vcs::*workspace-organizations* (list organization)))
          (nerimux::%set-client-selected-tree-object conn worktree)
          (expect (eq t (nerimux::%handle-client-ui-command
                         s conn :wt-complete nil nil)))
          (expect (nerimux/workspace-model:worktree-completed-p worktree))
          (expect (string= "marked complete"
                           (first (nerimux::client-conn-message-log conn))))
          (expect (eq t (nerimux::%handle-client-ui-command
                         s conn :wt-complete nil nil)))
          (expect (null (nerimux/workspace-model:worktree-completed-p worktree)))
          (expect (string= "completion cleared"
                           (first (nerimux::client-conn-message-log conn))))))))

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
                                callback-dispatch &allow-other-keys)
                       (declare (ignore path force on-complete on-error
                                       callback-dispatch))
                       (setf call (list received-repository branch))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
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

  (it "wt-create-command-rejects-a-branch-name-that-starts-with-a-dash"
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
                     (lambda (received-repository &key branch &allow-other-keys)
                       (setf call (list received-repository branch))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-create --branch - --confirm"
                                               :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (search "a name cannot start with -"
                               (first (nerimux::client-conn-message-log conn)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "wt-create-command-rejects-a-dash-branch-given-via-the-short-flag-form"
    ;; -b - reaches the branch through the option-value path rather than the
    ;; positional path exercised by the --branch test above; pre-existing
    ;; behaviour, not a fix -- %client-option-value already resolved "-b -"
    ;; to branch "-" before this change, this only adds coverage for it.
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
                     (lambda (received-repository &key branch &allow-other-keys)
                       (setf call (list received-repository branch))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-create -b - --confirm"
                                               :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (search "a name cannot start with -"
                               (first (nerimux::client-conn-message-log conn)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "wt-create-command-rejects-a-dash-branch-given-via-the-equals-form"
    ;; Pre-existing behaviour: %client-option-value already split "name=value"
    ;; before this change; this adds coverage for that syntax rejecting "-".
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
                     (lambda (received-repository &key branch &allow-other-keys)
                       (setf call (list received-repository branch))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-create --branch=- --confirm"
                                               :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (search "a name cannot start with -"
                               (first (nerimux::client-conn-message-log conn)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "wt-create-command-with-only-a-dash-positional-requires-a-branch"
    ;; Pre-existing behaviour: %client-positional-branch already skips any
    ;; positional token starting with -, so a bare "-" never becomes branch.
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
                     (lambda (received-repository &key branch &allow-other-keys)
                       (setf call (list received-repository branch))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-create - --confirm"
                                               :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (search "worktree create requires a branch"
                               (first (nerimux::client-conn-message-log conn)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "wt-create-command-rejects-a-path-that-starts-with-a-dash"
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
                     (lambda (received-repository &key branch &allow-other-keys)
                       (setf call (list received-repository branch))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-create --branch feature/x --path -x --confirm"
                 :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (search "a path cannot start with -"
                               (first (nerimux::client-conn-message-log conn)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "wt-create-command-rejects-a-path-that-escapes-the-repository"
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
                     (lambda (received-repository &key branch &allow-other-keys)
                       (setf call (list received-repository branch))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-create --branch feature/x --path ../../escape --confirm"
                 :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (search "path must stay under the repository"
                               (first (nerimux::client-conn-message-log conn)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "wt-create-command-rejects-a-path-that-escapes-through-a-symlinked-parent"
    (let* ((root (format nil "/tmp/nerimux-worktree-create-symlink-~D" (sb-posix:getpid)))
           (parent (format nil "~A/parent/" root))
           (outside (format nil "~A/outside/" root))
           (outside-existing (format nil "~Aexisting/" outside))
           (link (format nil "~Alink" parent))
           (candidate (format nil "~A/new-worktree" link))
           (intermediate-candidate
             (format nil "~A/existing/new-worktree" link))
           (internal-target (format nil "~Atarget/" parent))
           (internal-link (format nil "~Ainternal-link" parent))
           (internal-candidate (format nil "~A/new-worktree" internal-link))
           (canonical-internal-candidate nil)
           (accepted-candidate (format nil "~Anew-worktree" parent))
           (organization
             (nerimux/workspace-model:make-organization
              :id "org-symlink" :host "github.com" :name "team-symlink"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-symlink" :organization organization
              :specification "github.com/team-symlink/repo-symlink"))
           (conn (%make-test-conn))
           (nerimux::*clients* (list conn))
           (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
           (parent-directory (fdefinition 'nerimux/vcs:worktree-parent-directory))
           (create (fdefinition 'nerimux/vcs:create-worktree-async))
           (call nil))
      (unwind-protect
           (progn
             (ensure-directories-exist parent)
             (ensure-directories-exist outside-existing)
             (ensure-directories-exist internal-target)
             (sb-posix:symlink outside link)
             (sb-posix:symlink "target/" internal-link)
             (setf canonical-internal-candidate
                   (format nil "~Anew-worktree"
                           (namestring (truename internal-target))))
             (nerimux/workspace-model:organization-add-repository organization repository)
             (with-stubbed-fdefinition
                 ((nerimux/vcs:vcs-package-available-p (lambda () t))
                  (nerimux/vcs:worktree-parent-directory
                   (lambda (received-repository)
                     (declare (ignore received-repository))
                     parent))
                  (nerimux/vcs:create-worktree-async
                   (lambda (&rest arguments)
                     (setf call arguments)
                     t)))
               (nerimux::%set-client-selected-tree-object conn repository)
               (expect (nerimux::%handle-client-ui-command
                        nil conn :wt-create nil
                        (list "--branch" "feature/symlink-intermediate" "--path"
                              intermediate-candidate "--confirm")))
               (expect (null call))
               (expect (search "path must stay under the repository"
                               (first (nerimux::client-conn-message-log conn))))
               (setf call nil)
               (expect (nerimux::%handle-client-ui-command
                        nil conn :wt-create nil
                        (list "--branch" "feature/symlink-missing" "--path"
                              candidate "--confirm")))
               (expect (null call))
               (expect (search "path must stay under the repository"
                               (first (nerimux::client-conn-message-log conn))))
               (setf call nil)
               (expect (nerimux::%handle-client-ui-command
                        nil conn :wt-create nil
                        (list "--branch" "feature/symlink-internal" "--path"
                              internal-candidate "--confirm")))
               (expect (equal canonical-internal-candidate
                              (getf (cdr call) :path)))
               (setf call nil)
               (sb-posix:unlink internal-link)
               (sb-posix:symlink "missing/../link" internal-link)
               (expect (nerimux::%handle-client-ui-command
                        nil conn :wt-create nil
                        (list "--branch" "feature/symlink-missing-parent" "--path"
                              internal-candidate "--confirm")))
               (expect (null call))
               (expect (search "path must stay under the repository"
                               (first (nerimux::client-conn-message-log conn))))
               (expect (nerimux::%handle-client-ui-command
                        nil conn :wt-create nil
                        (list "--branch" "feature/missing" "--path"
                              accepted-candidate "--confirm")))
               (expect call)))
        (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
              (fdefinition 'nerimux/vcs:worktree-parent-directory) parent-directory
              (fdefinition 'nerimux/vcs:create-worktree-async) create)
        (ignore-errors (sb-posix:unlink link))
        (ignore-errors (sb-posix:unlink internal-link))
        (ignore-errors (sb-posix:rmdir outside-existing))
        (ignore-errors (sb-posix:rmdir outside))
        (ignore-errors (sb-posix:rmdir internal-target))
        (ignore-errors (sb-posix:rmdir (format nil "~A/parent" root)))
        (ignore-errors (sb-posix:rmdir root)))))

  (it "wt-create-command-strips-control-characters-from-the-branch-notification"
    ;; S4: %client-create-worktree-now interpolates the typed branch into
    ;; the "opening worktree ~A" notification, so an SGR sequence in the
    ;; branch must not reach the client's message strip unstripped. Dispatch
    ;; goes through %handle-client-ui-command with a pre-tokenized args list
    ;; rather than raw keystroke bytes: the byte-level command-line input
    ;; path treats a bare ESC as a key event of its own and never delivers
    ;; it as text, which would make this test pass for the wrong reason.
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
             (branch (format nil "danger~C[31mred" (code-char 27)))
             (call nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:create-worktree-async)
                     (lambda (received-repository &key branch &allow-other-keys)
                       (setf call (list received-repository branch))
                       t))
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-client-ui-command
                s conn :wt-create nil
                (list "--branch" branch "--confirm"))
               (expect (equal (list repository branch) call))
               (let ((notified (first (nerimux::client-conn-message-log conn))))
                 (expect (not (find (code-char 27) notified)))
                 (expect (not (search "[31m" notified)))
                 (expect (string= "opening worktree dangerred" notified))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "overview-worktree-delete-dispatches-and-restores-overview"
    (with-fake-session (s)
      (let* ((nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
             (organization
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
                              &key force on-complete on-error on-result callback-dispatch)
                       (declare (ignore on-complete on-error on-result callback-dispatch))
                       (setf call (list received-worktree force))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58))
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
               (expect (string= "wt-delete: add --confirm to run"
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
               (nerimux::%handle-multi-key-message s conn #(58))
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

  (it "branch-picker-requires-a-selected-repository"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil))
        (setf nerimux::*clients* (list conn))
        (setf (nerimux::client-conn-view conn) :status)
        (dolist (probe '((#(99)  . "select a repository first")
                         (#(107) . "select a worktree to delete")
                         (#(108) . "select a worktree to lock")
                         (#(117) . "select a worktree to unlock")))
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
        (nerimux::%handle-multi-key-message s conn #(98))
        (expect (search "select a repository first"
                        (first (nerimux::client-conn-message-log conn)))))))

  (it "the-w-transient-confirms-before-pruning"
    (with-fake-session (s)
      (let* ((repository (nerimux/workspace-model:make-repository
                          :id "repo" :specification "github.com/team/repo"))
             (worktree (nerimux/workspace-model:make-worktree
                        :id "wt" :repository repository :path "/tmp/wt"))
             (conn (%make-test-conn))
             (nerimux::*clients* nil)
             (prune-calls nil))
        (setf nerimux::*clients* (list conn))
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (with-stubbed-fdefinition
            ((nerimux::%client-prune-workspaces
               (lambda (received-conn &key all)
                 (push (list received-conn all) prune-calls)
                 t)))
          (setf (nerimux::client-conn-view conn) :repolist)
          (nerimux::%handle-multi-key-message
           s conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
          (nerimux::%handle-multi-key-message s conn #(112))
          (expect (string= "no workspace selected for prune"
                           (first (nerimux::client-conn-message-log conn))))
          (expect (null prune-calls))
          (nerimux::%set-client-selected-worktree conn worktree)
          (nerimux::%handle-multi-key-message
           s conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
          (nerimux::%handle-multi-key-message s conn #(112))
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (expect (null prune-calls))
          (nerimux::%handle-multi-key-message s conn #(121))
          (expect (equal (list (list conn nil)) prune-calls))
          (expect (null (nerimux::client-conn-modal conn)))))))
  (it "the-w-transient-confirms-all-before-pruning"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-prune-all" :host "github.com" :name "team-prune-all"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-prune-all" :organization organization
                :specification "github.com/team-prune-all/repo-prune-all"))
             (primary
               (nerimux/workspace-model:make-worktree
                :id "wt-primary" :repository repository
                :path "/tmp/wt-primary" :branch "main"))
             (eligible
               (nerimux/workspace-model:make-worktree
                :id "wt-eligible" :repository repository
                :path "/tmp/wt-eligible" :branch "feature/eligible"
                :completed-p t))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (prune-calls nil))
        (nerimux/workspace-model:organization-add-repository
         organization repository)
        (nerimux/workspace-model:repository-add-worktree repository primary)
        (nerimux/workspace-model:repository-add-worktree repository eligible)
        (with-stubbed-fdefinition
            ((nerimux::%client-prune-workspaces
               (lambda (received-conn &key all)
                 (push (list received-conn all) prune-calls)
                 t)))
          (setf (nerimux::client-conn-view conn) :repolist)
          (nerimux::%handle-multi-key-message
           s conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
          (nerimux::%handle-multi-key-message s conn #(80))
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (expect (null prune-calls))
          (nerimux::%handle-multi-key-message s conn #(121))
          (expect (equal (list (list conn t)) prune-calls))
          (expect (null (nerimux::client-conn-modal conn)))))))

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

  (it "overview-worktree-prune-preview-reports-the-workspace-classification"
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
             (primary
               (nerimux/workspace-model:make-worktree
                :id "primary"
                :repository repository
                :path "/tmp/primary"
                :branch "main"))
             (completed
               (nerimux/workspace-model:make-worktree
                :id "done"
                :repository repository
                :path "/tmp/done"
                :branch "feature/done"
                :completed-p t))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux::*server-sessions* nil)
             (nerimux::*workspace-cancel-reservations* (make-hash-table :test #'equal))
             (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository primary)
        (nerimux/workspace-model:repository-add-worktree repository completed)
        (setf (nerimux/workspace-model:repository-worktrees repository)
              (list primary completed)
              (nerimux/workspace-model:repository-main-worktree repository) primary)
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () t))
             (nerimux/vcs:workspace-organizations (lambda () (list organization))))
          (setf (nerimux::client-conn-view conn) :repolist)
          (nerimux::%set-client-selected-tree-object conn repository)
          (nerimux::%handle-multi-key-message s conn #(58))
          (nerimux::%handle-multi-key-message
           s conn
           (cl-codec-kit:string-to-octets "wt-prune" :encoding :utf-8))
          (nerimux::%handle-multi-key-message s conn #(13))
          (expect (string= "worktree prune preview: 1 prunable, 1 kept (main worktree)"
                           (first (nerimux::client-conn-message-log conn))))
          (expect (equal (list primary completed)
                         (nerimux/workspace-model:repository-worktrees repository)))
          (expect (null (nerimux::client-conn-modal conn)))))))

  (it "overview-worktree-prune-confirm-runs-the-workspace-prune"
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
             (completed
               (nerimux/workspace-model:make-worktree
                :id "done"
                :repository repository
                :path "/tmp/done"
                :branch "feature/done"
                :completed-p t))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux::*server-sessions* nil)
             (nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
             (nerimux::*workspace-cancel-reservations* (make-hash-table :test #'equal))
             (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
             (preflights nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository completed)
        (setf (nerimux/workspace-model:repository-main-worktree repository) nil)
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () t))
             (nerimux/vcs:workspace-organizations (lambda () (list organization)))
             (nerimux::%workspace-prune-directory-identity
              (lambda (worktree)
                (list (nerimux/workspace-model:worktree-path worktree))))
             (nerimux/vcs:read-worktree-prune-snapshot-async
              (lambda (worktree &rest options) (push (cons worktree options) preflights))))
          (setf (nerimux::client-conn-view conn) :repolist)
          (nerimux::%set-client-selected-tree-object conn repository)
          (nerimux::%handle-multi-key-message s conn #(58))
          (nerimux::%handle-multi-key-message
           s conn
           (cl-codec-kit:string-to-octets
            "wt-prune-confirm --confirm" :encoding :utf-8))
          (nerimux::%handle-multi-key-message s conn #(13))
          ;; --confirm on the `:' prompt is one gate; the confirm view's `y'
          ;; is the one that runs the job, same as `w P' -- so nothing has
          ;; preflighted yet with only the modal open.
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (expect (null preflights))
          (nerimux::%handle-multi-key-message s conn #(121))
          ;; The completed worktree reaches the same preflight `w P` runs, which
          ;; the raw `git worktree prune` this used to call never did.
          (expect (= 1 (length preflights)))
          (expect (eq completed (caar preflights)))
          (expect (nerimux::%worktree-delete-pending-p completed))
          (expect (null (nerimux::client-conn-modal conn)))))))
)

(describe "worktree-command-target-and-prune-suite"

  (it "reports a -t target that resolves to nothing and runs nothing"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-target" :host "github.com" :name "team-target"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-target" :organization organization
                :specification "github.com/team-target/repo-target"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-target" :repository repository
                :path "/tmp/wt-target" :branch "main"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (locks nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (with-stubbed-fdefinition
            ((nerimux::%client-lock-worktree
               (lambda (received-conn target args)
                 (push (list received-conn target args) locks)
                 t)))
          (expect (nerimux::%handle-client-ui-command
                   s conn :wt-lock "github.com/team-target/no-such-repo" nil))
          (expect (null locks))
          (expect (string= "target not found: github.com/team-target/no-such-repo"
                           (first (nerimux::client-conn-message-log conn))))
          (expect (nerimux::%handle-client-ui-command
                   s conn :wt-lock "/tmp/wt-target" nil))
          (expect (= 1 (length locks)))))))

  (it "counts only the worktrees a prune-all would remove"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-prune" :host "github.com" :name "team-prune"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-prune" :organization organization
                :specification "github.com/team-prune/repo-prune"))
             (kept
               (nerimux/workspace-model:make-worktree
                :id "wt-kept" :repository repository
                :path "/tmp/wt-kept" :branch "feature/kept"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (prunes nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository kept)
        (with-stubbed-fdefinition
            ((nerimux::%client-prune-workspaces
               (lambda (received-conn &key all)
                 (push (list received-conn all) prunes)
                 t)))
          (expect (nerimux::%confirm-client-prune-workspaces conn t))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (null prunes))
          (expect (string= "nothing to prune"
                           (first (nerimux::client-conn-message-log conn))))
          (let ((eligible
                  (nerimux/workspace-model:make-worktree
                   :id "wt-done" :repository repository
                   :path "/tmp/wt-done" :branch "feature/done"
                   :completed-p t)))
            (nerimux/workspace-model:repository-add-worktree repository eligible)
            (expect (nerimux::%confirm-client-prune-workspaces conn t))
            (expect (eq :confirm (nerimux::client-conn-modal conn)))
            (expect (equal (cons "workspaces" "1")
                           (assoc "workspaces"
                                  (nerimux/renderer:confirm-view-fields
                                   (nerimux::client-conn-confirm-view conn))
                                  :test #'string=)))
            (nerimux::%handle-multi-key-message s conn #(121))
            (expect (equal (list (list conn t)) prunes)))))))

  (it "excludes an attached worktree from the eligible count, matching what prune keeps"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-attached" :host "github.com" :name "team-attached"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-attached" :organization organization
                :specification "github.com/team-attached/repo-attached"))
             ;; The first worktree REPOSITORY-ADD-WORKTREE adds becomes the
             ;; repository's primary, which is always excluded, so it must not
             ;; be the worktree the assertions are about.
             (primary
               (nerimux/workspace-model:make-worktree
                :id "wt-primary" :repository repository
                :path "/tmp/wt-attached-primary" :branch "main"))
             (eligible
               (nerimux/workspace-model:make-worktree
                :id "wt-eligible" :repository repository
                :path "/tmp/wt-eligible" :branch "feature/eligible"
                :completed-p t))
             (attached
               (nerimux/workspace-model:make-worktree
                :id "wt-attached" :repository repository
                :path "/tmp/wt-attached" :branch "feature/attached"
                :completed-p t))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository primary)
        (nerimux/workspace-model:repository-add-worktree repository eligible)
        (nerimux/workspace-model:repository-add-worktree repository attached)
        (with-stubbed-fdefinition
            ((nerimux::%worktree-attached-to-clients-p
               (lambda (session worktree clients)
                 (declare (ignore session clients))
                 (eq worktree attached))))
          ;; %WORKSPACE-PRUNE-ELIGIBLE-WORKTREES used to count both -- only
          ;; classification, not %WORKSPACE-PRUNE-EXCLUSION's :attached check
          ;; -- so `w P' promised a prune the job was never going to run.
          (expect (nerimux::%confirm-client-prune-workspaces conn t))
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (expect (equal (cons "workspaces" "1")
                         (assoc "workspaces"
                                (nerimux/renderer:confirm-view-fields
                                 (nerimux::client-conn-confirm-view conn))
                                :test #'string=)))))))

  (it "names a dirty candidate in the prune confirmation instead of deleting it in silence"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-dirty" :host "github.com" :name "team-dirty"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-dirty" :organization organization
                :specification "github.com/team-dirty/repo-dirty"))
             (primary
               (nerimux/workspace-model:make-worktree
                :id "wt-primary" :repository repository
                :path "/tmp/wt-dirty-primary" :branch "main"))
             (dirty
               (nerimux/workspace-model:make-worktree
                :id "wt-dirty" :repository repository
                :path "/tmp/wt-dirty" :branch "feature/dirty"
                :completed-p t :dirty-p t))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository primary)
        (nerimux/workspace-model:repository-add-worktree repository dirty)
        (expect (nerimux::%confirm-client-prune-workspaces conn t))
        (expect (eq :confirm (nerimux::client-conn-modal conn)))
        (let ((field
                (assoc "these have uncommitted changes and will be deleted with them"
                       (nerimux/renderer:confirm-view-fields
                        (nerimux::client-conn-confirm-view conn))
                       :test #'string=)))
          (expect field)
          (expect (search "team-dirty/repo-dirty" (cdr field)))
          (expect (search "feature/dirty" (cdr field)))))))

  (it "omits the dirty-candidate line when nothing eligible is dirty"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-clean" :host "github.com" :name "team-clean"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-clean" :organization organization
                :specification "github.com/team-clean/repo-clean"))
             (primary
               (nerimux/workspace-model:make-worktree
                :id "wt-primary" :repository repository
                :path "/tmp/wt-clean-primary" :branch "main"))
             (clean
               (nerimux/workspace-model:make-worktree
                :id "wt-clean" :repository repository
                :path "/tmp/wt-clean" :branch "feature/clean"
                :completed-p t))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository primary)
        (nerimux/workspace-model:repository-add-worktree repository clean)
        (expect (nerimux::%confirm-client-prune-workspaces conn t))
        (expect (eq :confirm (nerimux::client-conn-modal conn)))
        (expect
         (null
          (assoc "these have uncommitted changes and will be deleted with them"
                 (nerimux/renderer:confirm-view-fields
                  (nerimux::client-conn-confirm-view conn))
                 :test #'string=)))))))
(describe "worktree create reuse notification"
  (it "reports that requested path and force were ignored on reuse"
    (with-fake-session (session)
      (multiple-value-bind (repository worktree conn)
          (%make-worktree-operation-fixture)
        (declare (ignore session))
        (let* ((nerimux::*workspace-operation-jobs*
                 (make-hash-table :test #'equal))
               (nerimux::*clients* (list conn))
               (create (fdefinition 'nerimux/vcs:create-worktree-async))
               (call nil))
          (unwind-protect
               (progn
                 (setf (fdefinition 'nerimux/vcs:create-worktree-async)
                       (lambda (received-repository &key path force on-complete
                                                     &allow-other-keys)
                         (setf call (list received-repository path force))
                         (funcall on-complete worktree)
                         t))
                 (nerimux::%client-create-worktree-now
                  repository "feature/errors" conn nil
                  :path "/tmp/requested-worktree" :force t)
                 (let ((notice (first (nerimux::client-conn-message-log conn))))
                   (expect (search "worktree reused" notice))
                   (expect (search "ignored --path" notice))
                   (expect (search "--force" notice)))
                 (expect
                  (equal
                   (list repository "/tmp/requested-worktree" t)
                   call)))
            (setf (fdefinition 'nerimux/vcs:create-worktree-async) create)))))))
