(in-package #:nerimux/test)

(describe "server-multi-suite"
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
          (ignore-errors (sb-posix:rmdir failing-path)))))))
