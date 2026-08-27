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
            ;; PR2 polarity inversion: absent from *WORKSPACE-COLLAPSED-NODE-
            ;; IDS* means expanded now, so an empty (freshly bound, for test
            ;; isolation) table already shows the whole 4-row tree below --
            ;; nothing needs to be marked to reveal it, unlike the pre-PR2
            ;; *WORKSPACE-EXPANDED-NODE-IDS* this replaces.
            (nerimux::*workspace-collapsed-node-ids*
              (make-hash-table :test #'equal))
            (nerimux/vcs::*workspace-organizations* organizations)
            (conn (nerimux::%make-client-conn)))
        (setf (nerimux::client-conn-rows conn) 5)
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

  ;; F9 regression: a freshly attached client has NO selection at all --
  ;; %client-tree-object returns nil (no selected-tree-object, no
  ;; selected-worktree, no focus pane). The FIRST Enter used to bind OBJECT to
  ;; that nil before dispatching, miss every typep clause, and fall into the
  ;; catch-all worktree branch -- which selected row 0 as a side effect but
  ;; then read a still-nil client-conn-selected-worktree and reported "no
  ;; worktree selected", even though row 0 was a perfectly good organization
  ;; that should have expanded. Only the SECOND Enter worked, because the
  ;; first one's fallback had, by then, set up state for it.
  (it "first-enter-on-a-fresh-client-toggles-the-default-row-not-a-nil-selection"
    (let* ((organization
             (nerimux/model:make-organization
              :id "org" :host "github.com" :name "team"))
           (conn (nerimux::%make-client-conn))
           (nerimux/vcs::*workspace-organizations* (list organization))
           ;; PR2 polarity inversion: the org row starts EXPANDED (absent from
           ;; this table), so the first Enter's toggle must COLLAPSE it --
           ;; the opposite direction from the pre-PR2 *WORKSPACE-EXPANDED-
           ;; NODE-IDS* this replaces.
           (nerimux::*workspace-collapsed-node-ids*
             (make-hash-table :test #'equal))
           (nerimux::*clients* (list conn))
           (nerimux::*dirty* nil))
      (setf (nerimux::client-conn-view conn) :overview)
      ;; Fresh conn: nothing selected, nothing focused.
      (expect (null (nerimux::%client-tree-object conn)))
      (expect (nerimux::%focus-selected-client-worktree nil conn))
      ;; The organization row (the only row, expanded by default) must have
      ;; toggled to collapsed ...
      (expect (gethash (list :organization "org")
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

;;; PR2 tree-navigation redesign (R6.3 pivot): Enter on a repository row dives
;;; straight into its main worktree's shell instead of toggling it
;;; open/closed; h/l collapse/expand the owning repository from any row
;;; level; J/K jump the selection across repository rows only.

(describe "server-dispatch-helper-tree-navigation-suite"

  ;; Enter on a repository row with a live pane already attached to its main
  ;; worktree jumps straight to that pane's shell (view :detail, focus set),
  ;; with no intermediate expand/collapse step. FD 9999 fakes "live" without
  ;; a real PTY (the same technique used elsewhere in this suite, e.g.
  ;; confirm-view-quit-tests.lisp), so %OPEN-CLIENT-WORKTREE-PANE's spawn
  ;; path is never reached.
  (it "enter-on-a-repository-row-with-a-main-worktree-jumps-straight-to-its-shell"
    (with-fake-session (s)
      (let* ((pane (nerimux/model:window-active-pane
                    (nerimux/model:session-active-window s)))
             (organization
               (nerimux/model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/model:make-worktree
                :id "main" :repository repository :path "/tmp/main" :branch "main"))
             (conn (nerimux::%make-client-conn)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (nerimux/model:worktree-add-pane worktree pane)
        (setf (nerimux/model:pane-fd pane) 9999) ; "live" without a real PTY
        (setf (nerimux::client-conn-view conn) :overview)
        (nerimux::%set-client-selected-tree-object conn repository)
        (expect (nerimux::%focus-selected-client-worktree s conn))
        (expect (eq :detail (nerimux::client-conn-view conn)))
        (expect (eq pane (nerimux::client-conn-focus conn))))))

  ;; A repository with no worktrees at all reports it rather than silently
  ;; doing nothing or erroring.
  (it "enter-on-a-repository-row-with-no-worktrees-notifies-instead-of-crashing"
    (let* ((organization
             (nerimux/model:make-organization
              :id "org" :host "github.com" :name "team"))
           (repository
             (nerimux/model:make-repository
              :id "repo" :organization organization
              :specification "github.com/team/repo"))
           (conn (nerimux::%make-client-conn))
           ;; %CLIENT-NOTIFY only appends to the message log for a live
           ;; (registered) client -- see %CLIENT-LIVE-P.
           (nerimux::*clients* (list conn)))
      (nerimux/model:organization-add-repository organization repository)
      (setf (nerimux::client-conn-view conn) :overview)
      (nerimux::%set-client-selected-tree-object conn repository)
      (expect (eq t (nerimux::%focus-selected-client-worktree nil conn)))
      (expect (string= "repository has no worktrees"
                       (first (nerimux::client-conn-message-log conn))))
      ;; No jump happened -- the view is untouched.
      (expect (eq :overview (nerimux::client-conn-view conn)))))

  ;; Enter on an organization row still toggles its collapse state (unchanged
  ;; from the repository-row pivot above) -- a direct, non-edge-case check
  ;; distinct from the fresh-client regression test above.
  (it "enter-on-an-organization-row-toggles-its-collapse-state"
    (let* ((organization
             (nerimux/model:make-organization
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

  ;; h on a worktree row collapses its OWNING repository (worktree rows carry
  ;; no collapse state of their own) and moves the selection up to that
  ;; repository, so the cursor is never left on a row the collapse itself
  ;; just hid. l then expands it again.
  (it "h-collapses-the-owning-repository-and-l-expands-it-again"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore organizations organization main-worktree))
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (conn (nerimux::%make-client-conn))
            (repo-key (list :repository (nerimux/model:repository-id repository))))
        (nerimux::%set-client-selected-tree-object conn feature-worktree)
        (expect (nerimux::%client-tree-collapse-selected conn))
        (expect (gethash repo-key nerimux::*workspace-collapsed-node-ids*))
        (expect (eq repository (nerimux::%client-tree-object conn)))
        (expect (nerimux::%client-tree-expand-selected conn))
        (expect (null (gethash repo-key nerimux::*workspace-collapsed-node-ids*))))))

  ;; J moves the selection to the next REPOSITORY row only, skipping the
  ;; worktree rows in between.
  (it "J-jumps-the-selection-forward-to-the-next-repository-row"
    (let* ((organization
             (nerimux/model:make-organization
              :id "org-jk" :host "github.com" :name "team"))
           (repo-a
             (nerimux/model:make-repository
              :id "repo-a" :organization organization
              :specification "github.com/team/repo-a"))
           (repo-b
             (nerimux/model:make-repository
              :id "repo-b" :organization organization
              :specification "github.com/team/repo-b"))
           (worktree-a
             (nerimux/model:make-worktree
              :id "wt-a" :repository repo-a :path "/tmp/a" :branch "a"))
           (worktree-b
             (nerimux/model:make-worktree
              :id "wt-b" :repository repo-b :path "/tmp/b" :branch "b"))
           (conn (nerimux::%make-client-conn)))
      (nerimux/model:organization-add-repository organization repo-a)
      (nerimux/model:organization-add-repository organization repo-b)
      (nerimux/model:repository-add-worktree repo-a worktree-a)
      (nerimux/model:repository-add-worktree repo-b worktree-b)
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* (list organization)))
        ;; ORGANIZATION-ADD-REPOSITORY pushnew-prepends, so the display order
        ;; is org, repo-b, worktree-b, repo-a, worktree-a -- select worktree-b
        ;; first, so J has to skip past it to land on repo-a.
        (nerimux::%set-client-selected-tree-object conn worktree-b)
        (expect (eq repo-a (nerimux::%select-client-tree-repository-relative conn 1)))
        (expect (eq repo-a (nerimux::%client-tree-object conn))))))

  ;; FIXED: %SELECT-CLIENT-TREE-REPOSITORY-RELATIVE's LOOP used to step
  ;; `by direction` directly, and CL's LOOP requires a BY step to be a
  ;; positive real -- a SIMPLE-TYPE-ERROR fired the instant DIRECTION was
  ;; negative, so every K press in :overview was broken (verified directly
  ;; against SBCL 2.6.6: `(loop for i from 3 by -1 ...)` errors the same way,
  ;; before the loop body ever runs). The fix always steps a positive
  ;; iteration count and multiplies by DIRECTION to get the index. This test
  ;; pins the required behaviour (K moves backward to the previous
  ;; repository row).
  (it "K-jumps-the-selection-backward-to-the-previous-repository-row"
    (let* ((organization
             (nerimux/model:make-organization
              :id "org-jk-back" :host "github.com" :name "team"))
           (repo-a
             (nerimux/model:make-repository
              :id "repo-a-back" :organization organization
              :specification "github.com/team/repo-a-back"))
           (repo-b
             (nerimux/model:make-repository
              :id "repo-b-back" :organization organization
              :specification "github.com/team/repo-b-back"))
           (worktree-a
             (nerimux/model:make-worktree
              :id "wt-a-back" :repository repo-a :path "/tmp/a-back" :branch "a"))
           (worktree-b
             (nerimux/model:make-worktree
              :id "wt-b-back" :repository repo-b :path "/tmp/b-back" :branch "b"))
           (conn (nerimux::%make-client-conn)))
      (nerimux/model:organization-add-repository organization repo-a)
      (nerimux/model:organization-add-repository organization repo-b)
      (nerimux/model:repository-add-worktree repo-a worktree-a)
      (nerimux/model:repository-add-worktree repo-b worktree-b)
      (let ((nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* (list organization)))
        ;; Display order: org, repo-b, worktree-b, repo-a, worktree-a --
        ;; select repo-a and expect K to land back on repo-b.
        (nerimux::%set-client-selected-tree-object conn repo-a)
        (expect (eq repo-b (nerimux::%select-client-tree-repository-relative conn -1)))
        (expect (eq repo-b (nerimux::%client-tree-object conn))))))

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
