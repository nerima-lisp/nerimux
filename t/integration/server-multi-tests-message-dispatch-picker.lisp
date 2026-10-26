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
        (progn
          (expect (null (nerimux::%append-client-picker-query-octets conn #(1))))
          (let ((probe (%make-test-conn)))
            (expect (null (nerimux::%append-client-picker-query-octets probe #(#xE2 #x80 #xAE))))))
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
  (it "picker-query-inputs-are-capped-at-200-characters-including-utf8-octets"
    (with-fake-session (s)
      (expect s)
      (let* ((conn (%make-test-conn))
             (query (make-string 205 :initial-element (code-char 120)))
             (utf8-query (make-string 205 :initial-element (code-char #x3042)))
             (utf8-octets (cl-codec-kit:string-to-octets
                           utf8-query :encoding :utf-8)))
        (expect (nerimux::%set-client-picker-query conn ""))
        (expect (nerimux::%append-client-picker-query-octets conn query))
        (expect (= 200 (length (nerimux::client-conn-picker-query conn))))
        (expect (string= (subseq query 0 200)
                         (nerimux::client-conn-picker-query conn)))
        (expect (nerimux::%set-client-picker-query conn query))
        (expect (= 200 (length (nerimux::client-conn-picker-query conn))))
        (expect (string= (subseq query 0 200)
                         (nerimux::client-conn-picker-query conn)))
        (expect (nerimux::%set-client-picker-query conn ""))
        (expect (nerimux::%handle-client-picker-key-payload s conn utf8-octets))
        (expect (= 200 (length (nerimux::client-conn-picker-query conn))))
        (expect (string= (subseq utf8-query 0 200)
                         (nerimux::client-conn-picker-query conn))))))
  (it "attach-selector-query-inputs-are-capped-at-200-characters-and-notifies-on-truncation"
    (with-fake-session (s)
      (expect s)
      (let* ((selector (format nil "github.com/team/~A" (make-string 189 :initial-element (code-char 120))))
             (organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization :specification selector))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt" :repository repository :path selector :branch "main"))
             (conn (%make-test-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (let ((nerimux::*clients* (list conn)))
          (with-stubbed-fdefinition
              ((nerimux/vcs:workspace-organizations
                (lambda () (list organization)))
               (nerimux::%refresh-client-picker
                (lambda (connection &rest arguments)
                  (declare (ignore arguments))
                  connection)))
            (setf (nerimux::client-conn-attach-target conn) selector)
            (expect (null (nerimux::%client-attach-selection
                           conn (list organization))))
            (expect (eq :picker (nerimux::client-conn-modal conn)))
            (expect (= 200 (length (nerimux::client-conn-picker-query conn))))
            (expect (string= (subseq selector 0 200)
                             (nerimux::client-conn-picker-query conn)))
            (expect
             (some (lambda (message)
                     (let ((text (string-downcase message)))
                       (and (search "200" text)
                            (or (search "trunc" text)
                                (search "limit" text)))))
                   (nerimux::client-conn-message-log conn))))))))
  (it "attach-client-selects-an-absolute-linked-worktree-through-dispatch"
  (let* ((root
           (merge-pathnames
            (format nil "nerimux-attach-selector-~D-~D/"
                    (get-universal-time)
                    (sb-posix:getpid))
            (host-kit:temporary-directory)))
         (ghq-root (merge-pathnames "ghq/" root))
         (bare (merge-pathnames "example.test/org/bare-repo/" ghq-root))
         (seed (merge-pathnames "seed/" root))
         (alpha (merge-pathnames ".worktrees/alpha/" bare))
         (target (string-right-trim "/" (namestring alpha)))
         (scan-entered-p nil)
         (scan-released-p nil)
         (entered (sb-thread:make-semaphore :count 0))
         (resume (sb-thread:make-semaphore :count 0))
         (real-ghq-list
           (symbol-function
            (find-symbol "GHQ-LIST-REPOSITORIES" "VCS-KIT"))))
    (flet ((run-git (&rest arguments)
             (uiop:run-program (cons "git" arguments)
                               :output :string
                               :error-output :string))
           (await-catalog-settle ()
             (loop repeat 6000
                   until nerimux::*workspace-catalog-loaded-p*
                   do (nerimux::%drain-main-thread-callbacks)
                      (sleep 0.01))
             (nerimux::%drain-main-thread-callbacks)))
      (unwind-protect
           (progn
             (ensure-directories-exist (merge-pathnames "placeholder" ghq-root))
             (ensure-directories-exist (merge-pathnames "placeholder" seed))
             (run-git "init" "--bare" "--initial-branch=main" (namestring bare))
             (run-git "init" "--initial-branch=main" (namestring seed))
             (run-git "-C" (namestring seed)
                      "-c" "user.name=Test"
                      "-c" "user.email=test@example.invalid"
                      "-c" "commit.gpgsign=false"
                      "-c" "core.hooksPath=/dev/null"
                      "commit" "--allow-empty" "-m" "fixture")
             (run-git "-C" (namestring seed) "push" (namestring bare) "main")
             (run-git "-C" (namestring bare) "worktree" "add"
                      "-b" "feature/alpha" (namestring alpha) "main")
             (with-temporary-posix-environment-variable
                 ("GHQ_ROOT" (namestring ghq-root))
               (with-stubbed-fdefinition
                   ((vcs-kit:ghq-list-repositories
                     (lambda (&rest arguments)
                       (setf scan-entered-p t)
                       (sb-thread:signal-semaphore entered)
                       (unless (sb-thread:wait-on-semaphore resume :timeout 30)
                         (error "Timed out waiting for attach dispatch before ghq scan"))
                       (apply real-ghq-list arguments))))
                 (unwind-protect
                      (progn (nerimux::%drain-main-thread-callbacks)
                        (with-fake-session (session)
                          (with-registered-sessions (("0" session))
                            (let ((nerimux/vcs::*workspace-organizations* nil)
                                  (nerimux/vcs::*ghq-root-cache* :unresolved)
                                  (nerimux::*last-selected-worktree-token* nil)
                                  (nerimux::*workspace-catalog-refresh-started-p* nil)
                                  (nerimux::*workspace-catalog-loaded-p* nil)
                                  (nerimux::*workspace-scan-progress* nil)
                                  (nerimux::*workspace-refreshing-ids*
                                    (make-hash-table :test #'equal))
                                  (nerimux::*workspace-stale-ids*
                                    (make-hash-table :test #'equal))
                                  (nerimux::*workspace-operation-jobs*
                                    (make-hash-table :test #'equal))
                                  (nerimux::*clients* nil))
                              (expect (null (nerimux/vcs:workspace-organizations))
                                      :to-be-truthy)
                              (with-test-listener
                                  (listener path
                                            (%test-socket-path
                                             (format nil "attach-selector-~D"
                                                     (sb-posix:getpid)))
                                            :backlog 4)
                                (let ((client (nerimux/net:connect-to path))
                                      (server-sock nil)
                                      (conn nil))
                                  (unwind-protect
                                       (progn
                                         (expect client :to-be-truthy)
                                         (when client
                                           (setf server-sock
                                                 (nerimux/net:accept-connection
                                                  listener))
                                           (expect server-sock :to-be-truthy)
                                           (when server-sock
                                             (setf conn
                                                   (nerimux::%add-client server-sock))
                                             (expect conn :to-be-truthy)
                                             (when conn
                                               (expect
                                                (sb-thread:wait-on-semaphore
                                                 entered :timeout 30)
                                                :to-be-truthy)
                                               (flet ((dispatch-next-client-frame ()
                                                        (let ((ready
                                                                (nerimux/pty:select-fds
                                                                 (list
                                                                  (nerimux::client-conn-fd
                                                                   conn))
                                                                 1000000)))
                                                          (expect ready :to-be-truthy)
                                                          (when ready
                                                            (nerimux::%read-and-dispatch-client-message
                                                             session conn)))))
                                                 (send-frame
                                                  (nerimux/net:socket-stream client)
                                                  (msg-attach 24 80))
                                                 (force-output
                                                  (nerimux/net:socket-stream client))
                                                 (dispatch-next-client-frame)
                                                 (let ((*default-pathname-defaults* root))
                                                  (nerimux::%send-client-attach-target
                                                   (nerimux/net:socket-stream client)
                                                   target))
                                                 (force-output
                                                  (nerimux/net:socket-stream client))
                                                 (dispatch-next-client-frame)
                                                 (progn
                                                   (expect
                                                    (string=
                                                     target
                                                     (nerimux::client-conn-attach-target
                                                      conn))
                                                    :to-be-truthy)
                                                   (expect
                                                    (null (nerimux/vcs:workspace-organizations))
                                                    :to-be-truthy))
                                                 (expect
                                                  (null
                                                   (nerimux::client-conn-selected-worktree
                                                    conn))
                                                  :to-be-truthy)
                                                 (expect
                                                  (null
                                                   (nerimux::client-conn-modal conn))
                                                  :to-be-truthy)
                                                 (sb-thread:signal-semaphore resume)
                                                 (setf scan-released-p t)
                                                 (%wait-for-test-worker
                                                  (lambda (timeout-seconds)
                                                    (let ((deadline
                                                            (+ (get-internal-real-time)
                                                               (round
                                                                (* timeout-seconds
                                                                   internal-time-units-per-second)))))
                                                      (loop
                                                        (nerimux::%drain-main-thread-callbacks)
                                                        (when nerimux::*workspace-catalog-loaded-p*
                                                          (return t))
                                                        (when (>= (get-internal-real-time)
                                                                  deadline)
                                                          (return nil))
                                                        (sleep 0.01))))
                                                  "real Git workspace catalog")
                                                 (nerimux::%drain-main-thread-callbacks)
                                                 (expect (nerimux/vcs:workspace-organizations)
                                                         :to-be-truthy)
                                                 (let* ((organizations (nerimux/vcs:workspace-organizations))
       (worktree
         (loop for organization in organizations
               thereis
               (loop for repository in
                     (nerimux/workspace-model:organization-repositories organization)
                     thereis
                     (find-if
                      (lambda (candidate)
                        (string= "feature/alpha"
                                 (nerimux/workspace-model:worktree-branch candidate)))
                      (nerimux/workspace-model:repository-worktrees repository))))))
  (expect organizations :to-be-truthy)
  (expect worktree :to-be-truthy)
  (when worktree
    (expect
     (string= (namestring (truename target))
              (namestring
               (truename (nerimux/workspace-model:worktree-path worktree))))
     :to-be-truthy)
    (expect (eq worktree (nerimux::client-conn-selected-worktree conn))
            :to-be-truthy)
    (expect (eq worktree (nerimux::client-conn-selected-tree-object conn))
            :to-be-truthy)
    (multiple-value-bind (type payload)
        (nerimux/protocol::decode-frame
         (progn
           (nerimux::%render-client-frame session conn)
           (nerimux::%render-client-frame session conn)))
      (expect (= nerimux::+msg-frame+ type) :to-be-truthy)
      (let* ((visible
               (strip-sgr (nerimux/protocol::decode-text payload)))
             (alpha-row
               (find-if (lambda (line) (search "feature/alpha" line))
                        (uiop:split-string visible :separator (list #\Newline))))
             (cursor (and alpha-row (search ">" alpha-row)))
             (alpha-label (and alpha-row (search "feature/alpha" alpha-row))))
        (expect alpha-row :to-be-truthy)
        (expect cursor :to-be-truthy)
        (expect alpha-label :to-be-truthy)
        (when (and cursor alpha-label)
          (expect (< cursor alpha-label) :to-be-truthy))))
    (expect (eq worktree (nerimux::client-conn-selected-tree-object conn))
            :to-be-truthy)
    (expect (null (nerimux::client-conn-modal conn)) :to-be-truthy)
    (expect (null (nerimux::client-conn-attach-target conn))
            :to-be-truthy)))))))))
                                    (when (and conn
                                               (member conn nerimux::*clients*))
                                      (nerimux::%drop-client conn))
                                    (dolist (socket
                                             (remove nil (list client server-sock)))
                                      (ignore-errors
                                        (nerimux/net:close-socket socket))))))))))
                   (unless scan-released-p
                     (sb-thread:signal-semaphore resume))
                   (when scan-entered-p
                     (await-catalog-settle))))))
        (when (probe-file root)
          (uiop:delete-directory-tree
           root :validate t :if-does-not-exist :ignore)))))
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

(describe "server-multi-picker-pane-ownership-regression-suite"
  (it "a-stale-pane-row-does-not-focus-a-pane-from-another-worktree"
    (with-fake-session (session :nwindows 2)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "picker-pane-owner-org" :host "example.test" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "picker-pane-owner-repo" :organization organization
                :specification "example.test/team/repo"))
             (alpha
               (nerimux/workspace-model:make-worktree
                :id "picker-pane-owner-alpha" :repository repository
                :path "/tmp/picker-pane-owner/alpha" :branch "feature/alpha"))
             (beta
               (nerimux/workspace-model:make-worktree
                :id "picker-pane-owner-beta" :repository repository
                :path "/tmp/picker-pane-owner/beta" :branch "feature/beta"))
             (windows (nerimux/session:session-windows session))
             (stale-pane
               (nerimux/window:window-active-pane (first windows)))
             (beta-window (second windows))
             (beta-pane (nerimux/window:window-active-pane beta-window))
             (connection (nerimux::%make-client-conn))
             (items nil))
        (nerimux/workspace-model:organization-add-repository
         organization repository)
        (nerimux/workspace-model:repository-add-worktree repository alpha)
        (nerimux/workspace-model:repository-add-worktree repository beta)
        (setf (nerimux/pane:pane-title stale-pane) "stale-shell")
        (nerimux/pane:worktree-add-pane beta stale-pane)
        (setf (nerimux/pane:pane-worktree stale-pane) alpha
              (nerimux/pane:pane-title beta-pane) "beta-shell")
        (nerimux/pane:worktree-add-pane beta beta-pane)
        (setf items
              (nerimux/picker:build-global-picker-items (list organization))
              (nerimux::client-conn-picker-items connection) items
              (nerimux::client-conn-picker-query connection) "stale-shell"
              (nerimux::client-conn-picker-index connection) 0)
        (nerimux::%set-client-modal connection :picker)
        (let ((visible (nerimux::%client-picker-visible-items connection)))
          (expect (= 1 (length visible)))
          (expect (eq beta
                      (nerimux/picker:picker-item-worktree (first visible))))
          (expect (eq stale-pane
                      (nerimux/picker:picker-item-pane (first visible)))))
        (expect (nerimux::%select-client-picker-item session connection))
        (expect (eq beta-pane (nerimux::client-conn-focus connection)))
        (progn
          (expect (eq beta (nerimux::client-conn-selected-worktree connection)))
          (expect (eq beta-pane (nerimux::%worktree-remembered-pane beta))))
        (expect (eq beta-pane
                    (nerimux/window:window-active-pane beta-window))))))
  (it "client-worktree-pane-uses-enter-priority-and-skips-a-dead-remembered-pane"
    (with-fake-session (session :nwindows 2)
      (let* ((windows (nerimux/session:session-windows session))
             (dead-agent (nerimux/window:window-active-pane (first windows)))
             (live-shell (nerimux/window:window-active-pane (second windows)))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "picker-enter-priority" :path "/tmp/picker-enter-priority"))
             (nerimux::*workspace-worktree-last-pane*
               (make-hash-table :test #'equal))
             (dead-pane-live-checks 0)
             (selected nil))
        (setf (nerimux/pane:pane-agent-kind dead-agent) :codex)
        (nerimux/pane:worktree-add-pane worktree live-shell)
        (nerimux/pane:worktree-add-pane worktree dead-agent)
        (nerimux::%remember-worktree-pane worktree dead-agent)
        (with-stubbed-fdefinition
            ((nerimux/pane:pane-live-p
              (lambda (pane)
                (if (eq pane dead-agent)
                    (progn (incf dead-pane-live-checks) nil)
                    t)))
             (nerimux/pane:worktree-running-agent-p
              (lambda (candidate)
                (declare (ignore candidate))
                nil)))
          (setf selected (nerimux::%client-worktree-pane session worktree)))
        (expect (plusp dead-pane-live-checks))
        (expect (eq live-shell selected))))))
