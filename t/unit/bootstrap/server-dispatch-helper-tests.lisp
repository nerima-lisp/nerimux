(in-package #:nerimux/test)

;;;; Pure selection, command, and picker helpers used by the multi-client UI.

(defun %make-server-dispatch-helper-fixture ()
  (let* ((organization
           (nerimux/model:make-organization
            :id "org-id"
            :host "origin"
            :name "team"))
         (repository
           (nerimux/model:make-repository
            :id "repo-id"
            :organization organization
            :specification "origin/team/repo"
            :local-path "/workspace/repo"))
         (main-worktree
           (nerimux/model:make-worktree
            :id "main-id"
            :repository repository
            :path "/workspace/repo"
            :branch "main"))
         (feature-worktree
           (nerimux/model:make-worktree
            :id "feature-id"
            :repository repository
            :path "/workspace/repo/feature"
            :branch "feature")))
    (nerimux/model:organization-add-repository organization repository)
    (nerimux/model:repository-add-worktree repository main-worktree)
    (nerimux/model:repository-add-worktree repository feature-worktree)
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

  (it "tracks-tree-objects-selection-and-scroll"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*dirty* nil)
            (nerimux::*last-selected-worktree-token* nil)
            (nerimux::*workspace-expanded-node-ids*
              (make-hash-table :test #'equal))
            (nerimux/vcs::*workspace-organizations* organizations)
            (conn (nerimux::%make-client-conn)))
        (setf (gethash (list :organization
                             (nerimux/model:organization-id organization))
                       nerimux::*workspace-expanded-node-ids*)
              t
              (gethash (list :repository
                             (nerimux/model:repository-id repository))
                       nerimux::*workspace-expanded-node-ids*)
              t
              (nerimux::client-conn-rows conn) 5)
        (let ((objects (nerimux::%workspace-tree-objects organizations)))
          (expect (= 4 (length objects)))
          (expect (eq organization (first objects)))
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
      (declare (ignore organization main-worktree feature-worktree))
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
        (expect (nerimux::%client-create-worktree
                 conn "repo-id" '("--confirm")))
        (expect (search "worktree create requires a branch"
                        (first (nerimux::client-conn-message-log conn))))
        (expect (eq :input
                    (nerimux::%set-client-ui-mode conn :input)))
        (expect (eq :normal
                    (nerimux::%transition-client-ui-mode conn :cancel)))
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
                     (nerimux::client-conn-workspace-prefix-code conn)))))))
  )

(describe "server-dispatch-helper-edge-suite"

  (it "parses-payloads-and-transitions-client-modes"
    (let ((conn (nerimux::%make-client-conn))
          (nerimux::*dirty* nil))
      (expect (= 65 (nerimux::%client-single-byte (vector 65))))
      (expect (= 65 (nerimux::%client-single-byte "A")))
      (expect (null (nerimux::%client-single-byte (vector 65 66))))
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
      (expect (nerimux::%client-enter-input-mode conn))
      (expect (eq :input (nerimux::client-conn-mode conn)))
      (expect (eq :detail (nerimux::client-conn-view conn)))
      (expect (eq :copy (nerimux::%set-client-ui-mode conn :copy)))
      (expect (eq :normal
                  (nerimux::%transition-client-ui-mode
                   conn :toggle-copy)))
      (expect (eq :copy
                  (nerimux::%transition-client-ui-mode
                   conn :toggle-copy)))
      (expect (eq :copy
                  (nerimux::%transition-client-ui-mode
                   conn :unrecognized-event)))
      (expect (eq :overview (nerimux::%set-client-view conn :overview)))
      (expect (eq :overview (nerimux::%set-client-view conn :invalid)))
      (expect (nerimux::%client-enter-command-mode conn "command"))
      (expect (eq :command (nerimux::client-conn-mode conn)))
      (expect (string= "command"
                       (nerimux::client-conn-command-buffer conn)))
      (expect (eq :overview
                  (nerimux::client-conn-command-return-view conn)))
      (expect (eq :normal
                  (nerimux::%transition-client-ui-mode conn :accept)))
      (expect (string= "" (nerimux::client-conn-command-buffer conn)))
      (expect (null (nerimux::client-conn-command-return-view conn)))
      (expect (nerimux::%client-enter-command-mode conn 42))
      (expect (string= "" (nerimux::client-conn-command-buffer conn)))))

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

  (it "parses-client-options-and-viewport-values"
    (let ((conn (nerimux::%make-client-conn)))
      (expect (= 42 (nerimux::%parse-client-integer "42")))
      (expect (null (nerimux::%parse-client-integer "not-an-integer")))
      (expect (null (nerimux::%parse-client-integer nil)))
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
      (expect (null (nerimux::%client-kill-force-p nil))))))
