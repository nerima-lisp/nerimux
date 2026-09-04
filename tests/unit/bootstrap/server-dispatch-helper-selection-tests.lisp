(in-package #:nerimux/test)

(describe "server-dispatch-helper-selection-suite"
  (it "resolves-workspace-selectors-and-attach-paths"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (expect (= 2 (length (nerimux::%workspace-worktrees organizations))))
      (expect (eq feature-worktree
                  (nerimux::%workspace-find-worktree "feature-id"
                                                     organizations)))
      (expect (eq main-worktree
                  (nerimux::%workspace-find-worktree "/workspace/repo"
                                                     organizations)))
      (expect (null (nerimux::%workspace-find-worktree 42 organizations)))
      (expect (null (nerimux::%workspace-find-worktree
                     "not-a-worktree" organizations)))
      (expect (eq feature-worktree
                  (nerimux::%workspace-find-worktree-for-attach
                   "/workspace/repo/" organizations)))
      (expect (eq repository
                  (nerimux::%workspace-find-repository-for-attach
                   "origin/team/repo" organizations)))
      (expect (null (nerimux::%workspace-find-repository-for-attach
                    "" organizations)))
      (expect (nerimux::%workspace-directory-prefix-p
               "/workspace/repo" "/workspace/repo/feature"))
      (expect (nerimux::%workspace-directory-prefix-p
               "/workspace/repo/" "/workspace/repo/feature"))
      (expect (null (nerimux::%workspace-directory-prefix-p
                     "/workspace/repository" "/workspace/repo/feature")))
      (expect (null (nerimux::%workspace-directory-prefix-p nil
                     "/workspace/repo")))
      (expect (eq organization
                  (nerimux::%workspace-find-organization "org-id"
                                                          organizations)))
      (expect (eq organization
                  (nerimux::%workspace-find-organization "origin"
                                                          organizations)))
      (expect (eq repository
                  (nerimux::%workspace-find-repository "repo-id"
                                                        organizations)))
      (expect (eq feature-worktree
                  (nerimux::%workspace-find-tree-object
                   '(:worktree "feature-id") organizations)))))

  (it "resolves-explicit-organization-tree-tokens"
    (multiple-value-bind (organizations organization)
        (%make-server-dispatch-helper-fixture)
      (expect (eq organization
                  (nerimux::%workspace-find-tree-object
                   '(:organization "org-id") organizations)))))

  (it "uses-the-live-catalog-for-default-workspace-selection"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore organization repository main-worktree))
      (let ((nerimux/vcs::*workspace-organizations* organizations))
        (expect (= 2 (length (nerimux::%workspace-worktrees))))
        (expect (listp (nerimux::%workspace-tree-objects)))
        (expect (eq feature-worktree
                    (nerimux::%workspace-find-worktree "feature-id"))))))

  (it "resolves-picker-organization-through-its-first-available-worktree"
    (let* ((organization (nerimux/workspace-model:make-organization :id "org"))
           (repository (nerimux/workspace-model:make-repository :id "repo"))
           (worktree (nerimux/workspace-model:make-worktree
                      :id "tree" :repository repository :path "/tmp/tree"))
           (item (nerimux/picker::%make-picker-item
                  :id "org" :kind :organization :label "org"
                  :organization organization)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (expect (eq worktree (nerimux::%picker-item-worktree item)))))

  (it "resolves-the-most-specific-worktree-containing-a-cwd"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organization repository))
      (expect (eq feature-worktree
                  (nerimux::%workspace-find-worktree-for-cwd
                   "/workspace/repo/feature/src" organizations)))
      (expect (eq main-worktree
                  (nerimux::%workspace-find-worktree-for-cwd
                   "/workspace/repo/src" organizations)))
      (expect (null (nerimux::%workspace-find-worktree-for-cwd
                     "/workspace/other" organizations)))
      (expect (null (nerimux::%workspace-find-worktree-for-cwd
                     nil organizations)))))

  (it "builds-selection-tokens-from-model-identities"
    (let* ((organization
             (nerimux/workspace-model::%make-organization
              :id "org-id" :host "origin" :name "team"))
           (repository
             (nerimux/workspace-model::%make-repository
              :id "repo-id" :organization organization :specification "spec"
              :local-path "/workspace/repo"))
           (worktree
             (nerimux/workspace-model::%make-worktree
              :id "worktree-id" :path "/workspace/repo/feature" :branch 'feature)))
      (expect (string= "org-id"
                       (nerimux::%organization-selection-token organization)))
      (expect (string= "repo-id"
                       (nerimux::%repository-selection-token repository)))
      (expect (string= "worktree-id"
                       (nerimux::%worktree-selection-token worktree)))
      (expect (null (nerimux::%organization-selection-token nil)))
      (expect (null (nerimux::%repository-selection-token nil)))
      (expect (null (nerimux::%worktree-selection-token nil)))))

  (it "selection-tokens-fall-back-to-stable-model-fields"
    (let* ((organization
             (nerimux/workspace-model::%make-organization
              :host "origin" :name "team"))
           (repository
             (nerimux/workspace-model::%make-repository
              :organization organization :specification "origin/team/repo"))
           (local-path-repository
             (nerimux/workspace-model::%make-repository
              :local-path "/workspace/local-only"))
           (path-worktree
             (nerimux/workspace-model::%make-worktree
              :path "/workspace/repo"))
           (branch-worktree
             (nerimux/workspace-model::%make-worktree
              :branch 'feature))
           (pane (nerimux/pane:make-pane :id 1)))
      (nerimux/pane:worktree-add-pane path-worktree pane)
      (expect (string= "origin/team"
                       (nerimux::%organization-selection-token organization)))
      (expect (string= "origin/team/repo"
                       (nerimux::%repository-selection-token repository)))
      (expect (string= "/workspace/local-only"
                       (nerimux::%repository-selection-token
                        local-path-repository)))
      (expect (string= "/workspace/repo"
                       (nerimux::%worktree-selection-token path-worktree)))
      (expect (string= "FEATURE"
                       (nerimux::%worktree-selection-token branch-worktree)))
      (expect (equal '(:worktree "/workspace/repo")
                     (nerimux::%tree-object-selection-token pane)))
      (expect (equal '(:worktree "owner")
                     (nerimux::%tree-object-selection-token
                      '(:diff-line "owner" "file"))))
      (expect (equal '(:section :active)
                     (nerimux::%tree-object-selection-token :active)))
      (expect (null (nerimux::%tree-object-selection-token 42)))))

  (it "tracks-tree-objects-selection-and-scroll"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organization))
      (let ((nerimux::*dirty* nil)
            (nerimux::*last-selected-worktree-token* nil)
            (nerimux::*workspace-collapsed-node-ids*
              (make-hash-table :test #'equal))
            (nerimux::*workspace-expanded-node-ids*
              (let ((table (make-hash-table :test #'equal)))
                (setf (gethash (list :repository (nerimux/workspace-model:repository-id repository))
                               table)
                      t)
                table))
            (nerimux/vcs::*workspace-organizations* organizations)
            (conn (nerimux::%make-client-conn)))
        (setf (nerimux::client-conn-rows conn) 5)
        (let ((objects (nerimux::%workspace-tree-objects organizations)))
          (expect (= 4 (length objects)))
          (expect (eq :repositories (first objects)))
          (expect (eq repository (second objects)))
          (expect (eq feature-worktree (third objects)))
          (expect (eq main-worktree (fourth objects))))
        (expect (equal '(:organization "org-id")
                       (nerimux::%tree-object-selection-token organization)))
        (expect (equal '(:repository "repo-id")
                       (nerimux::%tree-object-selection-token repository)))
        (expect (equal '(:worktree "main-id")
                       (nerimux::%tree-object-selection-token main-worktree)))
        (expect (eq feature-worktree
                    (nerimux::%set-client-selected-tree-object
                     conn feature-worktree)))
        (expect (equal '(:worktree "feature-id")
                       (nerimux::%client-tree-selection-token conn)))
        (expect (eq main-worktree
                    (nerimux::%select-client-tree-worktree conn "main-id")))
        (setf (nerimux::client-conn-tree-scroll conn) 0)
        (expect (= 3 (nerimux::%move-client-tree-scroll conn 99)))
        (expect (zerop (nerimux::%move-client-tree-scroll conn -99)))
        (expect (zerop (nerimux::%move-client-tree-scroll conn "down")))
        (expect (eq main-worktree
                    (nerimux::%rebind-client-selection conn organizations)))
        (expect nerimux::*dirty*))))

  (it "updates-picker-query-regex-and-index"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organization main-worktree feature-worktree))
      (let ((conn (nerimux::%make-client-conn)))
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items organizations))
        (expect (nerimux::%set-client-picker-query conn "repo-id"))
        (expect (string= "repo-id"
                         (nerimux::client-conn-picker-query conn)))
        (expect (consp (nerimux::%client-picker-visible-items conn)))
        (expect (nerimux::%set-client-picker-regex conn t t))
        (expect (nerimux::client-conn-picker-regex-p conn))
        (expect (nerimux::%set-client-picker-regex conn :unknown t))
        (expect (nerimux::client-conn-picker-regex-p conn))
        (expect (null (nerimux::%set-client-picker-regex conn nil t)))
        (expect (null (nerimux::client-conn-picker-regex-p conn)))
        (expect (consp (nerimux::%client-picker-visible-items conn)))
        (expect (nerimux::%set-client-picker-regex conn nil nil))
        (expect (nerimux::client-conn-picker-regex-p conn))
        (expect (nerimux::%set-client-picker-query conn ""))
        (expect (nerimux::%append-client-picker-query-octets conn "repo"))
        (expect (nerimux::%append-client-picker-query-octets
                 conn (vector (char-code #\-))))
        (expect (null (nerimux::%append-client-picker-query-octets
                       conn (vector 10))))
        (expect (string= "repo-"
                         (nerimux::client-conn-picker-query conn)))
        (expect (nerimux::%set-client-picker-query conn "abc"))
        (expect (nerimux::%delete-client-picker-query-character conn))
        (expect (string= "ab"
                         (nerimux::client-conn-picker-query conn)))
        (expect (nerimux::%delete-client-picker-query-character conn))
        (expect (nerimux::%delete-client-picker-query-character conn))
        (expect (null (nerimux::%delete-client-picker-query-character conn)))
        (setf (nerimux::client-conn-picker-query conn) "repo-id"
              (nerimux::client-conn-picker-index conn) 0)
        (let ((visible-items (nerimux::%client-picker-visible-items conn)))
          (expect (nerimux::%move-client-picker-index conn 1))
          (expect (= (mod 1 (length visible-items))
                     (nerimux::client-conn-picker-index conn))))
        (expect (eq repository
                    (nerimux/picker:picker-item-repository
                     (find-if (lambda (item)
                                (eq :repository
                                    (nerimux/picker:picker-item-kind item)))
                              (nerimux::%client-picker-visible-items conn))))))))
  )
