(in-package #:nerimux/test)

(defun %attach-fixture (&key (specification "github.com/team/widget")
                             worktree-path)
  "An organization holding one repository, and a worktree when PATH is given."
  (let* ((organization
          (nerimux/workspace-model:make-organization :id
                                                     "org"
                                                     :host
                                                     "github.com"
                                                     :name
                                                     "team"))
         (repository
          (nerimux/workspace-model:make-repository :id
                                                   "repo"
                                                   :organization
                                                   organization
                                                   :specification
                                                   specification)))
    (nerimux/workspace-model:organization-add-repository organization
                                                         repository)
    (when worktree-path
      (nerimux/workspace-model:repository-add-worktree repository
                                                       (nerimux/workspace-model:make-worktree
                                                        :id
                                                        "wt"
                                                        :repository
                                                        repository
                                                        :path
                                                        worktree-path
                                                        :branch
                                                        "main")))
    (values (list organization) repository)))

(describe "attach-selector-suite"

  (it "r7-6-a-selector-matching-both-a-repository-and-a-worktree-opens-the-picker"
    (let* ((selector "github.com/team/widget")
           (organizations (%attach-fixture :specification selector
                                           :worktree-path selector))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-target conn) selector)
      (let ((resolved (nerimux::%client-attach-selection conn organizations)))
        (expect (null resolved)
                )
        (expect (eq :picker (nerimux::client-conn-modal conn)))
        (expect (string= selector (nerimux::client-conn-picker-query conn))
                ))))

  (it "r7-6-an-unambiguous-worktree-selector-attaches-without-a-picker"
    (let* ((organizations (%attach-fixture :worktree-path "/tmp/only-a-worktree"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-target conn) "/tmp/only-a-worktree")
      (let ((resolved (nerimux::%client-attach-selection conn organizations)))
        (expect resolved)
        (expect (not (eq :picker (nerimux::client-conn-modal conn)))))))

  (it "r7-6-a-repository-selector-with-no-worktree-selects-the-repository"
    (multiple-value-bind (organizations repository)
        (%attach-fixture :specification "github.com/team/widget")
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-attach-target conn) "github.com/team/widget")
        (expect (null (nerimux::%client-attach-selection conn organizations))
                )
        (expect (eq repository (nerimux::%client-tree-object conn))
                )
        (expect (not (eq :picker (nerimux::client-conn-modal conn)))
                ))))

  (it "unknown-explicit-selector-reports-not-found"
    (let* ((organizations (nth-value 0 (%attach-fixture)))
           (selector "github.com/team/missing")
           (conn (%make-test-conn)))
      (let ((nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-attach-target conn) selector)
        (expect (null (nerimux::%client-attach-selection conn organizations)))
        (expect (search "attach target not found: github.com/team/missing"
                        (first (nerimux::client-conn-message-log conn)))))))

  (it "cwd-inside-a-worktree-selects-that-worktree"
    (let* ((nerimux::*last-selected-worktree-token* nil)
           (organizations
             (%attach-fixture
              :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-cwd conn)
            "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1/src")
      (let ((resolved (nerimux::%client-attach-selection conn organizations)))
        (expect resolved)
        (expect (string= "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1"
                         (nerimux/workspace-model:worktree-path resolved))))))

  (it "cwd-that-is-an-ancestor-of-a-worktree-selects-nothing"
    (let* ((nerimux::*last-selected-worktree-token* nil)
           (organizations
             (%attach-fixture
              :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-cwd conn) "/tmp/nerimux-cwd-fixture")
      (multiple-value-bind (resolved source)
          (nerimux::%client-attach-selection conn organizations)
        (expect (null resolved))
        (expect (null source)))))

  (it "cwd-sharing-a-string-prefix-with-a-sibling-path-does-not-match"
    (let* ((nerimux::*last-selected-worktree-token* nil)
           (organizations
             (%attach-fixture :worktree-path "/tmp/nerimux-cwd-fixture/repo"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-cwd conn)
            "/tmp/nerimux-cwd-fixture/repo-extra/src")
      (expect (null (nerimux::%client-attach-selection conn organizations)))))

  (it "cwd-inside-a-nested-worktree-selects-the-most-specific-one"
    (let* ((nerimux::*last-selected-worktree-token* nil)
           (organization (nerimux/workspace-model:make-organization
                          :id "org" :host "github.com" :name "team"))
           (repository (nerimux/workspace-model:make-repository
                        :id "repo"
                        :organization organization
                        :specification "github.com/team/widget"))
           (outer (nerimux/workspace-model:make-worktree
                   :id "outer"
                   :repository repository
                   :path "/tmp/nerimux-cwd-fixture/repo/.worktrees/outer"
                   :branch "main"))
           (inner (nerimux/workspace-model:make-worktree
                   :id "inner"
                   :repository repository
                   :path "/tmp/nerimux-cwd-fixture/repo/.worktrees/outer/nested"
                   :branch "nested"))
           (conn (%make-test-conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository outer)
      (nerimux/workspace-model:repository-add-worktree repository inner)
      (setf (nerimux::client-conn-attach-cwd conn)
            "/tmp/nerimux-cwd-fixture/repo/.worktrees/outer/nested/deep")
      (let ((resolved
              (nerimux::%client-attach-selection conn (list organization))))
        (expect (eq inner resolved))))))

(describe "attach-selector-source-suite"

  (it "r7-2-source-is-explicit-for-an-explicit-selector-match"
    (let* ((organizations (%attach-fixture :worktree-path "/tmp/only-a-worktree"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-target conn) "/tmp/only-a-worktree")
      (multiple-value-bind (worktree source)
          (nerimux::%client-attach-selection conn organizations)
        (expect worktree)
        (expect (eq :explicit source)))))

  (it "r7-2-source-is-cwd-for-a-cwd-match"
    (let* ((nerimux::*last-selected-worktree-token* nil)
           (organizations
             (%attach-fixture
              :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-cwd conn)
            "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1/src")
      (multiple-value-bind (worktree source)
          (nerimux::%client-attach-selection conn organizations)
        (expect worktree)
        (expect (eq :cwd source)))))

  (it "r7-2-source-is-previous-for-a-remembered-selection-with-no-explicit-or-cwd-match"
    (let* ((organizations (%attach-fixture :worktree-path "/tmp/only-a-worktree"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* "wt"))
      (multiple-value-bind (worktree source)
          (nerimux::%client-attach-selection conn organizations)
        (expect worktree)
        (expect (eq :previous source)))))

  (it "r7-2-source-is-nil-when-nothing-matches"
    (let* ((organizations (%attach-fixture :worktree-path "/tmp/only-a-worktree"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* nil))
      (multiple-value-bind (worktree source)
          (nerimux::%client-attach-selection conn organizations)
        (expect (null worktree))
        (expect (null source))))))

(describe "attach-target-cwd-detail-jump-suite"

  (it "r7-2-a-cwd-match-through-client-attach-target-jumps-straight-to-detail"
    (let ((nerimux::*last-selected-worktree-token* nil))
      (multiple-value-bind (organizations)
          (%attach-fixture
           :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-cwd")
        (let ((worktree
                (first (nerimux/workspace-model:repository-worktrees
                        (first (nerimux/workspace-model:organization-repositories
                                (first organizations)))))))
          (multiple-value-bind (session)
              (make-single-pane-session)
            (let ((pane (first (nerimux/session:all-panes session))))
              (setf (nerimux/pane:pane-fd pane) 999)
              (nerimux/pane:worktree-add-pane worktree pane)
              (let ((conn (%make-test-conn))
                    (nerimux::*server-sessions* (list (cons "0" session)))
                    (nerimux/vcs::*workspace-organizations* organizations))
                (setf (nerimux::client-conn-view conn) :repolist)
                (nerimux::%client-attach-target
                 conn (list nil "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-cwd/src"))
                (expect (eq :pane (nerimux::client-conn-view conn))))))))))

  (it "r7-2-a-cwd-match-with-no-pane-opens-a-direct-shell"
    (let ((nerimux::*last-selected-worktree-token* nil))
      (multiple-value-bind (organizations)
          (%attach-fixture
           :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-direct")
        (let* ((repository
                 (first (nerimux/workspace-model:organization-repositories
                         (first organizations))))
               (worktree
                 (first (nerimux/workspace-model:repository-worktrees
                         repository)))
               (opened nil))
          (multiple-value-bind (session)
              (make-single-pane-session)
            (let ((pane (first (nerimux/session:all-panes session)))
                  (conn (%make-test-conn))
                  (nerimux::*server-sessions* (list (cons "0" session)))
                  (nerimux/vcs::*workspace-organizations* organizations))
              (setf (nerimux::client-conn-view conn) :repolist)
              (with-stubbed-fdefinition
                  ((nerimux::%open-client-worktree-pane
                    (lambda (s c wt &key default-command agent-kind)
                      (declare (ignore s default-command agent-kind))
                      (setf opened wt
                            (nerimux::client-conn-focus c)
                            pane)
                      t)))
                (nerimux::%client-attach-target
                 conn
                 (list nil
                       "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-direct/src")))
              (expect (eq worktree opened))
              (expect (eq :pane (nerimux::client-conn-view conn)))
              (expect (null (nerimux::client-conn-workspace-assignment conn)))))))))

  (it "r7-2-a-cwd-match-with-no-registered-session-does-not-jump-to-detail"
    (let ((nerimux::*last-selected-worktree-token* nil))
      (multiple-value-bind (organizations)
          (%attach-fixture
           :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-no-session")
        (let ((conn (%make-test-conn))
              (nerimux::*server-sessions* nil)
              (nerimux/vcs::*workspace-organizations* organizations))
          (setf (nerimux::client-conn-view conn) :repolist)
          (nerimux::%client-attach-target
           conn (list nil "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-no-session/src"))
          (expect (eq :repolist (nerimux::client-conn-view conn)))))))

  (it "r7-2-a-attach-with-no-match-leaves-focus-unset"
    (multiple-value-bind (session)
        (make-single-pane-session)
      (let ((conn (%make-test-conn))
            (nerimux::*server-sessions* (list (cons "0" session)))
            (nerimux/vcs::*workspace-organizations* nil))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%client-attach-target conn '(nil nil))
        (expect (null (nerimux::client-conn-focus conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn))))))

  (it "r7-2-a-attach-resolves-and-merges-a-fresh-cwd-catalog"
    (multiple-value-bind (organizations)
        (%attach-fixture
         :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-resolved")
      (multiple-value-bind (session)
          (make-single-pane-session)
        (let ((conn (%make-test-conn))
              (nerimux::*server-sessions* (list (cons "0" session)))
              (nerimux/vcs::*workspace-organizations* nil)
              (resolver
                (make-mock-function
                 (lambda (directory)
                   (expect (string= "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-resolved/src"
                                    directory))
                   organizations))))
          (setf (nerimux::client-conn-view conn) :repolist)
          (with-mocked-functions
              (((fdefinition 'nerimux/vcs:resolve-directory-organizations)
                 resolver))
            (nerimux::%client-attach-target
             conn
             (list nil
                   "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-resolved/src")))
          (expect (equal organizations
                          (nerimux/vcs:workspace-organizations)))
          (expect (eq :repolist (nerimux::client-conn-view conn))))))))

(describe "attach-selector-consumption-suite"

  (it "an-ambiguous-selector-opens-the-picker-once-and-consumes-the-selector"
    (let* ((selector "github.com/team/widget")
           (organizations (%attach-fixture :specification selector
                                           :worktree-path selector))
           (conn (%make-test-conn))
           (nerimux::*clients* (list conn)))
      (setf (nerimux::client-conn-attach-target conn) selector)
      (nerimux::%client-attach-selection conn organizations)
      (expect (eq :picker (nerimux::client-conn-modal conn)))
      (expect (null (nerimux::client-conn-attach-target conn)))
      (nerimux::%set-client-modal conn nil)
      (nerimux::%rebind-client-selection conn organizations)
      (expect (null (nerimux::client-conn-modal conn)))))

  (it "an-explicit-selector-that-matches-nothing-keeps-the-previous-selection-out-of-it"
    (let* ((organizations (%attach-fixture :worktree-path "/tmp/only-a-worktree"))
           (conn (%make-test-conn))
           (nerimux::*clients* (list conn))
           (nerimux::*last-selected-worktree-token* "wt"))
      (setf (nerimux::client-conn-attach-target conn) "github.com/team/missing")
      (multiple-value-bind (worktree source)
          (nerimux::%client-attach-selection conn organizations)
        (expect (null worktree))
        (expect (null source)))
      (expect (null (nerimux::client-conn-selected-worktree conn)))
      (expect (search "attach target not found: github.com/team/missing"
                      (first (nerimux::client-conn-message-log conn))))))

  (it "an-explicit-path-selector-that-matches-nothing-keeps-the-cwd-out-of-it"
    (let* ((organizations
             (%attach-fixture
              :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1"))
           (conn (%make-test-conn))
           (nerimux::*clients* (list conn))
           (nerimux::*last-selected-worktree-token* nil))
      (setf (nerimux::client-conn-attach-target conn) "/no/such/worktree/xyz"
            (nerimux::client-conn-attach-cwd conn)
            "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1/src")
      (expect (null (nerimux::%client-attach-selection conn organizations)))
      (expect (null (nerimux::client-conn-selected-worktree conn)))
      (expect (search "attach target not found: /no/such/worktree/xyz"
                      (first (nerimux::client-conn-message-log conn))))))

  (it "a-bare-repository-resolves-by-the-name-the-tree-shows"
    (multiple-value-bind (organizations repository)
        (%attach-fixture :specification "github.com/team/widget.git")
      (expect (eq repository
                  (nerimux::%workspace-find-repository-for-attach
                   "github.com/team/widget" organizations)))
      (expect (eq repository
                  (nerimux::%workspace-find-repository-for-attach
                   "github.com/team/widget.git" organizations)))))

  (it "a-mixed-case-dot-git-suffix-resolves-as-an-attach-selector"
    ;; D4: the three strippers used to disagree on case, so a `.GIT' clone
    ;; displayed stripped in the tree but did not resolve back as a selector.
    (multiple-value-bind (organizations repository)
        (%attach-fixture :specification "github.com/team/widget.GIT")
      (expect (eq repository
                  (nerimux::%workspace-find-repository-for-attach
                   "github.com/team/widget" organizations)))
      (expect (eq repository
                  (nerimux::%workspace-find-repository-for-attach
                   "github.com/team/widget.GIT" organizations)))))

  (it "a-path-selector-resolves-through-a-symlinked-parent"
    (let* ((root (format nil "/tmp/nerimux-symlink-fixture-~D" (sb-posix:getpid)))
           (real (format nil "~A/real" root))
           (link (format nil "~A/link" root)))
      (unwind-protect
           (progn
             (ensure-directories-exist (format nil "~A/worktree/" real))
             (ignore-errors (sb-posix:unlink link))
             (sb-posix:symlink real link)
             (let* ((organizations
                      (%attach-fixture
                       :worktree-path (format nil "~A/worktree" real)))
                    (conn (%make-test-conn)))
               (setf (nerimux::client-conn-attach-target conn)
                     (format nil "~A/worktree" link))
               (let ((resolved
                       (nerimux::%client-attach-selection conn organizations)))
                 (expect resolved)
                 (expect (string= (format nil "~A/worktree" real)
                                  (nerimux/workspace-model:worktree-path
                                   resolved))))))
        (ignore-errors (sb-posix:unlink link))
        (ignore-errors (sb-posix:rmdir (format nil "~A/worktree" real)))
        (ignore-errors (sb-posix:rmdir real))
        (ignore-errors (sb-posix:rmdir root)))))

  (it "attach-with-no-selector-and-no-remembered-selection-selects-the-first-row"
    (let* ((organizations (%attach-fixture :worktree-path "/tmp/only-a-worktree"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* nil))
      (expect (null (nerimux::%client-attach-selection conn organizations)))
      (expect (nerimux::client-conn-selected-tree-object conn)))))
