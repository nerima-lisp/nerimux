(in-package #:nerimux/test)

(describe "server-dispatch-helper-tree-navigation-suite"

  (it "enter-on-a-repository-row-with-a-main-worktree-jumps-straight-to-its-shell"
    (with-fake-session (s)
      (let* ((pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s)))
             (organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "main" :repository repository :path "/tmp/main" :branch "main"))
             (conn (nerimux::%make-client-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux/pane:worktree-add-pane worktree pane)
        (setf (nerimux/pane:pane-fd pane) 9999) ; "live" without a real PTY
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn repository)
        (expect (nerimux::%focus-selected-client-worktree s conn))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect (eq pane (nerimux::client-conn-focus conn))))))

  (it "enter-on-a-repository-row-with-no-worktrees-notifies-instead-of-crashing"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo" :organization organization
              :specification "github.com/team/repo"))
           (conn (nerimux::%make-client-conn))
           (nerimux::*clients* (list conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (setf (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-selected-tree-object conn repository)
      (expect (eq t (nerimux::%focus-selected-client-worktree nil conn)))
      (expect (string= "repository has no worktrees"
                       (first (nerimux::client-conn-message-log conn))))
      (expect (eq :repolist (nerimux::client-conn-view conn)))))

  (it "enter-on-an-organization-row-toggles-its-collapse-state"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-toggle" :host "github.com" :name "team"))
           (conn (nerimux::%make-client-conn))
           (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
           (nerimux::*dirty* nil))
      (nerimux::%set-client-selected-tree-object conn organization)
      (expect (nerimux::%focus-selected-client-worktree nil conn))
      (expect (gethash (list :organization "org-toggle")
                       nerimux::*workspace-collapsed-node-ids*))
      (expect (nerimux::%focus-selected-client-worktree nil conn))
      (expect (null (gethash (list :organization "org-toggle")
                             nerimux::*workspace-collapsed-node-ids*)))))

  (it "enter-on-a-pane-selects-the-pane-and-enters-pane-view"
    (with-fake-session (s)
      (let* ((nerimux::*dirty* nil)
             (window (nerimux/session:session-active-window s))
             (pane (nerimux/window:window-active-pane window))
             (conn (nerimux::%make-client-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn pane)
        (expect (nerimux::%focus-selected-client-worktree s conn))
        (expect (eq pane (nerimux::client-conn-focus conn)))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect nerimux::*dirty*))))

  (it "enter-on-a-window-focuses-its-active-pane"
    (with-fake-session (s)
      (let* ((nerimux::*dirty* nil)
             (window (nerimux/session:session-active-window s))
             (pane (nerimux/window:window-active-pane window))
             (conn (nerimux::%make-client-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn window)
        (expect (nerimux::%focus-selected-client-worktree s conn))
        (expect (eq pane (nerimux::client-conn-focus conn)))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect nerimux::*dirty*))))

  (it "enter-on-an-inline-diff-row-is-a-no-op"
    (let ((conn (nerimux::%make-client-conn))
          (nerimux::*dirty* nil))
      (dolist (object '((:file "README.md")
                        (:commit "abc123")
                        (:diff-line 12)
                        (:diff-more)))
        (nerimux::%set-client-selected-tree-object conn object)
        (setf nerimux::*dirty* nil)
        (expect (nerimux::%focus-selected-client-worktree nil conn))
        (expect (null nerimux::*dirty*)))))

  (it "h-and-l-are-no-ops-on-a-selected-worktree-row"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organizations organization repository main-worktree))
      (let ((nerimux::*dirty* nil)
            (conn (nerimux::%make-client-conn)))
        (nerimux::%set-client-selected-tree-object conn feature-worktree)
        (setf nerimux::*dirty* nil)
        (expect (null (nerimux::%client-tree-collapse-selected conn)))
        (expect (null (nerimux::%client-tree-expand-selected conn)))
        (expect (eq feature-worktree (nerimux::%client-tree-object conn)))
        (expect (null nerimux::*dirty*)))))

  (it "enter-toggles-worktree-expansion-and-refreshes-missing-commits"
    (dolist (case '((nil t) (:failed t) (:ready nil)))
      (destructuring-bind (state refresh-p) case
        (let* ((worktree
                 (nerimux/workspace-model:make-worktree
                  :id (format nil "toggle-~A" state)
                  :path "/tmp/toggle" :branch "main"
                  :commits-state state))
               (conn (nerimux::%make-client-conn))
               (refreshes 0)
               (nerimux::*workspace-expanded-node-ids*
                 (make-hash-table :test #'equal))
               (nerimux::*dirty* nil))
          (nerimux::%set-client-selected-tree-object conn worktree)
          (setf nerimux::*dirty* nil)
          (with-stubbed-fdefinition
              ((nerimux::%client-start-worktree-commits-refresh
                 (lambda (selected)
                   (declare (ignore selected))
                   (incf refreshes))))
            (expect (nerimux::%client-toggle-selected-tree-row conn))
            (expect (= (if refresh-p 1 0) refreshes))
            (expect (eq (if refresh-p :pending :ready)
                        (nerimux/workspace-model:worktree-commits-state worktree)))
            (expect (gethash (list :worktree
                                   (nerimux/workspace-model:worktree-id worktree))
                             nerimux::*workspace-expanded-node-ids*))
            (expect nerimux::*dirty*))
          (setf nerimux::*dirty* nil)
          (expect (nerimux::%client-toggle-selected-tree-row conn))
          (expect (null (gethash (list :worktree
                                       (nerimux/workspace-model:worktree-id worktree))
                                 nerimux::*workspace-expanded-node-ids*)))
          (expect nerimux::*dirty*)))))

  (it "tab-toggles-file-rows-and-ignores-unknown-tree-objects"
    (let* ((conn (nerimux::%make-client-conn))
           (calls nil)
           (nerimux::*dirty* nil))
      (with-stubbed-fdefinition
          ((nerimux::%client-toggle-selected-file-diff
             (lambda (&rest arguments)
               (setf calls arguments)
               :file-handled)))
        (nerimux::%set-client-selected-tree-object
         conn '(:file "worktree-1" "src/main.lisp" "M"))
        (setf nerimux::*dirty* nil)
        (expect (eq :file-handled
                    (nerimux::%client-toggle-selected-tree-row conn)))
        (expect (equal '("worktree-1" "src/main.lisp" "M") calls))
        (nerimux::%set-client-selected-tree-object conn '(:other "value"))
        (setf nerimux::*dirty* nil)
        (expect (null (nerimux::%client-toggle-selected-tree-row conn)))
        (expect (null nerimux::*dirty*)))))

  (it "collapses-an-expanded-file-diff-row"
    (let* ((key (list :file-diff "worktree-1" "src/main.lisp"))
           (nerimux::*workspace-expanded-node-ids*
             (make-hash-table :test #'equal)))
      (setf (gethash key nerimux::*workspace-expanded-node-ids*) t)
      (expect (eq t (nerimux::%client-toggle-selected-file-diff
                     "worktree-1" "src/main.lisp" "M")))
      (expect (null (gethash key nerimux::*workspace-expanded-node-ids*)))))

  (it "expands-an-untracked-file-without-starting-a-diff-fetch"
    (let* ((key (list :file-diff "worktree-1" "untracked.lisp"))
           (nerimux::*workspace-expanded-node-ids*
             (make-hash-table :test #'equal))
           (nerimux::*workspace-file-diffs*
             (make-hash-table :test #'equal))
           (nerimux::*dirty* nil)
           (fetch-started nil))
      (with-stubbed-fdefinition
          ((nerimux::%client-start-worktree-file-diff-refresh
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (setf fetch-started t))))
        (expect (eq t (nerimux::%client-toggle-selected-file-diff
                       "worktree-1" "untracked.lisp" "??")))
        (expect (gethash key nerimux::*workspace-expanded-node-ids*))
        (expect (null fetch-started))
        (expect nerimux::*dirty*))))

  (it "h-and-l-toggle-a-repository-row-in-the-expanded-node-table"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organizations organization main-worktree feature-worktree))
      (let ((nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (conn (nerimux::%make-client-conn))
            (repo-key (list :repository (nerimux/workspace-model:repository-id repository))))
        (nerimux::%set-client-selected-tree-object conn repository)
        (expect (nerimux::%client-tree-collapse-selected conn))
        (expect (null (gethash repo-key nerimux::*workspace-expanded-node-ids*)))
        (expect (nerimux::%client-tree-expand-selected conn))
        (expect (gethash repo-key nerimux::*workspace-expanded-node-ids*))
        (expect (nerimux::%client-tree-collapse-selected conn))
        (expect (null (gethash repo-key nerimux::*workspace-expanded-node-ids*))))))

  (it "enter-on-an-expanded-repository-row-collapses-its-worktrees"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organizations organization main-worktree feature-worktree))
      (let* ((nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux::*dirty* nil)
             (conn (nerimux::%make-client-conn))
             (key (list :repository (nerimux/workspace-model:repository-id repository))))
        (nerimux::%set-client-selected-tree-object conn repository)
        (setf (gethash key nerimux::*workspace-expanded-node-ids*) t)
        (expect (nerimux::%client-toggle-selected-tree-row conn))
        (expect (null (gethash key nerimux::*workspace-expanded-node-ids*)))
        (expect nerimux::*dirty*))))

  (it "h-and-l-toggle-a-section-row"
    (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
          (nerimux::*dirty* nil)
          (conn (nerimux::%make-client-conn)))
      (nerimux::%set-client-selected-tree-object conn :repositories)
      (expect (nerimux::%client-tree-collapse-selected conn))
      (expect (gethash (list :section :repositories)
                       nerimux::*workspace-collapsed-node-ids*))
      (expect (nerimux::%client-tree-expand-selected conn))
      (expect (null (gethash (list :section :repositories)
                             nerimux::*workspace-collapsed-node-ids*)))
      (expect nerimux::*dirty*))

  (it "h-and-l-still-toggle-a-directly-selected-organization-row"
    (let ((organization
            (nerimux/workspace-model:make-organization
             :id "org-direct" :host "github.com" :name "team"))
          (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
          (nerimux::*dirty* nil)
          (conn (nerimux::%make-client-conn)))
      (nerimux::%set-client-selected-tree-object conn organization)
      (expect (nerimux::%client-tree-collapse-selected conn))
      (expect (gethash (list :organization "org-direct")
                       nerimux::*workspace-collapsed-node-ids*))
      (expect (nerimux::%client-tree-expand-selected conn))
      (expect (null (gethash (list :organization "org-direct")
                             nerimux::*workspace-collapsed-node-ids*)))
      (expect nerimux::*dirty*)))

  (it "enter-tree-filter-mode-clears-query-and-scroll"
    (let ((conn (nerimux::%make-client-conn)))
      (setf (nerimux::client-conn-tree-filter conn) "old"
            (nerimux::client-conn-tree-scroll conn) 7)
      (expect (nerimux::%client-enter-tree-filter-mode conn))
      (expect (null (nerimux::client-conn-tree-filter conn)))
      (expect (zerop (nerimux::client-conn-tree-scroll conn)))
      (expect (eq :filter (nerimux::client-conn-modal conn)))))

  (it "tree-relative-selection-empty-workspace"
    (let ((conn (nerimux::%make-client-conn))
          (nerimux/vcs::*workspace-organizations* nil)
          (nerimux::*dirty* nil))
      (expect (null (nerimux::%select-client-tree-relative conn 1)))
      (expect (null nerimux::*dirty*))))

  (it "tree-selection-logic-resolves-direction-and-scroll-bounds"
    (dolist (case '((nil (a b) 1 -1)
                   (nil (a b) -1 0)
                   (stale (a b) -1 0)
                   (stale (a b) 1 -1)
                   (a (a b) 1 1)
                   (b (a b) 1 1)))
      (destructuring-bind (current objects delta expected) case
        (expect (= expected
                   (nerimux::%tree-selection-index current objects delta)))))
    (dolist (case '((2 3 5 2)
                   (8 3 5 3)
                   (10 0 5 6)
                   (0 3 5 0)
                   (3 3 5 3)
                   (2 3 5 2)))
      (destructuring-bind (next scroll visible expected) case
        (expect (= expected
                   (nerimux::%tree-selection-scroll next scroll visible))))))

  (it "tree-selection-logic-covers-unselected-directional-fallbacks"
    (expect (= 0 (nerimux::%tree-selection-index nil '(a b) -1)))
    (expect (= -1 (nerimux::%tree-selection-index nil '(a b) 1)))
    (expect (= -1 (nerimux::%tree-selection-index nil '(a b) 0)))
    (expect (= 2 (nerimux::%tree-selection-scroll 2 3 5)))
    (expect (= 3 (nerimux::%tree-selection-scroll 8 3 5)))
    (expect (= 6 (nerimux::%tree-selection-scroll 10 0 5)))
    (expect (= 0 (nerimux::%tree-selection-scroll 5 0 10))))

  (it "tree-relative-selection-clamps-backward-movement-without-selection"
    (with-server-dispatch-helper-fixture
        (organizations organization repository main-worktree feature-worktree)
      (declare (ignorable organization repository main-worktree feature-worktree))
      (let ((conn (nerimux::%make-client-conn))
            (nerimux/vcs::*workspace-organizations* organizations)
            (nerimux::*dirty* nil))
        (setf (nerimux::client-conn-rows conn) 7)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-relative conn -1)))
        (expect (zerop (nerimux::client-conn-tree-scroll conn))))))

  (it "tree-relative-selection-starts-at-the-first-row-for-forward-movement"
    (with-server-dispatch-helper-fixture
        (organizations organization repository main-worktree feature-worktree)
      (declare (ignorable organization repository main-worktree feature-worktree))
      (let ((conn (nerimux::%make-client-conn))
            (nerimux/vcs::*workspace-organizations* organizations)
            (nerimux::*dirty* nil))
        (setf (nerimux::client-conn-rows conn) 7)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-relative conn 1))))))

  (it "tree-relative-selection-uses-directional-fallback-for-stale-selection"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((conn (nerimux::%make-client-conn))
            (nerimux/vcs::*workspace-organizations* organizations)
            (nerimux::*dirty* nil))
        (nerimux::%set-client-selected-tree-object conn :stale)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-relative conn -1))))))

  (it "tree-relative-selection-uses-forward-fallback-for-stale-selection"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((conn (nerimux::%make-client-conn))
            (nerimux/vcs::*workspace-organizations* organizations)
            (nerimux::*dirty* nil))
        (nerimux::%set-client-selected-tree-object conn :stale)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-relative conn 1))))))

  (it "tree-relative-selection-starts-and-scrolls-a-multi-row-list"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-relative" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-relative" :organization organization
              :specification "github.com/team/repo-relative"))
           (first-worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-relative-1" :repository repository :path "/tmp/relative-1"
              :branch "first" :dirty-p t))
           (second-worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-relative-2" :repository repository :path "/tmp/relative-2"
              :branch "second" :dirty-p t))
           (conn (nerimux::%make-client-conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository first-worktree)
      (nerimux/workspace-model:repository-add-worktree repository second-worktree)
      (let ((nerimux/vcs::*workspace-organizations* (list organization))
            (nerimux::*dirty* nil))
        (setf (nerimux::client-conn-rows conn) 1)
        (nerimux::%set-client-selected-tree-object conn first-worktree)
        (expect (eq second-worktree
                    (nerimux::%select-client-tree-relative conn 1)))
        (setf (nerimux::client-conn-tree-scroll conn) 3)
        (expect (eq first-worktree
                    (nerimux::%select-client-tree-relative conn -1)))
        (expect (= 1 (nerimux::client-conn-tree-scroll conn))))))

  (it "tree-relative-selection-adjusts-scroll-for-a-narrow-view"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organization main-worktree feature-worktree))
      (let ((conn (nerimux::%make-client-conn))
            (nerimux/vcs::*workspace-organizations* organizations)
            (nerimux::*dirty* nil))
        (setf (nerimux::client-conn-rows conn) 7)
        (nerimux::%set-client-selected-tree-object conn :repositories)
        (expect (eq repository
                    (nerimux::%select-client-tree-relative conn 1)))
        (expect (= 1 (nerimux::client-conn-tree-scroll conn))))))

  (it "tree-relative-selection-keeps-narrow-view-scroll-in-range"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organization repository main-worktree feature-worktree))
      (let ((conn (nerimux::%make-client-conn))
            (nerimux/vcs::*workspace-organizations* organizations)
            (nerimux::*dirty* nil))
        (setf (nerimux::client-conn-rows conn) 1
              (nerimux::client-conn-tree-scroll conn) 3)
        (nerimux::%set-client-selected-tree-object conn :repositories)
        (nerimux::%select-client-tree-relative conn -1)
        (expect (zerop (nerimux::client-conn-tree-scroll conn)))
        (nerimux::%select-client-tree-relative conn 3)
        (expect (= 3 (nerimux::client-conn-tree-scroll conn))))))

  (it "tree-relative-selection-clamps-at-both-list-ends"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-relative-edges" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-relative-edges" :organization organization
              :specification "github.com/team/repo-relative-edges"))
           (first-worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-relative-edge-1" :repository repository
              :path "/tmp/relative-edge-1" :branch "first" :dirty-p t))
           (second-worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-relative-edge-2" :repository repository
              :path "/tmp/relative-edge-2" :branch "second" :dirty-p t))
           (conn (nerimux::%make-client-conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository first-worktree)
      (nerimux/workspace-model:repository-add-worktree repository second-worktree)
      (let ((nerimux/vcs::*workspace-organizations* (list organization))
            (nerimux::*dirty* nil))
        (nerimux::%set-client-selected-tree-object conn first-worktree)
        (expect (eq first-worktree
                    (nerimux::%select-client-tree-relative conn -1)))
        (nerimux::%set-client-selected-tree-object conn second-worktree)
        (expect (eq second-worktree
                    (nerimux::%select-client-tree-relative conn 1))))))

  (it "J-jumps-the-selection-forward-to-the-next-section-header"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-jk" :host "github.com" :name "team"))
           (repo-a
             (nerimux/workspace-model:make-repository
              :id "repo-a" :organization organization
              :specification "github.com/team/repo-a"))
           (worktree-a
             (nerimux/workspace-model:make-worktree
              :id "wt-a" :repository repo-a :path "/tmp/a" :branch "a"
              :dirty-p t))
           (conn (nerimux::%make-client-conn)))
      (nerimux/workspace-model:organization-add-repository organization repo-a)
      (nerimux/workspace-model:repository-add-worktree repo-a worktree-a)
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux::%set-client-selected-tree-object conn worktree-a)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn 1)))
        (expect (eq :repositories (nerimux::%client-tree-object conn))))))

  (it "section-selection-returns-nil-for-an-empty-tree"
    (let ((conn (nerimux::%make-client-conn))
          (nerimux/vcs::*workspace-organizations* nil)
          (nerimux::*dirty* nil))
      (expect (null (nerimux::%select-client-tree-section-relative conn 1)))
      (expect (null (nerimux::%client-tree-object conn)))))

  (it "K-jumps-the-selection-backward-to-the-previous-section-header"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-jk-back" :host "github.com" :name "team"))
           (repo-a
             (nerimux/workspace-model:make-repository
              :id "repo-a-back" :organization organization
              :specification "github.com/team/repo-a-back"))
           (worktree-a
             (nerimux/workspace-model:make-worktree
              :id "wt-a-back" :repository repo-a :path "/tmp/a-back"
              :branch "a" :dirty-p t))
           (conn (nerimux::%make-client-conn)))
      (nerimux/workspace-model:organization-add-repository organization repo-a)
      (nerimux/workspace-model:repository-add-worktree repo-a worktree-a)
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux::%set-client-selected-tree-object conn repo-a)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn -1)))
        (expect (eq :repositories (nerimux::%client-tree-object conn))))))

  (it "K-starts-at-the-last-section-without-a-selection"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-jk-empty" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-jk-empty" :organization organization
              :specification "github.com/team/repo-jk-empty"))
           (conn (nerimux::%make-client-conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* (list organization)))
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn -1)))
        (expect (eq :repositories (nerimux::%client-tree-object conn))))))

  (it "K-uses-directional-fallback-for-a-stale-selection"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-jk-stale" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-jk-stale" :organization organization
              :specification "github.com/team/repo-jk-stale"))
           (conn (nerimux::%make-client-conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux::%set-client-selected-tree-object conn :stale)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn -1))))))

  (it "section-selection-starts-from-the-nearest-edge-without-a-selection"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-jk-edge" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-jk-edge" :organization organization
              :specification "github.com/team/repo-jk-edge"))
           (conn (nerimux::%make-client-conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* (list organization)))
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn 1)))
        (setf (nerimux::client-conn-selected-tree-object conn) nil)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn -1))))))

  (it "J-scrolls-section-selection-into-a-narrow-view"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-jk-scroll" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-jk-scroll" :organization organization
              :specification "github.com/team/repo-jk-scroll"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-jk-scroll" :repository repository :path "/tmp/jk-scroll"
              :branch "main" :dirty-p t))
           (conn (nerimux::%make-client-conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* (list organization)))
        (setf (nerimux::client-conn-rows conn) 1)
        (nerimux::%set-client-selected-tree-object conn :attention)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn 1)))
        (expect (plusp (nerimux::client-conn-tree-scroll conn))))))

  (it "K-scrolls-section-selection-back-into-view"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-jk-scroll-back" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-jk-scroll-back" :organization organization
              :specification "github.com/team/repo-jk-scroll-back"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-jk-scroll-back" :repository repository
              :path "/tmp/jk-scroll-back" :branch "main" :dirty-p t))
           (conn (nerimux::%make-client-conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* (list organization)))
        (setf (nerimux::client-conn-rows conn) 1
              (nerimux::client-conn-tree-scroll conn) 3)
        (nerimux::%set-client-selected-tree-object conn repository)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn -1)))
        (expect (= 2 (nerimux::client-conn-tree-scroll conn))))))

  (it "section-selection-adjusts-scroll-in-both-directions"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-jk-both" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-jk-both" :organization organization
              :specification "github.com/team/repo-jk-both"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-jk-both" :repository repository :path "/tmp/jk-both"
              :branch "main" :dirty-p t))
           (conn (nerimux::%make-client-conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* (list organization)))
        (setf (nerimux::client-conn-rows conn) 1
              (nerimux::client-conn-tree-scroll conn) 0)
        (nerimux::%set-client-selected-tree-object conn :attention)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn 1)))
        (expect (plusp (nerimux::client-conn-tree-scroll conn)))
        (setf (nerimux::client-conn-tree-scroll conn) 3
              (nerimux::client-conn-selected-tree-object conn) :repositories)
        (expect (eq :attention
                    (nerimux::%select-client-tree-section-relative conn -1)))
        (expect (= 1 (nerimux::client-conn-tree-scroll conn))))))

  (it "refuses to grow the tree filter past +max-tree-filter-length+"
    (let ((conn (nerimux::%make-client-conn)))
      (setf (nerimux::client-conn-tree-filter conn)
            (make-string nerimux::+max-tree-filter-length+ :initial-element #\a))
      (expect (null (nerimux::%client-tree-filter-buffer-append conn "b")))
      (expect (= nerimux::+max-tree-filter-length+
                 (length (nerimux::client-conn-tree-filter conn))))
      (expect (string= (make-string nerimux::+max-tree-filter-length+ :initial-element #\a)
                       (nerimux::client-conn-tree-filter conn)))
      (setf (nerimux::client-conn-tree-filter conn)
            (make-string (1- nerimux::+max-tree-filter-length+) :initial-element #\a))
      (expect (nerimux::%client-tree-filter-buffer-append conn "b"))
      (expect (= nerimux::+max-tree-filter-length+
                 (length (nerimux::client-conn-tree-filter conn)))))))

(describe "worktree-pane-memory"
          (it "ignores incomplete remembers and self-heals stale panes"
              (let* ((worktree
                      (nerimux/workspace-model:make-worktree :id "wt-memory"))
                     (pane (nerimux/pane:make-pane :id 101))
                     (other-pane (nerimux/pane:make-pane :id 102))
                     (nerimux::*workspace-worktree-last-pane*
                      (make-hash-table :test #'equal)))
                (expect (null (nerimux::%remember-worktree-pane nil pane)))
                (expect (null (nerimux::%remember-worktree-pane worktree nil)))
                (nerimux/pane:worktree-add-pane worktree pane)
                (nerimux::%remember-worktree-pane worktree pane)
                (expect (eq pane (nerimux::%worktree-remembered-pane worktree)))
                (nerimux::%remember-worktree-pane worktree other-pane)
                (expect (null (nerimux::%worktree-remembered-pane worktree)))
                (expect
                 (null
                  (gethash "wt-memory" nerimux::*workspace-worktree-last-pane*))))))

(describe "client-search-arguments"
          (it "normalizes search aliases and whitespace"
              (expect
               (eq :forward
                   (nerimux::%client-search-direction "search-forward")))
              (expect (eq :forward (nerimux::%client-search-direction "/")))
              (expect
               (eq :backward
                   (nerimux::%client-search-direction "search-backward")))
              (expect (eq :backward (nerimux::%client-search-direction "?")))
              (expect (null (nerimux::%client-search-direction "unknown")))
              (expect
               (string= "needle with spaces"
                        (nerimux::%client-search-term
                         '("  needle" "with" "spaces  "))))))

(describe "client-dispatch-boundaries"
          (it "consumes exactly the requested escape suffix"
              (let ((conn (nerimux::%make-client-conn)))
                (nerimux::%client-esc-swallow-start conn 1)
                (expect (nerimux::%client-esc-swallow-consume conn))
                (expect (null (nerimux::%client-esc-swallow-consume conn)))
                (nerimux::%client-esc-swallow-start conn 2)
                (expect (nerimux::%client-esc-swallow-consume conn))
                (expect (nerimux::%client-esc-swallow-consume conn))
                (expect (null (nerimux::%client-esc-swallow-consume conn)))))
          (it "only claims one-byte workspace prefix payloads"
              (let ((session (nerimux/session:make-session :id 1 :name "test"))
                    (conn (nerimux::%make-client-conn)))
                (multiple-value-bind (handled result) 
                    (nerimux::%handle-workspace-prefix-key session
                                                           conn
                                                           #(17 18))
                  (expect (null handled))
                  (expect (null result)))
                (multiple-value-bind (handled result) 
                    (nerimux::%handle-workspace-prefix-key session conn "Q")
                  (expect (null handled))
                  (expect (null result)))
                (multiple-value-bind (handled result) 
                    (nerimux::%handle-workspace-prefix-key session
                                                           conn
                                                           (vector
                                                            (nerimux::client-conn-workspace-prefix-code
                                                             conn)))
                  (expect handled)
                  (expect (null result))
                  (expect (nerimux::client-conn-ui-prefix-p conn)))))
          (it "derives UI ownership from view and modal state"
              (let ((conn (nerimux::%make-client-conn)))
                (dolist (view '(:repolist :status))
                  (setf (nerimux::client-conn-view conn) view)
                  (expect (nerimux::%client-ui-keys-p conn)))
                (setf (nerimux::client-conn-view conn) :pane)
                (expect (null (nerimux::%client-ui-keys-p conn)))
                (setf (nerimux::client-conn-view conn) :status
                      (nerimux::client-conn-modal conn) :command)
                (expect (null (nerimux::%client-ui-keys-p conn)))))
          (it
           "closes help on its documented exit keys and swallows escape tails"
           (dolist (payload '("q" "?" #(13) #(10)))
             (let ((conn (nerimux::%make-client-conn)))
               (setf (nerimux::client-conn-modal conn) :help)
               (nerimux::%handle-help-view-key conn payload)
               (expect (null (nerimux::client-conn-modal conn)))))
           (let ((conn (nerimux::%make-client-conn)))
             (setf (nerimux::client-conn-modal conn) :help)
             (nerimux::%handle-help-view-key conn #(27))
             (expect (null (nerimux::client-conn-modal conn)))
             (expect (nerimux::%client-esc-swallow-consume conn))
             (expect (nerimux::%client-esc-swallow-consume conn))
             (expect (null (nerimux::%client-esc-swallow-consume conn)))))
          (it "reports unavailable-focused-pane-input"
              (let* ((session (nerimux/session:make-session :id 1 :name "test"))
                     (conn (nerimux::%make-client-conn))
                     (pane (nerimux/pane:make-pane :fd -1))
                     (nerimux::*clients* (list conn))
                     (nerimux::*dirty* nil))
                (setf (nerimux::client-conn-stdin-target conn) pane)
                (expect
                 (nerimux::%handle-client-input-key-payload session conn "x"))
                (expect
                 (equal '("focused pane is unavailable")
                        (nerimux::client-conn-message-log conn)))
                (expect nerimux::*dirty*)))
          (it "contains-peer-io-failure-while-forwarding-pane-input"
              (let* ((session (nerimux/session:make-session :id 1 :name "test"))
                     (conn (nerimux::%make-client-conn))
                     (pane (nerimux/pane:make-pane :fd 1))
                     (nerimux::*clients* (list conn))
                     (nerimux::*dirty* nil))
                (setf (nerimux::client-conn-stdin-target conn) pane)
                (with-stubbed-fdefinition
                 ((nerimux/pty:pty-write
                   (lambda (fd payload)
                     (declare (ignore fd payload))
                     (error 'nerimux::peer-io-failure))))
                 (expect
                  (nerimux::%handle-client-input-key-payload session conn "x")))
                (expect
                 (search "input failed:"
                         (first (nerimux::client-conn-message-log conn))))
                (expect nerimux::*dirty*)))
          (it "feeds-input-to-the-screen-after-pane-exit"
              (let* ((session (nerimux/session:make-session :id 1 :name "test"))
                     (conn (nerimux::%make-client-conn))
                     (screen (nerimux/terminal:make-screen 5 2))
                     (pane (nerimux/pane:make-pane :fd -1 :screen screen))
                     (nerimux::*clients* (list conn))
                     (nerimux::*dirty* nil))
                (setf (nerimux::client-conn-stdin-target conn) pane)
                (expect
                 (nerimux::%handle-client-input-key-payload session
                                                            conn
                                                            (vector
                                                             (char-code #\A))))
                (expect
                 (char= #\A
                        (nerimux/terminal:cell-char
                         (nerimux/terminal:screen-cell screen 0 0))))
                (expect (null (nerimux::client-conn-message-log conn)))
                (expect nerimux::*dirty*)))
          (it "uses-live-workspace-defaults-and-stringifies-notices"
              (multiple-value-bind (organizations organization repository
                                    main-worktree feature-worktree)
                  (%make-server-dispatch-helper-fixture)
                (declare (ignorable organization main-worktree feature-worktree))
                (let ((conn (nerimux::%make-client-conn))
                      (nerimux::*clients* nil)
                      (nerimux::*dirty* nil)
                      (nerimux/vcs::*workspace-organizations* organizations))
                  (expect (eq repository
                              (nerimux::%workspace-find-repository "repo-id")))
                  (expect (eq organization
                              (nerimux::%workspace-find-organization "org-id")))
                  (setf nerimux::*clients* (list conn))
                  (expect (string= "42" (nerimux::%client-notify conn 42)))
                  (expect (equal '("42")
                                 (nerimux::client-conn-message-log conn)))))))
)
