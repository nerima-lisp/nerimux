(in-package #:nerimux/test)

;;;; Pure selection, command, and picker helpers used by the multi-client UI.
(defun %make-server-dispatch-helper-fixture ()
  (let* ((organization
          (nerimux/workspace-model:make-organization :id
                                                     "org-id"
                                                     :host
                                                     "origin"
                                                     :name
                                                     "team"))
         (repository
          (nerimux/workspace-model:make-repository :id
                                                   "repo-id"
                                                   :organization
                                                   organization
                                                   :specification
                                                   "origin/team/repo"
                                                   :local-path
                                                   "/workspace/repo"))
         (main-worktree
          (nerimux/workspace-model:make-worktree :id
                                                 "main-id"
                                                 :repository
                                                 repository
                                                 :path
                                                 "/workspace/repo"
                                                 :branch
                                                 "main"))
         (feature-worktree
          (nerimux/workspace-model:make-worktree :id
                                                 "feature-id"
                                                 :repository
                                                 repository
                                                 :path
                                                 "/workspace/repo/feature"
                                                 :branch
                                                 "feature")))
    (nerimux/workspace-model:organization-add-repository organization
                                                         repository)
    (nerimux/workspace-model:repository-add-worktree repository main-worktree)
    (nerimux/workspace-model:repository-add-worktree repository
                                                     feature-worktree)
    (values (list organization)
            organization
            repository
            main-worktree
            feature-worktree)))

(describe "server-dispatch-helper-suite"

  ;;; -- with-loop-safe-error containment ---------------------------------------
  ;;;
  ;;; This macro carries the file's "never let one client take down the server
  ;;; loop" invariant, and had no test at all -- which is how it came to miss
  ;;; the one condition it most needed to contain.
  ;;;
  ;;; SB-EXT:TIMEOUT is a SERIOUS-CONDITION that is deliberately NOT an ERROR,
  ;;; so the obvious (ERROR ...) clause reads as if it catches everything and
  ;;; silently does not.  SEND-FRAME bounds every socket write with
  ;;; SB-EXT:WITH-TIMEOUT and documents itself as signalling exactly this, and
  ;;; %BROADCAST-FRAME runs it through this macro for every attached client on
  ;;; every dirty frame -- so one stalled peer escaped the handler and took the
  ;;; whole server down with it.
  ;;;
  ;;; The third case is not padding: it pins that the fix stayed NARROW.
  ;;; Widening to SERIOUS-CONDITION would also catch STORAGE-CONDITION, turning
  ;;; heap exhaustion into a per-client-per-frame retry loop instead of a
  ;;; fatal error.

  (it "with-loop-safe-error-contains-a-send-timeout"
    (let ((ran nil))
      (expect (eq :contained
                  (nerimux::with-loop-safe-error (nil :on-error :contained)
                    (setf ran t)
                    (sb-ext:with-timeout 0.05 (sleep 5)))))
      (expect ran)))

  (it "with-loop-safe-error-contains-an-ordinary-error-and-binds-it"
    (expect (search "boom"
                    (nerimux::with-loop-safe-error
                        (condition :on-error (princ-to-string condition))
                      (error "boom")))))

  (it "with-loop-safe-error-does-not-swallow-storage-condition"
    ;; Heap exhaustion must stay fatal; SIGNAL rather than a real allocation
    ;; failure, since the point is which clause matches, not how it arose.
    (expect (eq :propagated
                (handler-case
                    (nerimux::with-loop-safe-error (nil :on-error :wrongly-caught)
                      (signal 'storage-condition))
                  (storage-condition () :propagated)))))

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
            ;; Both worktrees here are clean and pane-less -- no Attention/
            ;; Active row of their own -- so they are reachable only through
            ;; the Repositories section, and a repository row defaults
            ;; COLLAPSED (*WORKSPACE-EXPANDED-NODE-IDS*, opposite polarity
            ;; from *WORKSPACE-COLLAPSED-NODE-IDS*). Pre-expanding REPOSITORY
            ;; here reveals them, mirroring what the pre-redesign fully-
            ;; expanded-by-default table used to give this fixture for free.
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
          ;; (Repositories header) (repository) (feature-worktree) (main-worktree)
          ;; -- REPOSITORY-ADD-WORKTREE prepends, so the more-recently-added
          ;; FEATURE-WORKTREE sorts before MAIN-WORKTREE.
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
        (expect (null (nerimux::%set-client-picker-regex conn nil t)))
        (expect (null (nerimux::client-conn-picker-regex-p conn)))
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

  (it "parses-command-options-and-resolves-client-context"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (let ((conn (nerimux::%make-client-conn))
            (inactive (nerimux::%make-client-conn))
            (other-conn (nerimux::%make-client-conn))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations))
        (setf nerimux::*clients* (list conn))
        (multiple-value-bind (target args)
            (nerimux::%client-command-target-and-args
             '("--target" "repo-id" "--confirm"))
          (expect (string= "repo-id" target))
          (expect (equal '("--confirm") args)))
        (multiple-value-bind (target args)
            (nerimux::%client-command-target-and-args '("--confirm"))
          (expect (null target))
          (expect (equal '("--confirm") args)))
        (expect (eq :forward (nerimux::%client-search-direction "/")))
        (expect (eq :backward (nerimux::%client-search-direction "?")))
        (expect (null (nerimux::%client-search-direction "other")))
        (expect (string= "one  two"
                         (nerimux::%client-search-term '(" one " "two"))))
        (expect (string= "value"
                         (nerimux::%client-option-value
                          '("--name=value") '("--name"))))
        (expect (string= "value"
                         (nerimux::%client-option-value
                          '("--name" "value") '("--name"))))
        (expect (null (nerimux::%client-option-value
                      '("--other" "value") '("--name"))))
        (expect (nerimux::%client-boolean-option-p
                 '("--confirm") '("--confirm" "confirm")))
        (expect (null (nerimux::%client-boolean-option-p
                      '("--other") '("--confirm"))))
        (expect (= 17 (nerimux::%parse-client-key-code 17)))
        (expect (= #x11 (nerimux::%parse-client-key-code "c-q")))
        (expect (= (char-code #\x)
                   (nerimux::%parse-client-key-code "x")))
        (expect (null (nerimux::%parse-client-key-code "not-a-key")))
        (expect (nerimux::%client-live-p conn))
        (expect (null (nerimux::%client-live-p other-conn)))
        (expect (string= "feature"
                         (nerimux::%client-positional-branch
                          '("--branch" "main" "feature"))))
        (expect (null (nerimux::%client-positional-branch
                       '("--confirm"))))
        (expect (null (nerimux::%client-positional-branch
                       '("confirm" "force"))))
        (expect (nerimux::%client-create-worktree
                 conn "repo-id" '("--confirm")))
        (expect (search "worktree create requires a branch"
                        (first (nerimux::client-conn-message-log conn))))
        (expect (eq :input
                    (nerimux::%set-client-ui-mode conn :input)))
        ;; Magit alignment (contract §5): :cancel now maps to MODAL nil
        ;; rather than the old MODE vocabulary word :normal.
        (expect (null (nerimux::%transition-client-ui-mode conn :cancel)))
        (expect (eq :picker
                    (nerimux::%client-ui-mode-value "picker")))
        (expect (null (nerimux::%client-ui-mode-value "invalid")))
        (expect (eq repository
                    (nerimux::%client-selected-repository conn organization)))
        (expect (eq organization
                    (nerimux::%client-selected-organization conn repository)))
        (expect (eq feature-worktree
                    (nerimux::%client-operation-worktree conn "feature-id")))
        (expect (string= "notice" (nerimux::%client-notify conn "notice")))
        (expect (find "notice" (nerimux::client-conn-message-log conn)
                      :test #'string=))
        (expect (nerimux::%client-attach-target
                 conn '("feature-id" "/workspace/repo/feature")))
        (expect (string= "feature-id"
                         (nerimux::client-conn-attach-target conn)))
        (expect (string= "/workspace/repo/feature"
                         (nerimux::client-conn-attach-cwd conn)))
         (expect (= #x02
                    (progn
                      (nerimux::%client-rebind-prefix conn "c-b")
                      (nerimux::client-conn-workspace-prefix-code conn))))
         (expect (nerimux::%client-rebind-prefix conn "not-a-key"))
         (expect (find "invalid workspace prefix key"
                       (nerimux::client-conn-message-log conn)
                       :test #'string=)
                :to-be-truthy))))

  (it "resolves-workspace-tokens-by-kind-and-ignores-option-values"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable main-worktree))
      (let ((conn (nerimux::%make-client-conn)))
        (expect (null (nerimux::%workspace-find-tree-object nil organizations)))
        (expect (eq organization
                    (nerimux::%workspace-find-tree-object
                     (list :organization "org-id") organizations)))
        (expect (eq repository
                    (nerimux::%workspace-find-tree-object
                     (list :repository "repo-id") organizations)))
        (expect (eq feature-worktree
                    (nerimux::%workspace-find-tree-object
                     (list :worktree "feature-id") organizations)))
        (expect (eq organization
                    (nerimux::%workspace-find-tree-object
                     organization organizations)))
        (expect (eq repository
                    (nerimux::%workspace-find-tree-object
                     repository organizations)))
        (expect (eq feature-worktree
                    (nerimux::%workspace-find-tree-object
                     feature-worktree organizations)))
        (expect (eq "section-value"
                    (nerimux::%workspace-find-tree-object
                     '(:section "section-value") organizations)))
        (expect (null (nerimux::%workspace-find-tree-object
                       (list :unknown "value") organizations)))
        (expect (null (nerimux::%client-positional-branch
                       '("--branch"))))
        (expect (eq organization
                    (nerimux::%client-selected-organization conn organization)))
        (expect (eq repository
                    (nerimux::%client-selected-repository conn repository)))
        (expect (eq repository
                    (nerimux::%client-selected-repository conn feature-worktree)))
        (expect (eq organization
                    (nerimux::%client-selected-organization conn repository)))
        (expect (eq organization
                    (nerimux::%client-selected-organization conn feature-worktree)))
        (let ((second-repository
                (nerimux/workspace-model:make-repository
                 :id "second-repo-id"
                 :organization organization
                 :specification "origin/team/second-repo")))
          (push second-repository
                (nerimux/workspace-model:organization-repositories
                 organization))
          (expect (null (nerimux::%client-selected-repository
                         conn organization))))
        (let ((orphan-worktree
                (nerimux/workspace-model:make-worktree
                 :id "orphan-worktree-id")))
          (expect (null (nerimux::%client-selected-repository
                         conn orphan-worktree)))
          (expect (null (nerimux::%client-selected-organization
                         conn orphan-worktree))))
        )))

  (it "keeps-empty-selection-without-focus"
    (let ((conn (nerimux::%make-client-conn)))
      (expect (null (nerimux::%client-context-object conn nil)))
      (expect (null (nerimux::%client-selected-repository conn)))
      (expect (null (nerimux::%client-selected-organization conn)))
      (expect (null (nerimux::%client-operation-worktree conn)))))

  (it "resolves-operations-from-the-focused-pane-worktree"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore main-worktree))
      (let* ((conn (nerimux::%make-client-conn))
             (pane (nerimux/pane:make-pane :worktree feature-worktree))
             (nerimux/vcs::*workspace-organizations* organizations))
        (setf (nerimux::client-conn-focus conn) pane)
        (expect (eq feature-worktree
                    (nerimux::%client-context-object conn nil)))
        (expect (eq feature-worktree
                    (nerimux::%client-operation-worktree conn)))
        (expect (eq repository
                    (nerimux::%client-selected-repository conn)))
        (expect (eq organization
                    (nerimux::%client-selected-organization conn))))))

  (it "resolves-workspace-identifiers-and-guards-inactive-notifications"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (let ((conn (nerimux::%make-client-conn))
            (inactive (nerimux::%make-client-conn))
            (anonymous-organization
              (nerimux/workspace-model:make-organization
               :host "origin" :name "team"))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations))
        (expect (eq repository
                    (nerimux::%workspace-find-repository
                     "origin/team/repo" organizations)))
        (expect (eq repository
                    (nerimux::%workspace-find-repository
                     "/workspace/repo" organizations)))
        (expect (eq repository
                    (nerimux::%workspace-find-repository
                     repository organizations)))
        (expect (eq organization
                    (nerimux::%workspace-find-organization
                     "team" organizations)))
        (expect (eq anonymous-organization
                    (nerimux::%workspace-find-organization
                     "origin/team" (list anonymous-organization))))
        (expect (eq organization
                    (nerimux::%workspace-find-organization
                     organization organizations)))
        (expect (eq main-worktree
                    (nerimux::%workspace-find-tree-object
                     "main-id" organizations)))
        (expect (eq repository
                    (nerimux::%workspace-find-tree-object
                     "repo-id" organizations)))
        (expect (string= "feature-value"
                         (nerimux::%client-positional-branch
                          '("--branch" "main" "feature-value"))))
        (expect (string= "path-value"
                         (nerimux::%client-positional-branch
                          '("--path" "/tmp/path" "path-value"))))
        (setf nerimux::*clients* (list conn))
        (expect (string= "inactive"
                         (nerimux::%client-notify inactive "inactive")))
        (expect (null (nerimux::client-conn-message-log inactive)))
        (expect (null nerimux::*dirty*))
        (expect (eq feature-worktree
                    (nerimux::%client-operation-worktree conn
                                                          "feature-id"))))))

  (it "parses-payloads-and-transitions-client-modes"
    (let ((conn (nerimux::%make-client-conn))
          (nerimux::*dirty* nil))
      (expect (= 65 (nerimux::%client-single-byte (vector 65))))
      (expect (= 65 (nerimux::%client-single-byte "A")))
      (expect (null (nerimux::%client-single-byte (vector 65 66))))
      (expect (null (nerimux::%client-single-byte (make-array '(1 1) :initial-element 65))))
      (expect (nerimux::%client-byte-p (vector 17) 17))
      (expect (nerimux::%client-key-p "q" #\q))
      (expect (string= "A"
                       (nerimux::%client-payload-text
                        (make-array 1
                                    :element-type '(unsigned-byte 8)
                                    :initial-element 65))))
      (expect (string= "text" (nerimux::%client-payload-text "text")))
      (expect (null (nerimux::%client-payload-text nil)))
      (expect (null
               (nerimux::%client-payload-text
                (make-array 1
                            :element-type '(unsigned-byte 8)
                            :initial-element #xFF))))
      (expect (nerimux::%client-ui-mode-p :normal))
      (expect (null (nerimux::%client-ui-mode-p :unknown)))
      (expect (eq :copy (nerimux::%client-ui-mode-value 'copy)))
      (expect (eq :picker (nerimux::%client-ui-mode-value "PICKER")))
      (expect (null (nerimux::%client-ui-mode-value 42)))
      (dolist (mapping '((:normal nil)
                         (:enter-normal nil)
                         (:cancel nil)
                         (:accept nil)
                         (:input :view-pane)
                         (:enter-input :view-pane)
                         (:copy :scrollback)
                         (:enter-copy :scrollback)
                         (:command :command)
                         (:enter-command :command)
                         (:picker :picker)
                         (:enter-picker :picker)
                         (:tree-filter :filter)
                         (:enter-tree-filter :filter)
                         (:unknown :unchanged)))
        (expect (eq (second mapping)
                    (nerimux::%client-ui-mode-target-modal (first mapping)))))
      ;; %client-enter-input-mode retired with the `i` key it existed to
      ;; implement (contract §5): VIEW :pane is now reached only by focusing
      ;; a pane, never by an explicit "enter input" step. Confirm the
      ;; replacement primitive lands there and that %client-ui-keys-p
      ;; correctly derives "no" for it.
      (expect (eq :pane (nerimux::%set-client-view conn :pane)))
      (expect (null (nerimux::%client-ui-keys-p conn)))
      (expect (eq :copy (nerimux::%set-client-ui-mode conn :copy)))
      ;; MODAL was :scrollback (from :copy above); :toggle-copy flips it to
      ;; nil, then the second call flips it back -- %transition-client-ui-
      ;; mode now returns the MODAL value itself, not the old MODE word.
      (expect (null (nerimux::%transition-client-ui-mode
                     conn :toggle-copy)))
      (expect (eq :scrollback
                  (nerimux::%transition-client-ui-mode
                   conn :toggle-copy)))
      (expect (eq :scrollback
                  (nerimux::%transition-client-ui-mode
                   conn :unrecognized-event)))
      (expect (eq :repolist (nerimux::%set-client-view conn :repolist)))
      (expect (eq :repolist (nerimux::%set-client-view conn :invalid)))
      (expect (nerimux::%client-enter-command-mode conn "command"))
      (expect (eq :command (nerimux::client-conn-modal conn)))
      (expect (string= "command"
                       (nerimux::client-conn-command-buffer conn)))
      (expect (eq :repolist
                  (nerimux::client-conn-command-return-view conn)))
      ;; :accept maps to MODAL nil (contract §5) -- leaving :command clears
      ;; the buffer and the return-view, same as before under the old
      ;; :normal spelling.
      (expect (null (nerimux::%transition-client-ui-mode conn :accept)))
      (expect (string= "" (nerimux::client-conn-command-buffer conn)))
      (expect (null (nerimux::client-conn-command-return-view conn)))
      (expect (nerimux::%client-enter-command-mode conn 42))
      (expect (string= "" (nerimux::client-conn-command-buffer conn)))))

  (it "focus-and-copy-boundaries-keep-client-state-consistent"
    (let ((session (nerimux/session:make-session :id 1 :name "test"))
          (conn (nerimux::%make-client-conn))
          (notifications nil))
      (nerimux::%set-client-view conn :status)
      (expect (null (nerimux::%set-client-focus conn nil)))
      (expect (null (nerimux::client-conn-focus conn)))
      (expect (= 0 (nerimux::client-conn-viewport conn)))
      (expect (eq :pane (nerimux::client-conn-view conn)))
      (with-stubbed-fdefinition
          ((nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message notifications))))
        (expect (null (nerimux::%client-enter-copy-mode session conn)))
        (expect (equal '("no focused pane") notifications)))
      (expect (nerimux::%client-exit-copy-mode session conn))
      (expect (null (nerimux::client-conn-modal conn)))))

  (it "command-buffer-delete-character-is-safe-at-both-boundaries"
    (let ((conn (nerimux::%make-client-conn)))
      (setf (nerimux::client-conn-command-buffer conn) "abc")
      (expect (nerimux::%client-command-buffer-delete-character conn))
      (expect (string= "ab" (nerimux::client-conn-command-buffer conn)))
      (setf (nerimux::client-conn-command-buffer conn) "")
      (expect (null (nerimux::%client-command-buffer-delete-character conn)))
      (expect (string= "" (nerimux::client-conn-command-buffer conn)))))

  (it "command-buffer-append-accepts-printable-text-only"
    (let ((conn (nerimux::%make-client-conn)))
      (expect (nerimux::%client-command-buffer-append conn "ab"))
      (expect (string= "ab" (nerimux::client-conn-command-buffer conn)))
      (expect (null (nerimux::%client-command-buffer-append conn #(10))))
      (expect (string= "ab" (nerimux::client-conn-command-buffer conn)))
      (expect (null (nerimux::%client-command-buffer-append
                     conn (make-array '(1 1) :initial-element 65))))))

  (it "submitting-an-empty-command-clears-command-state"
    (let ((session (nerimux/session:make-session :id 1 :name "test"))
          (conn (nerimux::%make-client-conn)))
      (setf (nerimux::client-conn-command-buffer conn) "  ")
      (nerimux::%set-client-view conn :command)
      (nerimux::%set-client-modal conn :command)
      (expect (nerimux::%submit-client-command session conn))
      (expect (string= "" (nerimux::client-conn-command-buffer conn)))
      (expect (eq :repolist (nerimux::client-conn-view conn)))
      (expect (null (nerimux::client-conn-modal conn)))))

  (it "submitting-a-command-reports-tokenizer-failures-and-cleans-up"
    (let ((session (nerimux/session:make-session :id 1 :name "test"))
          (conn (nerimux::%make-client-conn))
          (messages nil))
      (setf (nerimux::client-conn-command-buffer conn) "broken input")
      (nerimux::%set-client-view conn :command)
      (nerimux::%set-client-modal conn :command)
      (with-stubbed-fdefinition
          ((nerimux/commands:tokenize-command-string
             (lambda (input)
               (declare (ignore input))
               (error "tokenizer failure")))
           (nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message messages))))
        (expect (nerimux::%submit-client-command session conn)))
      (expect (equal '("command failed: tokenizer failure") messages))
      (expect (string= "" (nerimux::client-conn-command-buffer conn)))
      (expect (eq :repolist (nerimux::client-conn-view conn)))
      (expect (null (nerimux::client-conn-modal conn)))))

  (it "computes-copy-mode-half-page-with-a-one-row-minimum"
    (let ((one-row-pane (nerimux/pane:make-pane
                         :id 1 :screen (make-screen 10 1)))
          (four-row-pane (nerimux/pane:make-pane
                          :id 2 :screen (make-screen 10 4))))
      (expect (= 1 (nerimux::%copy-mode-half-page-delta one-row-pane)))
      (expect (= 2 (nerimux::%copy-mode-half-page-delta four-row-pane)))
      (expect (= 12 (nerimux::%copy-mode-half-page-delta nil)))))

  (it "command-state-projections-preserve-valid-views-and-generate-worktree-names"
    (let ((conn (nerimux::%make-client-conn)))
      (setf (nerimux::client-conn-view conn) :status)
      (nerimux::%client-enter-command-mode conn "git status")
      (expect (eq :status
                  (nerimux::client-conn-command-return-view conn)))
      (nerimux::%client-restore-command-view conn)
      (expect (eq :status (nerimux::client-conn-view conn)))
      (expect (null (nerimux::client-conn-command-return-view conn)))
      (setf (nerimux::client-conn-command-return-view conn) :unknown)
      (nerimux::%client-restore-command-view conn)
      (expect (eq :status (nerimux::client-conn-view conn)))
      (expect (null (nerimux::client-conn-command-return-view conn)))
      (let ((name (nerimux::%client-worktree-create-branch-name)))
        (expect (and (stringp name)
                     (uiop:string-prefix-p "wt-" name)))
        (expect (= 18 (length name))))))

  (it "input-and-copy-dispatch-report-missing-focus"
    (let ((session (nerimux/session:make-session :id 1 :name "test"))
          (conn (nerimux::%make-client-conn)))
      (expect (nerimux::%handle-client-input-key-payload
               session conn "x"))
      (expect (nerimux::%handle-client-copy-key-payload
               session conn "q"))
      ;; No focused pane -> %copy-key-dispatch's (null screen) clause fires,
      ;; which transitions via :enter-normal -- MODAL nil under contract §5,
      ;; not the old MODE word :normal.
      (expect (null (nerimux::client-conn-modal conn)))))

  ;; Magit alignment (contract SS2 "scrollback", FR-008): the scrollback
  ;; table is j/k line, C-u/C-d (byte 21/4) half page, g/G top/bottom, /
  ;; ? search, n/N search next/prev, Space begin selection, y yank, q leave
  ;; -- 13 keys, replacing the old j/k/h/l/g/G/Space/y/n/N/[/?/q table (h/l
  ;; horizontal movement dropped, C-u/C-d half-page added). q's own leave
  ;; action no longer calls %CLIENT-EXIT-COPY-MODE (see the header comment
  ;; on %HANDLE-CLIENT-COPY-KEY-PAYLOAD): it drops MODAL inline, so it is the
  ;; one bound key with no stub above to record it -- the other 12 each
  ;; drive exactly one stubbed call.
  (it "copy-dispatches-every-bound-key-through-one-contract"
    (let* ((session (nerimux/session:make-session :id 1 :name "test"))
           (conn (nerimux::%make-client-conn))
           (pane (make-no-pty-pane 1 0 0 4 4))
           (calls nil))
      (with-stubbed-fdefinition
          ((nerimux::%resolve-client-focus-pane
             (lambda (&rest arguments) (declare (ignore arguments)) pane))
           (nerimux::copy-mode-move-cursor
             (lambda (&rest arguments) (push (cons :move arguments) calls)))
           (nerimux::copy-mode-scroll
             (lambda (&rest arguments) (push (cons :scroll arguments) calls)))
           (nerimux::copy-mode-begin-selection
             (lambda (screen) (push (list :begin screen) calls)))
           (nerimux::copy-mode-yank
             (lambda (screen) (push (list :yank screen) calls)))
           (nerimux::copy-mode-search-next
             (lambda (screen) (push (list :next screen) calls)))
           (nerimux::copy-mode-search-prev
             (lambda (screen) (push (list :prev screen) calls)))
           (nerimux::%client-enter-command-mode
             (lambda (connection command)
               (push (list :command connection command) calls))))
        (dolist (key (list #\k #\j (vector 21) (vector 4) #\g #\G #\Space
                           #\y #\n #\N #\/ #\? #\q))
          (nerimux::%handle-client-copy-key-payload
           session conn (if (characterp key) (string key) key)))
        (expect (= 12 (length calls)))
        (expect (search "search-backward "
                        (format nil "~S" calls)))
        (expect (search "search-forward "
                        (format nil "~S" calls)))
        ;; q's observable effect, since it has no stub call of its own.
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "ui-key-dispatch-covers-common-and-status-contracts"
    (let* ((session (nerimux/session:make-session :id 1 :name "test"))
           (conn (nerimux::%make-client-conn))
           (calls 0)
           (record (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (incf calls))))
      (with-stubbed-fdefinition
          ((nerimux::%client-meta-pending-consume record)
           (nerimux::%select-client-tree-relative record)
           (nerimux::%client-toggle-selected-tree-row record)
           (nerimux::%client-set-visibility-level record)
           (nerimux::%focus-selected-client-worktree record)
           (nerimux::%client-refresh-workspace record)
           (nerimux::%client-step-back record)
           (nerimux::%client-open-selected-worktree-command record)
           (nerimux::%set-client-modal record)
           (nerimux::%client-enter-tree-filter-mode record)
           (nerimux::%client-enter-command-mode record)
           (nerimux::%open-client-transient record)
           (nerimux::%client-stage-selection record)
           (nerimux::%client-stage-all record)
           (nerimux::%client-unstage-selection record)
           (nerimux::%client-unstage-all record)
           (nerimux::%client-start-discard-selection record))
        (dolist (payload '("n" "p" #(9) "1" "2" "3" "4"
                           #(13) #(10) "g" "q" "$" "/" ":" "?"))
          (nerimux::%handle-client-ui-key-payload session conn payload))
        (setf (nerimux::client-conn-view conn) :repolist)
        (dolist (payload '("t" "c" "x"))
          (nerimux::%handle-client-ui-key-payload session conn payload))
        (setf (nerimux::client-conn-view conn) :status)
        (dolist (payload '("s" "S" "u" "U" "k" "c" "P" "F" "b"
                           "m" "r" "z" "l" "d" "f" "t" "X" "!" "w"))
          (nerimux::%handle-client-ui-key-payload session conn payload))
        (setf (gethash conn nerimux::*client-meta-pending*) :second)
        (nerimux::%handle-client-ui-key-payload session conn "x")
        (remhash conn nerimux::*client-meta-pending*)
        (expect (= 38 calls)))))

  (it "open-selected-worktree-command-reports-missing-selection"
    (let ((conn (nerimux::%make-client-conn))
          (notifications nil)
          (selections 0))
      (with-stubbed-fdefinition
          ((nerimux::%select-client-tree-worktree
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (incf selections)))
           (nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message notifications))))
        (expect (nerimux::%client-open-selected-worktree-command
                 nil conn nil))
        (expect (= 1 selections))
        (expect (equal '("no worktree selected") notifications)))))

  (it "open-selected-worktree-command-opens-the-selected-worktree"
    (let ((conn (nerimux::%make-client-conn))
          (calls nil))
      (setf (nerimux::client-conn-selected-worktree conn) :worktree)
      (with-stubbed-fdefinition
          ((nerimux::%open-client-worktree-pane
             (lambda (&rest arguments)
               (setf calls arguments)
               t)))
        (expect (nerimux::%client-open-selected-worktree-command
                 :session conn :shell))
        (expect (equal (list :session conn :worktree :default-command :shell)
                       calls)))))

  (it "status-write-reports-transient-write-errors"
    (let ((conn (nerimux::%make-client-conn))
          (notifications nil))
      (with-stubbed-fdefinition
          ((nerimux::%run-transient-git-write
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "write failed")))
           (nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message notifications))))
        (expect (nerimux::%client-run-status-write
                 conn :repository :stage '("--" "file")))
        (expect (= 1 (length notifications)))
        (expect (search "git stage: failed:" (first notifications))))))

  (it "status-commands-report-missing-selection-through-one-contract"
    (let ((conn (nerimux::%make-client-conn))
          (notifications nil))
      (with-stubbed-fdefinition
          ((nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message notifications)))
           (nerimux::%client-selected-status-file
             (lambda (connection)
               (declare (ignore connection))
               nil)))
        (dolist (command (list #'nerimux::%client-stage-selection
                               #'nerimux::%client-stage-all
                               #'nerimux::%client-unstage-selection
                               #'nerimux::%client-unstage-all
                               #'nerimux::%client-start-discard-selection))
          (funcall command conn))
        (expect (= 5 (length notifications)))
        (expect (= 3 (count "select a file first" notifications :test #'string=)))
        (expect (= 2 (count "no worktree selected" notifications :test #'string=))))))

  (it "workspace-refresh-command-wires-completion-and-error-notifications"
    (let ((conn (nerimux::%make-client-conn))
          (notifications nil)
          (completion-callback nil)
          (error-callback nil))
      (with-stubbed-fdefinition
          ((nerimux::%refresh-client-picker
             (lambda (connection &key on-complete on-error)
               (declare (ignore connection))
               (setf completion-callback on-complete
                     error-callback on-error)))
           (nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message notifications))))
        (expect (nerimux::%client-refresh-workspace conn))
        (expect (functionp completion-callback))
        (expect (functionp error-callback))
        (funcall completion-callback nil)
        (funcall error-callback (make-condition 'simple-error
                                                :format-control "boom"))
        (expect (equal '("workspace refresh failed: boom"
                         "workspace refresh complete"
                         "workspace refresh started")
                       notifications)))))

  (it "open-worktree-pane-reports-invalid-paths"
    (let ((conn (nerimux::%make-client-conn))
          (notifications nil))
      (with-stubbed-fdefinition
          ((nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message notifications))))
        (dolist (case '(("" nil "worktree has no path")
                        ("/workspace/missing" t "worktree is missing")))
          (destructuring-bind (path missing-p message) case
            (let ((worktree
                    (nerimux/workspace-model:make-worktree
                     :id "invalid-worktree"
                     :path path
                     :missing-p missing-p)))
              (expect (null (nerimux::%open-client-worktree-pane
                             nil conn worktree)))
              (expect (equal (list message) notifications))
              (setf notifications nil)))))))

  ;; Magit alignment (contract SS5): %SUBMIT-CLIENT-SEARCH now closes MODAL
  ;; and restores VIEW by calling %SET-CLIENT-MODAL / %CLIENT-RESTORE-
  ;; COMMAND-VIEW directly, not by routing through the retired event
  ;; vocabulary of %TRANSITION-CLIENT-UI-MODE -- so this asserts the
  ;; OBSERVABLE result of both calls (view restored, return-view cleared,
  ;; modal dropped) rather than a call count through a function this helper
  ;; no longer touches.
  (it "search-submit-reports-invalid-input-and-restores-view"
    (let* ((session (nerimux/session:make-session :id 1 :name "test"))
           (conn (nerimux::%make-client-conn))
           (messages nil))
      (setf (nerimux::client-conn-command-return-view conn) :status
            (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-modal conn :command)
      (with-stubbed-fdefinition
          ((nerimux::%resolve-client-focus-pane
             (lambda (&rest arguments) (declare (ignore arguments)) nil))
           (nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message messages))))
        (nerimux::%submit-client-search session conn :forward '("needle"))
        (nerimux::%submit-client-search session conn :backward nil))
      (expect (equal '("no focused pane" "no focused pane") messages))
      (expect (eq :status (nerimux::client-conn-view conn)))
      (expect (null (nerimux::client-conn-command-return-view conn)))
      (expect (null (nerimux::client-conn-modal conn)))))

  (it "search-submit-reports-empty-terms-before-searching"
    (let* ((session (nerimux/session:make-session :id 1 :name "test"))
           (conn (nerimux::%make-client-conn))
           (pane (make-no-pty-pane 1 0 0 4 4))
           (messages nil)
           (searches 0))
      (nerimux::%set-client-view conn :status)
      (nerimux::%set-client-modal conn :command)
      (with-stubbed-fdefinition
          ((nerimux::%resolve-client-focus-pane
             (lambda (&rest arguments) (declare (ignore arguments)) pane))
           (nerimux::copy-mode-search-forward
             (lambda (&rest arguments) (declare (ignore arguments))
               (incf searches)))
           (nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message messages))))
        (nerimux::%submit-client-search session conn :forward '("  ")))
      (expect (equal '("search term is empty") messages))
      (expect (= 0 searches))
      (expect (eq :status (nerimux::client-conn-view conn)))
      (expect (null (nerimux::client-conn-modal conn)))))

  (it "search-submit-dispatches-both-directions"
    (let* ((session (nerimux/session:make-session :id 1 :name "test"))
           (conn (nerimux::%make-client-conn))
           (pane (make-no-pty-pane 1 0 0 4 4))
           (directions nil))
      (nerimux::%set-client-view conn :status)
      (nerimux::%set-client-modal conn :command)
      (with-stubbed-fdefinition
          ((nerimux::%resolve-client-focus-pane
             (lambda (&rest arguments) (declare (ignore arguments)) pane))
           (nerimux::copy-mode-search-forward
             (lambda (&rest arguments) (declare (ignore arguments))
               (push :forward directions)))
           (nerimux::copy-mode-search-backward
             (lambda (&rest arguments) (declare (ignore arguments))
               (push :backward directions))))
        (nerimux::%submit-client-search session conn :forward '("needle"))
        (nerimux::%set-client-modal conn :command)
        (nerimux::%submit-client-search session conn :backward '("needle")))
      (expect (equal '(:backward :forward) directions))
      (expect (eq :status (nerimux::client-conn-view conn)))
      (expect (null (nerimux::client-conn-modal conn)))))

  ;; Magit alignment (contract §2, "KEYS THAT NO LONGER EXIST"): d, o, and i
  ;; are all retired from the UI keymap -- d/o used to flip client-conn-view
  ;; between :overview and :detail directly, and i (%client-enter-input-mode,
  ;; now gone entirely) was the only way into what is now the VIEW derived
  ;; by focusing a pane. %handle-client-normal-key-payload itself is REPLACED
  ;; by %handle-client-ui-key-payload (contract §5). None of the three has a
  ;; new binding, so striking any of them must be a pure no-op: no VIEW
  ;; change, no MODAL entered.
  (it "retired-view-switch-keys-d-o-i-are-unbound-in-the-ui-keymap"
    (let ((session (nerimux/session:make-session :id 1 :name "test"))
          (conn (nerimux::%make-client-conn))
          (nerimux::*dirty* nil))
      (dolist (payload '("d" "o" "i"))
        (nerimux::%set-client-modal conn nil)
        (nerimux::%set-client-view conn :repolist)
        (expect (null (nerimux::%handle-client-ui-key-payload session conn payload)))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "command-target-and-search-helpers-preserve-argument-shape"
    (multiple-value-bind (target args)
        (nerimux::%client-command-target-and-args '("--target" "pane" "x"))
      (expect (string= "pane" target))
      (expect (equal '("x") args)))
    (multiple-value-bind (target args)
        (nerimux::%client-command-target-and-args '("x" "y"))
      (expect (null target))
      (expect (equal '("x" "y") args)))
    (expect (eq :forward (nerimux::%client-search-direction "SEARCH-FORWARD")))
    (expect (eq :backward (nerimux::%client-search-direction "?")))
    (expect (null (nerimux::%client-search-direction "other")))
    (expect (string= "hello  world"
                     (nerimux::%client-search-term '(" hello " "world ")))))

  (it "selects-picker-items-and-normalizes-attach-tokens"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (let ((conn (nerimux::%make-client-conn))
            (nerimux/vcs::*workspace-organizations* organizations))
        (let ((items (nerimux::%client-picker-items conn)))
          (expect (consp items))
          (expect (eq items (nerimux::%client-picker-items conn)))
          (setf (nerimux::client-conn-picker-index conn) 999)
          (expect (= (1- (length items))
                     (nerimux::%picker-clamp-index conn items)))
          (setf (nerimux::client-conn-picker-index conn) -1)
          (expect (zerop (nerimux::%picker-clamp-index conn items)))
          (expect (zerop (nerimux::%picker-clamp-index conn nil))))
        (let* ((items (nerimux/picker:build-global-picker-items
                      organizations))
               (organization-item
                 (find-if (lambda (item)
                            (eq :organization
                                (nerimux/picker:picker-item-kind item)))
                          items))
               (repository-item
                 (find-if (lambda (item)
                            (eq :repository
                                (nerimux/picker:picker-item-kind item)))
                          items))
               (worktree-item
                 (find-if (lambda (item)
                            (and (eq :worktree
                                      (nerimux/picker:picker-item-kind item))
                                 (eq feature-worktree
                                     (nerimux/picker:picker-item-worktree
                                      item))))
                          items)))
          (expect (eq feature-worktree
                      (nerimux::%picker-item-worktree worktree-item)))
          (expect (member (nerimux::%picker-item-worktree repository-item)
                          (list main-worktree feature-worktree)
                          :test #'eq))
          (expect (member (nerimux::%picker-item-worktree organization-item)
                          (list main-worktree feature-worktree)
                          :test #'eq))
          (expect (= 1
                     (length (nerimux::%deduplicate-client-picker-items
                              (list worktree-item worktree-item)))))
          (expect (string= "org-id"
                         (nerimux::%organization-selection-token
                          organization)))
          (expect (string= "repo-id"
                         (nerimux::%repository-selection-token repository)))
          (expect (string= "feature-id"
                         (nerimux::%worktree-selection-token feature-worktree)))
          (expect (null (nerimux::%tree-object-selection-token 42)))
          (expect (eq feature-worktree
                      (nerimux::%workspace-find-worktree
                       "feature" organizations)))
          (expect (null (nerimux::%workspace-find-worktree
                         nil organizations)))
          (expect (nerimux::%workspace-directory-prefix-p
                   "/workspace/repo/" "/workspace/repo/"))
          (expect (null (nerimux::%workspace-directory-prefix-p
                         "" "/workspace/repo")))
          (expect (null (nerimux::%workspace-directory-prefix-p
                         "/workspace/repo/" "/workspace/repo")))
          (expect (eq repository
                      (nerimux::%workspace-find-repository-for-attach
                       "/workspace/repo" organizations)))
          (expect (eq repository
                      (nerimux::%workspace-find-repository-for-attach
                       "repo-id" organizations)))
          (expect (null (nerimux::%workspace-find-repository-for-attach
                         42 organizations)))
          (setf (nerimux::client-conn-selected-tree-object conn)
                feature-worktree
                (nerimux::client-conn-selected-worktree conn)
                main-worktree)
          (expect (eq feature-worktree (nerimux::%client-tree-object conn)))
          (setf (nerimux::client-conn-selected-tree-object conn) nil)
          (expect (eq main-worktree (nerimux::%client-tree-object conn)))))))

  ;; F9 regression: a freshly attached client has NO selection at all --
  ;; %client-tree-object returns nil (no selected-tree-object, no
  ;; selected-worktree, no focus pane). The FIRST Enter used to bind OBJECT to
  ;; that nil before dispatching, miss every typep clause, and fall into the
  ;; catch-all worktree branch -- which selected row 0 as a side effect but
  ;; then read a still-nil client-conn-selected-worktree and reported "no
  ;; worktree selected", even though row 0 was a perfectly good row that
  ;; should have toggled. Only the SECOND Enter worked, because the first
  ;; one's fallback had, by then, set up state for it.
  (it "first-enter-on-a-fresh-client-toggles-the-default-row-not-a-nil-selection"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo" :organization organization
              :specification "github.com/team/repo"))
           (conn (nerimux::%make-client-conn))
           (nerimux/vcs::*workspace-organizations* (list organization))
           ;; Section-based redesign: row 0 of a fresh, unfiltered tree is
           ;; the Repositories section header (its ROW's OBJECT is the
           ;; :REPOSITORIES keyword, not an organization) -- sections start
           ;; EXPANDED (absent from this table), so the first Enter's toggle
           ;; must COLLAPSE it.
           (nerimux::*workspace-collapsed-node-ids*
             (make-hash-table :test #'equal))
           (nerimux::*clients* (list conn))
           (nerimux::*dirty* nil))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (setf (nerimux::client-conn-view conn) :repolist)
      ;; Fresh conn: nothing selected, nothing focused.
      (expect (null (nerimux::%client-tree-object conn)))
      (expect (nerimux::%focus-selected-client-worktree nil conn))
      ;; The Repositories section header (the only row, expanded by default)
      ;; must have toggled to collapsed ...
      (expect (gethash (list :section :repositories)
                       nerimux::*workspace-collapsed-node-ids*))
      ;; ... and the nil-selection catch-all must never have fired.
      (expect (null (find "no worktree selected"
                         (nerimux::client-conn-message-log conn)
                         :test #'string=)))))

  ;; Empty-catalog edge: no organizations at all (as opposed to the test
  ;; above, one organization with no selection yet). This is a
  ;; characterization test pinning current correct behavior, not a fix
  ;; guard -- %select-client-tree-worktree/%workspace-find-tree-object/
  ;; %client-tree-object (server-multi-dispatch-picker.lisp,
  ;; server-multi-dispatch-command-workspace.lisp) are all nil-safe over an
  ;; empty organizations list, so the catch-all branch in
  ;; %focus-selected-client-worktree (server-multi-dispatch-command-input.lisp)
  ;; is reached the same way as the fresh-client case above, and reports
  ;; "no worktree selected" without signalling.
  (it "focus-selected-client-worktree-on-an-empty-catalog-reports-no-worktree-selected"
    (let* ((conn (nerimux::%make-client-conn))
           (nerimux/vcs::*workspace-organizations* nil)
           (nerimux::*clients* (list conn))
           (nerimux::*dirty* nil))
      (expect (eq t (nerimux::%focus-selected-client-worktree nil conn)))
      (expect (equal (list "no worktree selected")
                      (nerimux::client-conn-message-log conn)))))

  (it "parses-client-options-and-viewport-values"
    (let ((conn (nerimux::%make-client-conn)))
      (expect (= 42 (nerimux::%parse-client-integer "42")))
      (expect (null (nerimux::%parse-client-integer "not-an-integer")))
      (expect (null (nerimux::%parse-client-integer nil)))
      (expect (null (nerimux::%parse-client-key-code nil)))
      (expect (= #x11 (nerimux::%parse-client-key-code "c-q")))
      (setf (nerimux::client-conn-viewport conn) 2)
      (expect (= 5 (nerimux::%move-client-viewport conn 3)))
      (expect (zerop (nerimux::%move-client-viewport conn -99)))
      (expect (zerop (nerimux::%move-client-viewport conn "down")))
      (expect (string= "VALUE"
                       (nerimux::%client-option-value
                        '("--NAME=VALUE") '("--name"))))
      (expect (string= "value"
                       (nerimux::%client-option-value
                        '("--name" "value") '("--name"))))
      (expect (nerimux::%client-boolean-option-p
               '("--CONFIRM") '("--confirm")))
      (expect (= #x02 (nerimux::%parse-client-key-code "control-b")))
      (expect (= #x02 (nerimux::%parse-client-key-code "control b")))
      (expect (= 42 (nerimux::%parse-client-key-code "42")))
      (expect (null (nerimux::%parse-client-key-code "")))
      (expect (nerimux::%client-kill-force-p '("--force")))
      (expect (null (nerimux::%client-kill-force-p '("--FORCE"))))
      (expect (null (nerimux::%client-kill-force-p nil)))))

  (it "clears modal buffers and filter state on explicit transitions"
    (let ((conn (nerimux::%make-client-conn)))
      (setf (nerimux::client-conn-command-buffer conn) "stale")
      (expect (eq :command
                  (nerimux::%transition-client-ui-mode conn :enter-command)))
      (expect (string= "" (nerimux::client-conn-command-buffer conn)))
      (setf (nerimux::client-conn-modal conn) :filter
            (nerimux::client-conn-tree-filter conn) "query")
      (expect (null (nerimux::%transition-client-ui-mode conn :cancel)))
      (expect (null (nerimux::client-conn-tree-filter conn)))
      (setf (nerimux::client-conn-modal conn) :command
            (nerimux::client-conn-command-buffer conn) "stale")
      (expect (null (nerimux::%transition-client-ui-mode conn :enter-normal)))
      (expect (string= "" (nerimux::client-conn-command-buffer conn)))))

  (it "dispatches worktree command entries through the shared command-mode contract"
    (let ((conn (nerimux::%make-client-conn)))
      (let ((nerimux::*clients* (list conn)))
      (dolist (entry '(nerimux::%client-start-worktree-delete
                       nerimux::%client-start-worktree-lock
                       nerimux::%client-start-worktree-unlock))
        (expect (funcall entry conn)))
        (expect (= 3 (length (nerimux::client-conn-message-log conn))))))
    (let ((conn (nerimux::%make-client-conn))
          (worktree (nerimux/workspace-model:make-worktree
                     :id "entry" :path "/tmp/entry" :branch "main")))
      (nerimux::%set-client-selected-tree-object conn worktree)
      (dolist (entry '(nerimux::%client-start-worktree-delete
                       nerimux::%client-start-worktree-lock
                       nerimux::%client-start-worktree-unlock))
        (expect (funcall entry conn)))
      (expect (eq :command (nerimux::client-conn-modal conn)))
      (expect (string= "wt-unlock --confirm"
                       (nerimux::client-conn-command-buffer conn)))))

  (it "reports a missing pane for every directional selection request"
    (let ((session (nerimux/session:make-session :id 1 :name "test"))
          (conn (nerimux::%make-client-conn)))
      (let ((nerimux::*clients* (list conn)))
      (dolist (direction '(:up :down :left :right))
        (expect (nerimux::%client-select-pane-direction
                 session conn direction)))
        (expect (= 4 (length (nerimux::client-conn-message-log conn)))))))

  (it "selects the adjacent pane and marks the session dirty"
    (with-two-pane-v-session (session _window upper lower)
      (let ((conn (nerimux::%make-client-conn))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil))
        (setf (nerimux/pane:pane-window upper) _window
              (nerimux/pane:pane-window lower) _window)
        (setf (nerimux::client-conn-focus conn) upper)
        (expect (nerimux::%client-select-pane-direction
                 session conn :down))
        (expect (eq lower (nerimux::client-conn-focus conn)))
        (expect nerimux::*dirty*))))

  (it "starts worktree creation with an automatic branch for a selected repository"
    (let ((session (nerimux/session:make-session :id 1 :name "test"))
          (conn (nerimux::%make-client-conn))
          (repository (nerimux/workspace-model:make-repository
                       :id "repo" :specification "github.com/team/repo"))
          (arguments nil))
      (with-stubbed-fdefinition
          ((nerimux::%client-selected-repository
             (lambda (connection)
               (declare (ignore connection))
               repository))
           (nerimux::%client-create-worktree-now
             (lambda (selected branch connection current-session)
               (setf arguments (list selected branch connection current-session))))
           (nerimux::%mark-dirty (lambda () t)))
        (expect (nerimux::%client-start-worktree-create session conn))
        (expect (eq repository (first arguments)))
        (expect (uiop:string-prefix-p "wt-" (second arguments)))
        (expect (eq conn (third arguments)))
        (expect (eq session (fourth arguments))))))

  (it "settles asynchronous refreshes when startup fails synchronously"
    (let* ((worktree (nerimux/workspace-model:make-worktree
                      :id "refresh" :path "/tmp/refresh" :branch "main"))
           (dirty-count 0)
           (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal)))
      (with-stubbed-fdefinition
          ((nerimux/vcs:refresh-worktree-commits-async
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "thread unavailable")))
           (nerimux/vcs:refresh-worktree-file-diff-async
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "thread unavailable")))
           (nerimux::%mark-dirty (lambda () (incf dirty-count))))
        (nerimux::%client-start-worktree-commits-refresh worktree)
        (nerimux::%client-start-worktree-file-diff-refresh worktree "README.md")
        (expect (eq :failed
                    (nerimux/workspace-model:worktree-commits-state worktree)))
        (expect (equal (list :failed 0 nil)
                       (gethash (list "refresh" "README.md")
                                nerimux::*workspace-file-diffs*)))
        (expect (= 2 dirty-count)))))

  (it "settles asynchronous refreshes when workers report errors through CPS"
    (let* ((worktree (nerimux/workspace-model:make-worktree
                      :id "callback-refresh" :path "/tmp/callback-refresh"
                      :branch "main"))
           (dirty-count 0)
           (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal)))
      (with-stubbed-fdefinition
          ((nerimux/vcs:refresh-worktree-commits-async
           (lambda (&rest arguments)
               (funcall (getf (cddr arguments) :callback-dispatch)
                        (lambda ()
                          (funcall (getf (cddr arguments) :on-error)
                                   (make-condition 'simple-error
                                                   :format-control "commit worker failed"))))))
           (nerimux/vcs:refresh-worktree-file-diff-async
             (lambda (&rest arguments)
               (funcall (getf (cdddr arguments) :callback-dispatch)
                        (lambda ()
                          (funcall (getf (cdddr arguments) :on-error)
                                   (make-condition 'simple-error
                                                   :format-control "diff worker failed"))))))
           (nerimux::%enqueue-main-thread-callback
             (lambda (thunk) (funcall thunk)))
           (nerimux::%mark-dirty (lambda () (incf dirty-count))))
        (nerimux::%client-start-worktree-commits-refresh worktree)
        (nerimux::%client-start-worktree-file-diff-refresh
         worktree "README.md")
        (expect (= 2 dirty-count))
        (expect (equal (list :failed 0 nil)
                       (gethash (list "callback-refresh" "README.md")
                                nerimux::*workspace-file-diffs*))))))

  (it "stores successful and unsuccessful file diff results from CPS"
    (let* ((worktree (nerimux/workspace-model:make-worktree
                      :id "callback-results" :path "/tmp/callback-results"
                      :branch "main"))
           (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
           (nerimux::*dirty* nil)
           (results (list (list :ready 7 "+added" "-removed")
                          (list :unexpected 0 nil))))
      (with-stubbed-fdefinition
          ((nerimux/vcs:refresh-worktree-file-diff-async
             (lambda (&rest arguments)
               (let ((on-complete (getf (cdddr arguments) :on-complete)))
                 (funcall on-complete (pop results)))))
           (nerimux::%mark-dirty (lambda () (setf nerimux::*dirty* t))))
        (nerimux::%client-start-worktree-file-diff-refresh
         worktree "README.md")
        (nerimux::%client-start-worktree-file-diff-refresh
         worktree "CHANGELOG.md")
        (expect (equal (list :ready 7 (list "+added" "-removed"))
                       (gethash (list "callback-results" "README.md")
                                nerimux::*workspace-file-diffs*)))
        (expect (equal (list :failed 0 nil)
                       (gethash (list "callback-results" "CHANGELOG.md")
                                nerimux::*workspace-file-diffs*)))
        (expect nerimux::*dirty*))))

  )

;;; PR2 tree-navigation redesign (R6.3 pivot): Enter on a repository row dives
;;; straight into its main worktree's shell instead of toggling it
;;; open/closed; h/l collapse/expand the owning repository from any row
;;; level; J/K jump the selection across repository rows only.
(describe "server-dispatch-helper-tree-navigation-suite"

  ;; Enter on a repository row with a live pane already attached to its main
  ;; worktree jumps straight to that pane's shell (view :pane, focus set),
  ;; with no intermediate expand/collapse step. FD 9999 fakes "live" without
  ;; a real PTY (the same technique used elsewhere in this suite, e.g.
  ;; confirm-view-quit-tests.lisp), so %OPEN-CLIENT-WORKTREE-PANE's spawn
  ;; path is never reached.
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

  ;; A repository with no worktrees at all reports it rather than silently
  ;; doing nothing or erroring.
  (it "enter-on-a-repository-row-with-no-worktrees-notifies-instead-of-crashing"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo" :organization organization
              :specification "github.com/team/repo"))
           (conn (nerimux::%make-client-conn))
           ;; %CLIENT-NOTIFY only appends to the message log for a live
           ;; (registered) client -- see %CLIENT-LIVE-P.
           (nerimux::*clients* (list conn)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (setf (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-selected-tree-object conn repository)
      (expect (eq t (nerimux::%focus-selected-client-worktree nil conn)))
      (expect (string= "repository has no worktrees"
                       (first (nerimux::client-conn-message-log conn))))
      ;; No jump happened -- the view is untouched.
      (expect (eq :repolist (nerimux::client-conn-view conn)))))

  ;; Enter on an organization row still toggles its collapse state (unchanged
  ;; from the repository-row pivot above) -- a direct, non-edge-case check
  ;; distinct from the fresh-client regression test above.
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

  ;; Section-based redesign: a worktree row has no expand state of its own
  ;; any more (a later wave adds inline detail) -- h/l on one is a no-op,
  ;; not a jump to its owning repository the way the pre-redesign collapse
  ;; chain used to work.
  (it "h-and-l-are-no-ops-on-a-selected-worktree-row"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organizations organization repository main-worktree))
      (let ((nerimux::*dirty* nil)
            (conn (nerimux::%make-client-conn)))
        (nerimux::%set-client-selected-tree-object conn feature-worktree)
        ;; %SET-CLIENT-SELECTED-TREE-OBJECT itself marks dirty (a selection
        ;; change); reset before the collapse/expand no-ops under test so
        ;; the assertion below is about THEM, not the selection above.
        (setf nerimux::*dirty* nil)
        (expect (null (nerimux::%client-tree-collapse-selected conn)))
        (expect (null (nerimux::%client-tree-expand-selected conn)))
        (expect (eq feature-worktree (nerimux::%client-tree-object conn)))
        (expect (null nerimux::*dirty*)))))

  ;; h/l on a REPOSITORY row toggle its worktree listing under the
  ;; Repositories section (*WORKSPACE-EXPANDED-NODE-IDS*, default-collapsed
  ;; polarity -- the opposite sense from *WORKSPACE-COLLAPSED-NODE-IDS*,
  ;; which every other row's own collapse state uses).
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
        ;; Never touched: absent, i.e. collapsed -- H is a no-op on the
        ;; table's contents but still reports handled.
        (expect (nerimux::%client-tree-collapse-selected conn))
        (expect (null (gethash repo-key nerimux::*workspace-expanded-node-ids*)))
        (expect (nerimux::%client-tree-expand-selected conn))
        (expect (gethash repo-key nerimux::*workspace-expanded-node-ids*))
        (expect (nerimux::%client-tree-collapse-selected conn))
        (expect (null (gethash repo-key nerimux::*workspace-expanded-node-ids*))))))

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
    ;; Organizations no longer appear in the overview tree itself, but the
    ;; collapse/expand handlers still special-case one if a caller selects
    ;; it directly (e.g. picker/command-target resolution) -- unchanged from
    ;; before the section-based redesign.
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
      ;; :tree-filter -> MODAL :filter (contract §5).
      (expect (eq :filter (nerimux::client-conn-modal conn)))))

  (it "tree-relative-selection-empty-workspace"
    (let ((conn (nerimux::%make-client-conn))
          (nerimux/vcs::*workspace-organizations* nil)
          (nerimux::*dirty* nil))
      (expect (null (nerimux::%select-client-tree-relative conn 1)))
      (expect (null nerimux::*dirty*))))

  (it "tree-relative-selection-clamps-backward-movement-without-selection"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organization repository main-worktree feature-worktree))
      (let ((conn (nerimux::%make-client-conn))
            (nerimux/vcs::*workspace-organizations* organizations)
            (nerimux::*dirty* nil))
        (setf (nerimux::client-conn-rows conn) 7)
        ;; Both worktrees in this fixture are clean and pane-less, so the
        ;; only row at all is the Repositories section header.
        (expect (eq :repositories
                    (nerimux::%select-client-tree-relative conn -1)))
        (expect (zerop (nerimux::client-conn-tree-scroll conn))))))

  (it "tree-relative-selection-starts-at-the-first-row-for-forward-movement"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
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

  (it "tree-relative-selection-adjusts-scroll-for-a-narrow-view"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignorable organization main-worktree feature-worktree))
      (let ((conn (nerimux::%make-client-conn))
            (nerimux/vcs::*workspace-organizations* organizations)
            (nerimux::*dirty* nil))
        (setf (nerimux::client-conn-rows conn) 7)
        ;; Row 0 is the Repositories section header; selecting it and moving
        ;; forward lands on REPOSITORY, its own row.
        (nerimux::%set-client-selected-tree-object conn :repositories)
        (expect (eq repository
                    (nerimux::%select-client-tree-relative conn 1)))
        (expect (= 1 (nerimux::client-conn-tree-scroll conn))))))

  ;; J moves the selection to the next :SECTION header row only, skipping
  ;; every worktree/repository row in between.
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
        ;; Rows: (Attention header) worktree-a (Repositories header) repo-a
        ;; -- select worktree-a (dirty, so it is under Attention) first, so
        ;; J has to skip past it and land on the :REPOSITORIES header.
        (nerimux::%set-client-selected-tree-object conn worktree-a)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn 1)))
        (expect (eq :repositories (nerimux::%client-tree-object conn))))))

  ;; FIXED: %SELECT-CLIENT-TREE-SECTION-RELATIVE's LOOP used to step
  ;; `by direction` directly, and CL's LOOP requires a BY step to be a
  ;; positive real -- a SIMPLE-TYPE-ERROR fired the instant DIRECTION was
  ;; negative, so every K press in :overview was broken (verified directly
  ;; against SBCL 2.6.6: `(loop for i from 3 by -1 ...)` errors the same way,
  ;; before the loop body ever runs). The fix always steps a positive
  ;; iteration count and multiplies by DIRECTION to get the index. This test
  ;; pins the required behaviour (K moves backward to the previous section
  ;; header).
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
        ;; Rows: (Attention header) worktree-a (Repositories header) repo-a
        ;; -- select repo-a and expect K to land on the NEAREST preceding
        ;; section header, :REPOSITORIES (repo-a's own section) -- not all
        ;; the way back to :ATTENTION, which is one section further still.
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

  ;; Review-round fix: +MAX-TREE-FILTER-LENGTH+ (256, security review) caps
  ;; CLIENT-CONN-TREE-FILTER's length -- %CLIENT-TREE-FILTER-BUFFER-APPEND
  ;; must refuse further characters outright once the cap is hit, not
  ;; silently truncate (truncating would still accept and discard an
  ;; unbounded payload forever, only quietly); the query's CONTENTS must be
  ;; unchanged by the refused keystroke, not just its length.
  (it "refuses to grow the tree filter past +max-tree-filter-length+"
    (let ((conn (nerimux::%make-client-conn)))
      (setf (nerimux::client-conn-tree-filter conn)
            (make-string nerimux::+max-tree-filter-length+ :initial-element #\a))
      (expect (null (nerimux::%client-tree-filter-buffer-append conn "b")))
      (expect (= nerimux::+max-tree-filter-length+
                 (length (nerimux::client-conn-tree-filter conn))))
      (expect (string= (make-string nerimux::+max-tree-filter-length+ :initial-element #\a)
                       (nerimux::client-conn-tree-filter conn)))
      ;; Below the cap, an ordinary append still works -- this is a hard
      ;; ceiling, not a broken append path.
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
