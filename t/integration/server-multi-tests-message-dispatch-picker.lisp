(in-package #:nerimux/test)

(describe "server-multi-suite"

  (it "pending-worktree-guards-reject-picker-transitions"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (window (nerimux/session:session-active-window s))
             (pane (nerimux/window:window-active-pane window)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (with-stubbed-fdefinition
            ((nerimux::%reject-pending-worktree-attachment
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 t)))
          (expect (null (nerimux::%open-client-picker conn)))
          (expect (null (nerimux::client-conn-modal conn)))
          (setf (nerimux::client-conn-focus conn) pane
                (nerimux::client-conn-modal conn) :picker
                (nerimux::client-conn-view conn) :pane)
          (expect (null (nerimux::%close-client-picker conn s)))
          (expect (eq :picker (nerimux::client-conn-modal conn)))
          (expect (eq :pane (nerimux::client-conn-view conn)))
          (expect (null (nerimux::%open-client-worktree-pane s conn nil)))
          (expect (eq :picker (nerimux::client-conn-modal conn)))))))

  (it "closing-the-picker-keeps-the-view-it-was-opened-over"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (window (nerimux/session:session-active-window s))
             (pane (nerimux/window:window-active-pane window)))
        (setf (nerimux::client-conn-focus conn) pane)
        (dolist (view '(:repolist :status))
          (setf (nerimux::client-conn-view conn) view
                (nerimux::client-conn-modal conn) :picker)
          (expect (nerimux::%close-client-picker conn s))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (eq view (nerimux::client-conn-view conn)))))))
  (it "prefix-c-p-cancels-to-original-pane-without-shell-input"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (window (nerimux/session:session-active-window s))
             (pane (nerimux/window:window-active-pane window))
             (input-payloads nil)
             (nerimux::*dirty* nil))
        (setf (nerimux::client-conn-focus conn) pane
              (nerimux::client-conn-view conn) :pane)
        (with-stubbed-fdefinition
            ((nerimux/vcs:workspace-organizations (lambda () nil))
             (nerimux::%refresh-client-picker
              (lambda (connection &rest arguments)
                (declare (ignore arguments))
                connection))
             (nerimux::%handle-client-input-key-payload
              (lambda (session connection payload)
                (declare (ignore session connection))
                (push payload input-payloads))))
          (nerimux::%handle-multi-key-message s conn #(17))
          (nerimux::%handle-multi-key-message s conn #(16))
          (expect (eq :picker (nerimux::client-conn-modal conn)))
          (expect
           (equal (list (nerimux/window:window-id window)
                        (nerimux/pane:pane-id pane))
                  (getf (gethash conn nerimux::*client-picker-return-targets*)
                        :pane-key)))
          (expect (eq pane (nerimux::client-conn-focus conn)))
          (expect (eq window (nerimux/session:session-active-window s)))
          (expect (eq pane (nerimux/window:window-active-pane window)))
          (expect (nerimux::%handle-multi-key-message s conn #(120)))
          (expect (string= "x" (nerimux::client-conn-picker-query conn)))
          (expect (null input-payloads))
          (nerimux::%handle-multi-key-message s conn #(27))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (eq :pane (nerimux::client-conn-view conn)))
          (expect (eq pane (nerimux::client-conn-focus conn)))
          (expect (eq window (nerimux/session:session-active-window s)))
          (expect (eq pane (nerimux/window:window-active-pane window)))
          (expect (null input-payloads))))))
  (it "prefix-c-p-cancel-falls-back-when-origin-pane-closed"
    (with-fake-session (s :npanes 2)
      (let* ((conn (%make-test-conn))
             (window (nerimux/session:session-active-window s))
             (origin-pane (first (nerimux/window:window-panes window)))
             (fallback-pane (second (nerimux/window:window-panes window)))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-focus conn) origin-pane
              (nerimux::client-conn-view conn) :pane)
        (with-stubbed-fdefinition
            ((nerimux/vcs:workspace-organizations (lambda () nil))
             (nerimux::%refresh-client-picker
              (lambda (connection &rest arguments)
                (declare (ignore arguments))
                connection)))
          (nerimux::%handle-multi-key-message s conn #(17))
          (nerimux::%handle-multi-key-message s conn #(16))
          (expect (eq :picker (nerimux::client-conn-modal conn)))
          (expect (eq fallback-pane
                      (nerimux/window:window-remove-pane window origin-pane)))
          (expect (null (nerimux/pane:pane-window origin-pane)))
          (expect (eq origin-pane (nerimux::client-conn-focus conn)))
          (nerimux::%handle-multi-key-message s conn #(27))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (eq :pane (nerimux::client-conn-view conn)))
          (expect (eq fallback-pane (nerimux::client-conn-focus conn)))
          (expect (not (eq origin-pane (nerimux::client-conn-focus conn))))
          (expect (search "picker return pane is no longer available"
                          (first (nerimux::client-conn-message-log conn))))))))
  (it "picker-cancel-ui-commands-fall-back-when-origin-pane-is-closed"
    (dolist (command '(:picker-cancel :cancel))
      (with-fake-session (s :npanes 2)
        (let* ((conn (%make-test-conn))
               (window (nerimux/session:session-active-window s))
               (origin-pane (first (nerimux/window:window-panes window)))
               (fallback-pane (second (nerimux/window:window-panes window)))
               (nerimux::*clients* (list conn))
               (nerimux::*dirty* nil))
          (setf (nerimux::client-conn-focus conn) origin-pane
                (nerimux::client-conn-view conn) :pane)
          (with-stubbed-fdefinition
              ((nerimux/vcs:workspace-organizations (lambda () nil))
               (nerimux::%refresh-client-picker
                (lambda (connection &rest arguments)
                  (declare (ignore arguments))
                  connection)))
            (expect (nerimux::%open-client-picker conn))
            (expect (eq fallback-pane
                        (nerimux/window:window-remove-pane window origin-pane)))
            (expect (null (nerimux/pane:pane-window origin-pane)))
            (expect (eq origin-pane (nerimux::client-conn-focus conn)))
            (expect
             (nerimux::%handle-client-ui-command s conn command nil nil))
            (expect (null (nerimux::client-conn-modal conn)))
            (expect (eq :pane (nerimux::client-conn-view conn)))
            (expect (eq fallback-pane (nerimux::client-conn-focus conn)))
            (expect
             (search "picker return pane is no longer available"
                     (first (nerimux::client-conn-message-log conn)))))))))

  (it "picker-refresh-settles-stale-on-synchronous-error"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (reported nil)
            (nerimux::*clients* nil)
            (nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* 9)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* nil))
        (setf nerimux::*clients* (list conn))
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () t))
             (nerimux::%workspace-refresh-organizations-async
              (lambda (&rest arguments)
                (declare (ignore arguments))
                (error "sync picker refresh failure"))))
          (nerimux::%refresh-client-picker
           conn :on-error (lambda (condition)
                            (setf reported condition)))
          (expect (typep reported 'error))
          (expect nerimux::*workspace-catalog-loaded-p*)
          (expect (null nerimux::*workspace-scan-progress*))
          (expect nerimux::*dirty*)))))

  (it "picker-arrow-key-bytes-one-at-a-time-do-not-move-the-index"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree-a
               (nerimux/workspace-model:make-worktree
                :id "a" :repository repository :path "/tmp/a" :branch "a"))
             (worktree-b
               (nerimux/workspace-model:make-worktree
                :id "b" :repository repository :path "/tmp/b" :branch "b"))
             (conn (%make-test-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree-a)
        (nerimux/workspace-model:repository-add-worktree repository worktree-b)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (expect (< 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(91))
        (nerimux::%handle-multi-key-message s conn #(66))
        (expect (null (nerimux::client-conn-modal conn))
                ))))

  (it "multi-picker-c-p-c-n-move-the-selection"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree-a
               (nerimux/workspace-model:make-worktree
                :id "a" :repository repository :path "/tmp/a" :branch "a"))
             (worktree-b
               (nerimux/workspace-model:make-worktree
                :id "b" :repository repository :path "/tmp/b" :branch "b"))
             (conn (%make-test-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree-a)
        (nerimux/workspace-model:repository-add-worktree repository worktree-b)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (expect (< 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(14))
        (expect (= 1 (nerimux::client-conn-picker-index conn)))
        (expect (eq :picker (nerimux::client-conn-modal conn))
                )
        (nerimux::%handle-multi-key-message s conn #(16))
        (expect (= 0 (nerimux::client-conn-picker-index conn)))
        (expect (string= "" (nerimux::client-conn-picker-query conn))
                ))))

  (it "multi-picker-selects-a-worktree-pane-in-an-inactive-window"
    (with-fake-session (s :nwindows 2)
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
                :branch "feature/inactive"))
             (conn (%make-test-conn))
             (inactive-window (second (nerimux/session:session-windows s)))
             (pane (nerimux/window:window-active-pane inactive-window)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux/pane:worktree-add-pane worktree pane)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-query conn) "feature")
        (expect (nerimux::%select-client-picker-item s conn))
        (expect (eq inactive-window
                    (nerimux/session:session-active-window s)))
        (expect (eq pane (nerimux::client-conn-focus conn)))
        (expect (null (nerimux::client-conn-modal conn))))))
  (it "prefix-c-p-enter-opens-selected-pane-in-another-window"
    (with-fake-session (s :nwindows 2)
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
                :path "/tmp/feature" :branch "feature/inactive"))
             (conn (%make-test-conn))
             (origin-window (first (nerimux/session:session-windows s)))
             (target-window (second (nerimux/session:session-windows s)))
             (origin-pane (nerimux/window:window-active-pane origin-window))
             (target-pane (nerimux/window:window-active-pane target-window)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux/pane:worktree-add-pane worktree target-pane)
        (setf (nerimux/pane:pane-title target-pane) "picker-target"
              (nerimux::client-conn-focus conn) origin-pane
              (nerimux::client-conn-view conn) :pane)
        (with-stubbed-fdefinition
            ((nerimux/vcs:workspace-organizations
              (lambda () (list organization)))
             (nerimux::%refresh-client-picker
              (lambda (connection &rest arguments)
                (declare (ignore arguments))
                connection)))
          (nerimux::%handle-multi-key-message s conn #(17))
          (nerimux::%handle-multi-key-message s conn #(16))
          (expect (eq :picker (nerimux::client-conn-modal conn)))
          (expect (eq origin-pane (nerimux::client-conn-focus conn)))
          (expect (eq origin-window
                      (nerimux/session:session-active-window s)))
          (expect (nerimux::%set-client-picker-query conn "picker-target"))
          (let ((items (nerimux::%client-picker-visible-items conn)))
            (expect (= 1 (length items)))
            (expect (eq :pane (nerimux/picker:picker-item-kind (first items))))
            (expect (eq target-pane
                        (nerimux/picker:picker-item-pane (first items)))))
          (nerimux::%handle-multi-key-message s conn #(13))
          (expect (eq target-window
                      (nerimux/session:session-active-window s)))
          (expect (eq target-pane
                      (nerimux/window:window-active-pane target-window)))
          (expect (eq target-pane (nerimux::client-conn-focus conn)))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (eq :pane (nerimux::client-conn-view conn)))))))

  (it "multi-picker-new-window-uses-client-geometry"
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
                :branch "feature/new"))
             (conn (%make-test-conn :rows 17 :cols 63))
             (captured-geometry nil)
             (original-new-window (fdefinition 'nerimux::%workspace-new-window)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-query conn) "feature")
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux::%workspace-new-window)
                     (lambda (session &rest args)
                       (declare (ignore args))
                       (setf captured-geometry
                             (list nerimux::*term-rows* nerimux::*term-cols*))
                       (nerimux/session:session-active-window session)))
               (expect (nerimux::%select-client-picker-item s conn))
               (expect (equal '(17 63) captured-geometry)))
          (setf (fdefinition 'nerimux::%workspace-new-window)
                original-new-window)))))

  (it "picker-query-helpers-reject-invalid-input-and-wrap-selection"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null (nerimux::%set-client-picker-query conn 42)))
        (expect (null (nerimux::%append-client-picker-query-octets
                       conn #(194 32))))
        (expect (null (nerimux::%append-client-picker-query-octets
                       conn 42)))
        (expect (null (nerimux::%append-client-picker-query-octets
                       conn #(1))))
        (expect (null (nerimux::%delete-client-picker-query-character conn)))
        (setf (nerimux::client-conn-picker-items conn) nil
              (nerimux::client-conn-picker-index conn) 9)
        (expect (null (nerimux::%move-client-picker-index conn 1)))
        (expect (= 0 (nerimux::client-conn-picker-index conn))))))

  (it "picker-query-helpers-normalize-input-and-handle-control-keys"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (nerimux::%set-client-picker-regex conn :on t))
        (expect (nerimux::%set-client-picker-regex conn "invalid" t))
        (expect (null (nerimux::%set-client-picker-regex conn :off t)))
        (expect (null (nerimux::%set-client-picker-regex conn "invalid" t)))
        (expect (nerimux::%set-client-picker-query conn "ab"))
        (expect (nerimux::%append-client-picker-query-octets conn "c"))
        (expect (string= "abc" (nerimux::client-conn-picker-query conn)))
        (expect (nerimux::%delete-client-picker-query-character conn))
        (expect (string= "ab" (nerimux::client-conn-picker-query conn)))
        (expect (nerimux::%handle-client-picker-key-payload s conn #(18)))
        (expect (null (nerimux::%handle-client-picker-key-payload s conn #(16))))
        (expect (null (nerimux::%handle-client-picker-key-payload s conn #(14))))
        (expect (nerimux::%handle-client-picker-key-payload s conn #(127))))))
  (it "picker-query-inputs-are-capped-at-200-characters"
    (with-fake-session (s)
      (declare (ignore s))
      (let* ((conn (%make-test-conn))
             (query (make-string 205 :initial-element #\x)))
        (expect (nerimux::%set-client-picker-query conn ""))
        (expect (nerimux::%append-client-picker-query-octets conn query))
        (expect (= 200 (length (nerimux::client-conn-picker-query conn))))
        (expect (string= (subseq query 0 200)
                        (nerimux::client-conn-picker-query conn)))
        (expect (nerimux::%set-client-picker-query conn query))
        (expect (= 200 (length (nerimux::client-conn-picker-query conn))))
        (expect (string= (subseq query 0 200)
                        (nerimux::client-conn-picker-query conn))))))
  (it "picker-close-requires-session"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (signals program-error
                  (funcall (symbol-function (quote nerimux::%close-client-picker))
                           conn)))
        (expect (nerimux::%close-client-picker conn s)))))

  (it "picker-visible-items-deduplicate-worktrees-and-clamp-selection"
    (with-fake-session (s)
      (let* ((worktree (nerimux/workspace-model:make-worktree :id "shared" :path "/tmp/shared"))
             (first-item (nerimux/picker:make-picker-item
                          :id "first" :kind :worktree :label "first"
                          :worktree worktree))
             (duplicate-item (nerimux/picker:make-picker-item
                              :id "duplicate" :kind :worktree :label "duplicate"
                              :worktree worktree))
             (organization-item (nerimux/picker:make-picker-item
                                 :id "organization" :kind :organization
                                 :label "organization"))
             (conn (%make-test-conn)))
        (setf (nerimux::client-conn-picker-items conn)
              (list first-item duplicate-item organization-item)
              (nerimux::client-conn-picker-index conn) 99)
        (let ((visible (nerimux::%client-picker-visible-items conn)))
          (expect (= 2 (length visible)))
          (expect (eq first-item (first visible)))
          (expect (eq organization-item (second visible)))
          (expect (= 1 (nerimux::client-conn-picker-index conn))))
        (setf (nerimux::client-conn-picker-index conn) -4)
        (nerimux::%client-picker-visible-items conn)
        (expect (= 0 (nerimux::client-conn-picker-index conn)))
        (setf (nerimux::client-conn-picker-items conn) nil)
        (nerimux::%client-picker-visible-items conn)
        (expect (= 0 (nerimux::client-conn-picker-index conn))))))

  (it "picker-selected-item-returns-the-current-visible-item"
    (with-fake-session (s)
      (let* ((first-item (nerimux/picker:make-picker-item
                          :id "first" :kind :repository :label "first"))
             (second-item (nerimux/picker:make-picker-item
                           :id "second" :kind :repository :label "second"))
             (conn (%make-test-conn)))
        (setf (nerimux::client-conn-picker-items conn)
              (list first-item second-item)
              (nerimux::client-conn-picker-index conn) 1)
        (expect (eq second-item (nerimux::%picker-selected-item conn)))
        (setf (nerimux::client-conn-picker-items conn) nil)
        (expect (null (nerimux::%picker-selected-item conn))))))

  (it "picker-selects-repository-and-organization-without-opening-a-pane"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (main-worktree
               (nerimux/workspace-model:make-worktree
                :id "main" :path "/tmp/repo" :branch "main"))
             (conn (%make-test-conn))
             (nerimux::*workspace-expanded-node-ids*
               (make-hash-table :test #'equal))
             (nerimux::*workspace-collapsed-node-ids*
               (make-hash-table :test #'equal)))
        (nerimux/workspace-model:organization-add-repository organization
                                                             repository)
        (nerimux/workspace-model:repository-add-worktree repository
                                                         main-worktree)
        (setf (gethash (list :organization "org")
                       nerimux::*workspace-collapsed-node-ids*)
              t)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (list (nerimux/picker:make-picker-item
                     :id "repo" :kind :repository :label "repo"
                     :repository repository))
              (nerimux::client-conn-picker-index conn) 0)
        (expect (nerimux::%select-client-picker-item s conn))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (null (nerimux::client-conn-focus conn)))
        (expect (eq main-worktree
                    (nerimux::client-conn-selected-tree-object conn)))
        (expect (gethash (list :repository "repo")
                         nerimux::*workspace-expanded-node-ids*))
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (list (nerimux/picker:make-picker-item
                     :id "org" :kind :organization :label "team"
                     :organization organization))
              (nerimux::client-conn-picker-index conn) 0)
        (expect (nerimux::%select-client-picker-item s conn))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (null (nerimux::client-conn-focus conn)))
        (expect (eq organization
                    (nerimux::client-conn-selected-tree-object conn)))
        (expect (null (gethash (list :organization "org")
                               nerimux::*workspace-collapsed-node-ids*)))
        (setf (nerimux::client-conn-picker-items conn) nil)
        (expect (null (nerimux::%select-client-picker-item s conn))))))


)
