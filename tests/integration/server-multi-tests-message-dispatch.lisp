(in-package #:nerimux/test)
(defclass row-delta-output-stream (sb-gray:fundamental-binary-output-stream)
  ((bytes :initform (make-array 0 :element-type '(unsigned-byte 8)
                               :adjustable t :fill-pointer 0)
          :reader row-delta-output-bytes)
   (fail-flush :initform nil :accessor row-delta-fail-flush)
   (flush-count :initform 0 :accessor row-delta-flush-count)))
(defmethod stream-element-type ((stream row-delta-output-stream))
  '(unsigned-byte 8))
(defmethod sb-gray:stream-write-byte ((stream row-delta-output-stream) byte)
  (vector-push-extend byte (row-delta-output-bytes stream))
  byte)
(defmethod sb-gray:stream-finish-output ((stream row-delta-output-stream))
  (incf (row-delta-flush-count stream))
  (when (row-delta-fail-flush stream) (error "row-delta injected flush failure")))
(defun %row-delta-take-output (stream)
  (let ((bytes (row-delta-output-bytes stream)))
    (multiple-value-bind (type payload next) (nerimux/protocol:decode-frame bytes)
      (assert type)
      (assert (= next (length bytes)))
      (setf (fill-pointer bytes) 0)
      (cl-codec-kit:octets-to-string payload :encoding :utf-8))))
(defun %row-delta-test-candidate (conn text &optional (title ""))
  (let ((surface (cl-tui-kit/core:make-surface
                  (nerimux::client-conn-cols conn) (nerimux::client-conn-rows conn))))
    (cl-tui-kit/core:surface-draw-text surface 0 1 text)
    (multiple-value-bind (full snapshot) (nerimux/renderer::%surface-to-ansi-frame surface)
      (multiple-value-bind (titled titled-snapshot)
          (nerimux/renderer::%ansi-frame-with-title full snapshot title)
        (let ((frame (nerimux/protocol:msg-frame titled)))
          (setf (nerimux::client-conn-frame conn) frame
                (nerimux::client-conn-row-frame-candidate conn)
                (list frame (nerimux::%client-row-frame-key conn) titled-snapshot))
          frame)))))

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
                :dirty-p t :conflict-p t))
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
                :branch "mnp-keys" :dirty-p t :conflict-p t))
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
                :branch "tab-wt" :dirty-p t :conflict-p t
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
                 (nerimux/renderer:workspace-flat-tree-entries
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
                :conflict-p t
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
                :conflict-p t
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
        (nerimux::%handle-multi-key-message s conn #(9))
        (nerimux::%handle-multi-key-message
         s conn #(27 91 66))
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

  (it "wt-21-a-refresh-that-no-longer-carries-the-row-keeps-the-selection"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-dropped" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-dropped" :organization organization
              :specification "github.com/team/repo-dropped"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-dropped" :repository repository
              :path "/tmp/dropped" :branch "dropped"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* nil))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (setf (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-selected-tree-object conn worktree)
      (nerimux::%rebind-client-selection
       conn
       (list (nerimux/workspace-model:make-organization
              :id "org-other" :host "github.com" :name "other")))
      (expect (eq worktree (nerimux::client-conn-selected-tree-object conn)))
      (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))))

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
                :branch "diff-cached" :dirty-p t :conflict-p t
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
                    (nerimux/renderer:workspace-flat-tree-entries
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
        (nerimux::%handle-multi-key-message s conn #(63))
        (expect (eq :transient (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(107))
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(110))
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(113))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "?-then-k-also-opens-from-the-repolist-view-and-enter-or-esc-close-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (nerimux::%handle-multi-key-message s conn #(27))
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
        (nerimux::%handle-multi-key-message s conn #(110))
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
          (nerimux::%handle-multi-key-message s conn #(110))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (eq :pane (nerimux::client-conn-view conn)))
          (expect (equalp (list (list 9999 #(110))) writes))))))

  (it "a-modal-owns-the-key-and-the-view-underneath-never-sees-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist
              (nerimux::client-conn-modal conn) :help)
        (nerimux::%handle-multi-key-message s conn #(110))
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
                    (nerimux/vcs::%git-worktree-list
                      (lambda (directory)
                        (list (%vcs-operations-fake-worktree
                               directory :branch "main" :head "head"))))
                    (nerimux/vcs::%git-status-snapshot
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
(describe "worktree-arrow-input-suite"
  (it "worktree-arrows-route-both-views-across-every-payload-split"
    (with-fake-session (s)
      (dolist (view '(:repolist :status))
        (dolist (direction '((65 -1) (66 1)))
          (dolist (cuts '((3) (1 2) (2 1) (1 1 1)))
            (let ((conn (%make-test-conn))
                  (nerimux::*client-meta-pending* (make-hash-table :test #'eq))
                  (calls nil)
                  (payload (vector 27 91 (first direction))))
              (setf (nerimux::client-conn-view conn) view)
              (with-stubbed-fdefinition
                  ((nerimux::%select-client-tree-relative
                     (lambda (received-conn delta)
                       (push (list received-conn delta) calls))))
                (loop with start = 0
                      for size in cuts
                      do (nerimux::%handle-multi-key-message
                          s conn (subseq payload start (+ start size)))
                         (incf start size)))
              (expect (equal (list (list conn (second direction))) calls))
              (expect (null (gethash conn nerimux::*client-meta-pending*)))
              (expect (null (nerimux::client-conn-modal conn)))))))))

  (it "worktree-arrows-preserve-meta-visibility-and-swallow-unknown-tails"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*client-meta-pending* (make-hash-table :test #'eq))
            (calls nil))
        (setf (nerimux::client-conn-view conn) :repolist)
        (with-stubbed-fdefinition
            ((nerimux::%select-client-tree-relative
               (lambda (received-conn delta)
                 (declare (ignore received-conn))
                 (push (list :row delta) calls)))
             (nerimux::%select-client-tree-section-relative
               (lambda (received-conn delta)
                 (declare (ignore received-conn))
                 (push (list :section delta) calls)))
             (nerimux::%client-prune-workspaces
               (lambda (received-conn &key all)
                 (push (list :prune received-conn all) calls)
                 t)))
          (nerimux::%handle-multi-key-message s conn #(27 110))
          (nerimux::%handle-multi-key-message s conn #(27))
          (nerimux::%handle-multi-key-message s conn #(112))
          (expect (equal '((:section -1) (:section 1)) calls))
          (let ((before (nerimux::client-conn-visibility-level conn)))
            (nerimux::%handle-multi-key-message s conn #(27 91 90))
            (expect (= (1+ (mod before 4))
                       (nerimux::client-conn-visibility-level conn))))
          (setf calls nil)
          (dolist (tail '(67 68 80 110 112))
            (nerimux::%handle-multi-key-message s conn #(27))
            (nerimux::%handle-multi-key-message s conn (vector 91 tail))
            (expect (null calls))
            (expect (null (nerimux::client-conn-modal conn)))
            (expect (null (gethash conn nerimux::*client-meta-pending*))))
          (nerimux::%handle-multi-key-message s conn #(112))
          (expect (equal (list '(:row -1)) calls))
          (nerimux::%handle-multi-key-message s conn #(27 91 65))
          (expect (equal (list '(:row -1) '(:row -1)) calls))))))

  (it "worktree-arrow-decoding-leaves-pane-payloads-intact"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/session:session-windows s)))
             (pane (first (nerimux/window:window-panes win)))
             (nerimux::*client-meta-pending* (make-hash-table :test #'eq))
             (calls nil))
        (nerimux::%set-client-focus conn pane)
        (with-stubbed-fdefinition
            ((nerimux/pane:pane-feed
               (lambda (received-pane bytes)
                 (push (list received-pane bytes) calls))))
          (dolist (payload '(#(27 91 66) #(27) #(91) #(65)))
            (nerimux::%handle-multi-key-message s conn payload)))
        (expect (equalp (list (list pane #(65)) (list pane #(91))
                             (list pane #(27)) (list pane #(27 91 66)))
                        calls))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect (null (gethash conn nerimux::*client-meta-pending*)))))))
(describe "agent-workspace merge additions"
  (it "row-delta sends first full then one row and suppresses identical retransmission"
      (let* ((stream (make-instance 'row-delta-output-stream))
             (conn (nerimux::%make-client-conn :stream stream :rows 3 :cols 10))
             (a (%row-delta-test-candidate conn "A")))
        (nerimux::%send-client-frame conn a)
        (let ((full (%row-delta-take-output stream))
              (b (%row-delta-test-candidate conn "B")))
          (expect (search (format nil "~C[2J" #\Escape) full))
          (nerimux::%send-client-frame conn b)
          (let ((delta (%row-delta-take-output stream)))
            (expect (< (length delta) (length full)))
            (expect (null (search (format nil "~C[2J" #\Escape) delta)))
            (expect (search (format nil "~C[2;1H" #\Escape) delta))
            (expect (null (search (format nil "~C[1;1H" #\Escape) delta)))
            (expect (null (search (format nil "~C[3;1H" #\Escape) delta))))
          (nerimux::%send-client-frame conn b)
          (expect (zerop (length (row-delta-output-bytes stream))))
          (expect (= 2 (row-delta-flush-count stream))))))
  (it "row-delta commits only successful sends and retries partial flush failure with full frame"
      (let* ((stream (make-instance 'row-delta-output-stream))
             (conn (nerimux::%make-client-conn :stream stream :rows 3 :cols 10)))
        (nerimux::%send-client-frame conn (%row-delta-test-candidate conn "A"))
        (%row-delta-take-output stream)
        (let* ((baseline (nerimux::client-conn-sent-row-frame conn))
               (b (%row-delta-test-candidate conn "B")))
          (expect (eq baseline (nerimux::client-conn-sent-row-frame conn)))
          (setf (row-delta-fail-flush stream) t)
          (expect (handler-case (progn (nerimux::%send-client-frame conn b) nil)
                    (error () t)))
          (expect (plusp (length (row-delta-output-bytes stream))))
          (expect (null (nerimux::client-conn-sent-row-frame conn)))
          (setf (fill-pointer (row-delta-output-bytes stream)) 0
                (row-delta-fail-flush stream) nil)
          (nerimux::%send-client-frame conn b)
          (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream)))
          (expect (eq b (first (nerimux::client-conn-sent-row-frame conn)))))))
  (it "row-delta invalidates geometry view modal and arbitrary-frame baselines"
      (let* ((stream (make-instance 'row-delta-output-stream))
             (conn (nerimux::%make-client-conn :stream stream :rows 3 :cols 10)))
        (nerimux::%send-client-frame conn (%row-delta-test-candidate conn "A"))
        (%row-delta-take-output stream)
        (dolist (change (list (lambda () (incf (nerimux::client-conn-cols conn)))
                             (lambda () (setf (nerimux::client-conn-view conn) :status))
                             (lambda () (setf (nerimux::client-conn-modal conn) :help))))
          (funcall change)
          (nerimux::%send-client-frame conn (%row-delta-test-candidate conn "B"))
          (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream))))
        (nerimux::%send-client-frame conn (nerimux/protocol:msg-frame "arbitrary"))
        (expect (string= "arbitrary" (%row-delta-take-output stream)))
        (expect (null (nerimux::client-conn-sent-row-frame conn)))
        (setf (nerimux::client-conn-modal conn) nil)
        (nerimux::%send-client-frame conn (%row-delta-test-candidate conn "B"))
        (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream)))))
  (it "row-delta isolates clients and transmits title-only OSC"
      (let* ((stream-a (make-instance 'row-delta-output-stream))
             (stream-b (make-instance 'row-delta-output-stream))
             (a (nerimux::%make-client-conn :stream stream-a :rows 3 :cols 10))
             (b (nerimux::%make-client-conn :stream stream-b :rows 3 :cols 10))
             (title-a (format nil "~C]2;A~C" #\Escape #\Bel))
             (title-b (format nil "~C]2;B~C" #\Escape #\Bel)))
        (nerimux::%send-client-frame a (%row-delta-test-candidate a "A" title-a))
        (%row-delta-take-output stream-a)
        (nerimux::%send-client-frame a (%row-delta-test-candidate a "A" title-b))
        (expect (string= title-b (%row-delta-take-output stream-a)))
        (nerimux::%send-client-frame b (%row-delta-test-candidate b "A" title-b))
        (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream-b)))
        (expect (not (eq (nerimux::client-conn-sent-row-frame a)
                         (nerimux::client-conn-sent-row-frame b))))))
  (it "row-delta real overview status and modal rendering respect sent cache ownership"
      (with-fake-session (session)
        (let* ((organization
                 (nerimux/workspace-model:make-organization :id "row-delta-org"))
               (repository
                 (nerimux/workspace-model:make-repository
                  :id "row-delta-repo" :organization organization
                  :specification "row-delta/repo"))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "row-delta-worktree" :repository repository
                  :path "row-delta-worktree" :branch "main"))
               (stream (make-instance 'row-delta-output-stream))
               (conn (nerimux::%make-client-conn :stream stream :rows 10 :cols 40))
               (nerimux/vcs::*workspace-organizations* (list organization)))
          (nerimux/workspace-model:organization-add-repository organization repository)
          (nerimux/workspace-model:repository-add-worktree repository worktree)
          (let ((frame (nerimux::%render-client-frame session conn)))
            (expect (nerimux::client-conn-row-frame-candidate conn))
            (expect (null (nerimux::client-conn-sent-row-frame conn)))
            (nerimux::%send-client-frame conn frame)
            (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream))))
          (let ((baseline (nerimux::client-conn-sent-row-frame conn)))
            (nerimux::%render-client-frame session conn)
            (expect (eq baseline (nerimux::client-conn-sent-row-frame conn))))
          (setf (nerimux::client-conn-view conn) :status
                (nerimux::client-conn-selected-worktree conn) worktree)
          (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))
          (nerimux::%send-client-frame conn (nerimux::%render-client-frame session conn))
          (expect (nerimux::client-conn-row-frame-candidate conn))
          (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream)))
          (setf (nerimux::client-conn-modal conn) :help)
          (nerimux::%send-client-frame conn (nerimux::%render-client-frame session conn))
          (expect (null (nerimux::client-conn-row-frame-candidate conn)))
          (expect (null (nerimux::client-conn-sent-row-frame conn)))
          (%row-delta-take-output stream)
          (setf (nerimux::client-conn-modal conn) nil)
          (nerimux::%send-client-frame conn (nerimux::%render-client-frame session conn))
          (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream))))))
  (it "ui-command-dispatch-rejects-prune-arguments-and-cancels-picker"
      (with-fake-session (s)
        (let ((conn (%make-test-conn))
              (calls nil)
              (notifications nil))
          (setf (nerimux::client-conn-modal conn) :picker)
          (with-stubbed-fdefinition
              ((nerimux::%client-notify
                (lambda (client message)
                  (declare (ignore client))
                  (push message notifications)))
               (nerimux::%client-prune-workspaces
                (lambda (&rest arguments)
                  (push arguments calls)))
               (nerimux::%close-client-picker
                (lambda (client)
                  (declare (ignore client))
                  (push :close calls))))
            (expect (nerimux::%handle-client-ui-command
                     s conn :workspace-prune "unexpected" nil))
            (expect (null calls))
            (expect (equal '("workspace prune takes no arguments") notifications))
            (expect (nerimux::%handle-client-ui-command
                     s conn :cancel nil nil))
            (expect (equal '(:close) calls))))))
  (it "ui-command-dispatches-single-and-all-workspace-prune"
      (with-fake-session (s)
        (let* ((organization (nerimux/workspace-model:make-organization :id "org"))
               (repository (nerimux/workspace-model:make-repository
                            :id "repo" :organization organization))
               (worktree (nerimux/workspace-model:make-worktree
                          :id "feature" :repository repository
                          :path "/tmp/feature"))
               ;; Prune-all now counts only what it would remove, and the
               ;; first worktree added is the repository's primary one.
               (prunable (nerimux/workspace-model:make-worktree
                          :id "done" :repository repository
                          :path "/tmp/done" :completed-p t))
               (conn (%make-test-conn))
               (nerimux::*clients* (list conn))
               (calls nil))
          (nerimux/workspace-model:organization-add-repository organization repository)
          (nerimux/workspace-model:repository-add-worktree repository worktree)
          (nerimux/workspace-model:repository-add-worktree repository prunable)
          (let ((nerimux/vcs::*workspace-organizations* (list organization)))
            (nerimux::%set-client-selected-tree-object conn worktree)
            (with-stubbed-fdefinition
                ((nerimux::%client-prune-workspaces
                  (lambda (client &key all)
                    (push (list client all) calls)
                    t)))
              (expect (nerimux::%handle-client-ui-command
                       s conn :workspace-prune nil nil))
              (expect (eq :confirm (nerimux::client-conn-modal conn)))
              (nerimux::%handle-multi-key-message s conn #(121))
              (expect (nerimux::%handle-client-ui-command
                       s conn :workspace-prune-all nil nil))
              (expect (eq :confirm (nerimux::client-conn-modal conn)))
              (nerimux::%handle-multi-key-message s conn #(121))
              (expect (equal (list (list conn t) (list conn nil)) calls)))))))
  (it "pending-worktree-guards-preserve-command-and-focus-state"
      (with-fake-session (s)
        (let* ((conn (%make-test-conn))
               (window (nerimux/session:session-active-window s))
               (pane (nerimux/window:window-active-pane window))
               (worktree (nerimux/workspace-model:make-worktree
                          :id "pending-focus"
                          :path "/tmp/pending-focus")))
          (setf (nerimux::client-conn-view conn) :command
                (nerimux::client-conn-command-return-view conn) :pane)
          (with-stubbed-fdefinition
              ((nerimux::%reject-pending-worktree-attachment
                 (lambda (&rest arguments)
                   (declare (ignore arguments))
                   t)))
            (expect (null (nerimux::%client-restore-command-view conn)))
            (expect (eq :pane (nerimux::client-conn-command-return-view conn)))
            (nerimux::%set-client-selected-tree-object conn pane)
            (nerimux::%set-client-focus conn pane)
            (expect (null (nerimux::%focus-selected-client-worktree s conn)))
            (expect (eq :command (nerimux::client-conn-view conn)))
            (nerimux::%set-client-selected-tree-object conn window)
            (expect (null (nerimux::%focus-selected-client-worktree s conn)))
            (expect (eq :command (nerimux::client-conn-view conn)))
            (nerimux::%set-client-selected-tree-object conn worktree)
            (setf (nerimux::client-conn-selected-worktree conn) worktree)
            (expect (null (nerimux::%focus-selected-client-worktree s conn)))
            (expect (null (nerimux::%client-select-pane-direction s conn :left)))))))
  (it "workspace-context-and-operation-worktree-fall-back-to-focused-pane"
      (with-fake-session (s)
        (let* ((organization
                 (nerimux/workspace-model:make-organization
                  :id "org-focus-fallback" :host "github.com" :name "team"))
               (repository
                 (nerimux/workspace-model:make-repository
                  :id "repo-focus-fallback" :organization organization
                  :specification "github.com/team/repo-focus-fallback"))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "wt-focus-fallback" :repository repository
                  :path "/tmp/focus-fallback" :branch "focus-fallback"))
               (conn (%make-test-conn))
               (pane (nerimux/window:window-active-pane
                      (nerimux/session:session-active-window s))))
          (nerimux/workspace-model:organization-add-repository organization repository)
          (nerimux/workspace-model:repository-add-worktree repository worktree)
          (nerimux/pane:worktree-add-pane worktree pane)
          (nerimux::%set-client-selected-tree-object conn nil)
          (setf (nerimux::client-conn-selected-worktree conn) nil
                (nerimux::client-conn-focus conn) pane)
          (expect (eq worktree (nerimux::%client-context-object conn nil)))
          (expect (eq worktree (nerimux::%client-operation-worktree conn nil))))))
  (it "section-navigation-initializes-and-clamps-tree-scroll"
      (with-fake-session (s)
        (let* ((organization
                 (nerimux/workspace-model:make-organization
                  :id "org-section-scroll" :host "github.com" :name "team"))
               (repository
                 (nerimux/workspace-model:make-repository
                  :id "repo-section-scroll" :organization organization
                  :specification "github.com/team/repo-section-scroll"))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "wt-section-scroll" :repository repository
                  :path "/tmp/section-scroll" :branch "section-scroll"
                  :dirty-p t :conflict-p t))
               (conn (%make-test-conn :rows 7))
               (nerimux/vcs::*workspace-organizations* (list organization)))
          (nerimux/workspace-model:organization-add-repository organization repository)
          (nerimux/workspace-model:repository-add-worktree repository worktree)
          (nerimux::%set-client-selected-tree-object conn nil)
          (setf (nerimux::client-conn-tree-scroll conn) 0)
          (expect (eq :attention
                      (nerimux::%select-client-tree-section-relative conn 1)))
          (nerimux::%set-client-selected-tree-object conn :attention)
          (setf (nerimux::client-conn-tree-scroll conn) 0)
          (expect (eq :repositories
                      (nerimux::%select-client-tree-section-relative conn 1)))
          (expect (> (nerimux::client-conn-tree-scroll conn) 0))
          (nerimux::%set-client-selected-tree-object conn worktree)
          (setf (nerimux::client-conn-tree-scroll conn) 5)
          (expect (eq :attention
                      (nerimux::%select-client-tree-section-relative conn -1)))
          (expect (= 0 (nerimux::client-conn-tree-scroll conn))))))
  (it "overview-status-key-opens-the-selected-worktree-status-view"
      (with-fake-session (s)
        (let* ((organization
                 (nerimux/workspace-model:make-organization :id "org-status"))
               (repository
                 (nerimux/workspace-model:make-repository
                  :id "repo-status" :organization organization))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "wt-status" :repository repository
                  :path "/tmp/wt-status" :branch "main"))
               (conn (%make-test-conn))
               (nerimux/vcs::*workspace-organizations* (list organization)))
          (nerimux/workspace-model:organization-add-repository organization repository)
          (nerimux/workspace-model:repository-add-worktree repository worktree)
          (nerimux::%set-client-selected-tree-object conn repository)
          (nerimux::%handle-multi-key-message s conn "v")
          (expect (eq :status (nerimux::client-conn-view conn)))
          (expect (eq worktree (nerimux::client-conn-selected-worktree conn))))))
  (it "overview-status-key-reports-when-no-worktree-is-selected"
      (with-fake-session (s)
        (let ((conn (%make-test-conn))
              (message nil))
          (with-stubbed-fdefinition
              ((nerimux::%client-notify
                 (lambda (received-conn received-message)
                   (declare (ignore received-conn))
                   (setf message received-message))))
            (nerimux::%handle-multi-key-message s conn "v"))
          (expect (eq :repolist (nerimux::client-conn-view conn)))
          (expect (string= "select a worktree first" message)))))
  (it "overview-status-key-resolves-repository-fallback-and-pane-worktrees"
      (with-fake-session (s)
        (let* ((organization
                 (nerimux/workspace-model:make-organization :id "org-status-fallback"))
               (repository
                 (nerimux/workspace-model:make-repository
                  :id "repo-status-fallback" :organization organization))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "wt-status-fallback" :repository repository
                  :path "/tmp/wt-status-fallback" :branch "feature/fallback"))
               (pane (make-no-pty-pane 71 0 0 20 5))
               (conn (%make-test-conn)))
          (nerimux/workspace-model:organization-add-repository organization repository)
          (nerimux/workspace-model:repository-add-worktree repository worktree)
          (setf (nerimux/workspace-model:repository-main-worktree repository) nil)
          (nerimux::%set-client-selected-tree-object conn repository)
          (expect (nerimux::%client-show-selected-status conn))
          (expect (eq :status (nerimux::client-conn-view conn)))
          (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))
          (setf (nerimux::client-conn-view conn) :repolist)
          (setf (nerimux/pane:pane-worktree pane) worktree)
          (nerimux::%set-client-selected-tree-object conn pane)
          (expect (nerimux::%client-show-selected-status conn))
          (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))
          (setf (nerimux::client-conn-view conn) :repolist)
          (nerimux::%set-client-selected-tree-object conn worktree)
          (expect (nerimux::%client-show-selected-status conn))
          (expect (eq :status (nerimux::client-conn-view conn)))
          (expect (eq worktree (nerimux::client-conn-selected-worktree conn))))))
)
