(in-package #:nerimux/test)

(defmacro %with-r5-fixture ((session-var conn-var worktree-var window-var) &body body)
  "Stub %fork-pane and start-reader-thread, bind PTY resize and close ports to
   no-ops,
   build one organization/repository/worktree, open the worktree's first pane
   via the real overview terminal command, and bind SESSION-VAR/CONN-VAR/
   WORKTREE-VAR/WINDOW-VAR for BODY."
  `(with-loop-state
     (let ((nerimux/ports:*resize-pty* (lambda (fd rows cols)
                                         (declare (ignore fd rows cols))
                                         nil))
           (nerimux/ports:*close-pty* (lambda (fd pid)
                                        (declare (ignore fd pid))
                                        nil)))
       (with-stubbed-fdefinition
           ((nerimux/pane::%fork-pane
             (lambda (session id x y cols rows &key start-dir default-command)
               (declare (ignore session default-command))
               (let ((pane (make-no-pty-pane id x y cols rows)))
                 (setf (nerimux/pane:pane-fd pane) 9999
                       (nerimux/pane:pane-start-path pane) (or start-dir ""))
                 pane)))
            (nerimux::start-reader-thread
             (lambda (pane) (declare (ignore pane)) nil)))
       (let* ((organization
                (nerimux/workspace-model:make-organization
                 :id "org" :host "github.com" :name "team"))
              (repository
                (nerimux/workspace-model:make-repository
                 :id "repo" :organization organization
                 :specification "github.com/team/repo"))
              (,worktree-var
                (nerimux/workspace-model:make-worktree
                 :id "wt" :repository repository
                 :path "/tmp/nerimux-r5-wt" :branch "feat/phase3"))
              (,session-var (nerimux/session:make-session :id 1 :name "0" :windows nil))
              (,conn-var (%make-test-conn :rows 200 :cols 200))
              (nerimux::*clients* (list ,conn-var)))
         (nerimux/workspace-model:organization-add-repository organization repository)
         (nerimux/workspace-model:repository-add-worktree repository ,worktree-var)
         (setf (nerimux::client-conn-view ,conn-var) :repolist)
         (nerimux::%set-client-selected-tree-object ,conn-var ,worktree-var)
         (nerimux::%handle-multi-key-message ,session-var ,conn-var #(116))
         (let ((,window-var (nerimux/session:session-active-window ,session-var)))
           ,@body))))))

(defmacro %with-assignment-fixture (&body body)
  `(with-loop-state
     (let* ((repository (nerimux/workspace-model:make-repository
                         :id "assignment-repo" :local-path "/tmp/assignment.git/"))
            (worktree (nerimux/workspace-model:make-worktree
                       :id "assignment-wt" :repository repository
                       :path "/tmp/assignment.git/.worktrees/new" :head "abc123"))
            (session (nerimux/session:make-session :id 1 :name "test" :windows nil))
            (conn (%make-test-conn :rows 200 :cols 200))
            (nerimux::*clients* (list conn))
            (nerimux::*workspace-cancel-reservations* (make-hash-table :test #'equal))
            (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
            (receipt (nerimux/vcs::%make-detached-worktree-result
                      :path (nerimux/workspace-model:worktree-path worktree)
                      :head "abc123" :worktree worktree)))
       (declare (ignorable receipt))
       (nerimux/workspace-model:repository-add-worktree repository worktree)
       (nerimux::%set-client-selected-tree-object conn worktree)
       (setf (nerimux::client-conn-view conn) :repolist)
       (with-stubbed-fdefinition
           ((nerimux::%workspace-find-repository
             (lambda (&rest args) (declare (ignore args)) repository)))
         ,@body))))

(describe "worktree assignment acceptance"
  (it "opens assignment on Enter without spawning and cancels existing rows without deletion"
    (%with-assignment-fixture
      (let ((spawns 0) (deletes 0))
        (with-stubbed-fdefinition
            ((nerimux/pane::%fork-pane
              (lambda (&rest args) (declare (ignore args)) (incf spawns)))
             (nerimux/vcs:delete-worktree-async
              (lambda (&rest args) (declare (ignore args)) (incf deletes))))
          (nerimux::%handle-multi-key-message session conn #(13))
          (expect (eq :transient (nerimux::client-conn-modal conn)))
          (expect (eq :assigning (nerimux::workspace-assignment-phase
                                 (nerimux::client-conn-workspace-assignment conn))))
          (nerimux::%handle-multi-key-message session conn #(27))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (= 0 spawns deletes))))))
  (it "uses n for detached creation and a for an existing workspace"
    (%with-assignment-fixture
      (let ((created 0) (selected nil))
        (with-stubbed-fdefinition
            ((nerimux/vcs:create-detached-worktree-async
              (lambda (repo &key on-complete &allow-other-keys)
                (setf selected repo) (incf created) (funcall on-complete receipt))))
          (nerimux::%handle-multi-key-message session conn #(110))
          (expect (= 1 created))
          (expect (eq repository selected))
          (expect (eq receipt (nerimux::workspace-assignment-receipt
                               (nerimux::client-conn-workspace-assignment conn))))
          (nerimux::%close-client-transient conn)
          (setf (nerimux::workspace-assignment-phase
                 (nerimux::client-conn-workspace-assignment conn)) :done)
          (nerimux::%handle-multi-key-message session conn #(97))
          (expect (= 1 created))
          (expect (null (nerimux::workspace-assignment-receipt
                         (nerimux::client-conn-workspace-assignment conn))))))))
  (it "retains receipts after disconnect, stale completion, and refresh failure"
    (dolist (mode '(:disconnect :stale :refresh-error :missing-worktree))
      (%with-assignment-fixture
        (let ((complete nil) (deletes 0))
          (with-stubbed-fdefinition
            ((nerimux/vcs:create-detached-worktree-async
              (lambda (repo &key on-start on-complete &allow-other-keys)
                (declare (ignore repo))
                (funcall on-start)
                (setf complete on-complete)))
               (nerimux/vcs:delete-worktree-async
                (lambda (&rest args) (declare (ignore args)) (incf deletes))))
            (nerimux::%client-create-detached-worktree repository conn session)
            (let ((state (nerimux::client-conn-workspace-assignment conn)))
              (ecase mode
                (:disconnect (setf nerimux::*clients* nil))
                (:stale (setf (nerimux::client-conn-workspace-assignment conn) nil))
                (:refresh-error
                 (setf (nerimux/vcs:detached-worktree-result-refresh-error receipt)
                       (make-condition 'simple-error :format-control "refresh failed")))
                (:missing-worktree
                 (setf (nerimux/vcs:detached-worktree-result-worktree receipt) nil)))
              (funcall complete receipt)
              (expect (eq receipt (nerimux::workspace-assignment-receipt state)))
              (expect (eq :retained (nerimux::workspace-assignment-phase state)))
              (expect (null (nerimux::client-conn-transient-view conn)))
              (expect (= 0 deletes))
              (when (eq mode :refresh-error)
                (expect (search (nerimux/workspace-model:worktree-path worktree)
                                (first (nerimux::client-conn-message-log conn)))))))))))
  (it "keeps assignment after failed startup and retries the selected agent explicitly"
    (%with-assignment-fixture
      (let ((calls nil) (succeed nil))
        (with-stubbed-fdefinition
            ((nerimux::%open-client-worktree-pane
              (lambda (s c wt &key default-command agent-kind)
                (push (list s c wt default-command agent-kind) calls)
                (values t succeed))))
          (nerimux::%handle-multi-key-message session conn #(97))
          (let ((state (nerimux::client-conn-workspace-assignment conn)))
            (nerimux::%handle-multi-key-message session conn #(120))
            (expect (eq :assigning (nerimux::workspace-assignment-phase state)))
            (expect (eq :transient (nerimux::client-conn-modal conn)))
            (setf succeed t)
            (nerimux::%handle-multi-key-message session conn #(99))
            (expect (eq :done (nerimux::workspace-assignment-phase state)))
            (expect (null (nerimux::client-conn-modal conn)))
            (expect (equal (list (list session conn worktree nerimux::+workspace-claude-command+ :claude)
                                (list session conn worktree nerimux::+workspace-codex-command+ :codex))
                           calls)))))))
  (it "rejects stale or pending worktrees before opening an assignment pane"
    (%with-assignment-fixture
      (let ((opens 0)
            (state nil))
        (nerimux::%client-assign-worktree nil conn)
        (setf state (nerimux::client-conn-workspace-assignment conn))
        (with-stubbed-fdefinition
            ((nerimux::%open-client-worktree-pane
              (lambda (&rest arguments)
                (declare (ignore arguments))
                (incf opens)
                (values t t))))
          (setf (nerimux::workspace-assignment-worktree-id state) "stale")
          (nerimux::%handle-worktree-assignment-key session conn state #(120))
          (expect (zerop opens))
          (expect (search "workspace changed; refresh before assigning"
                          (first (nerimux::client-conn-message-log conn))))
          (setf (nerimux::client-conn-message-log conn) nil
                (nerimux::workspace-assignment-worktree-id state)
                (nerimux/workspace-model:worktree-id worktree)
                (gethash (nerimux::%worktree-delete-key worktree)
                         nerimux::*worktree-delete-reservations*)
                (nerimux::make-worktree-delete-reservation
                 :key (nerimux::%worktree-delete-key worktree)
                 :worktree worktree))
          (nerimux::%handle-worktree-assignment-key session conn state #(120))
          (expect (zerop opens))
          (expect (search "worktree deletion is pending"
                          (first (nerimux::client-conn-message-log conn))))))))
  (it "preserves a created workspace after startup fails before creating any pane"
    (%with-assignment-fixture
      (let ((deletes 0) (starts 0))
        (with-stubbed-fdefinition
            ((nerimux/vcs:create-detached-worktree-async
              (lambda (repo &key on-complete &allow-other-keys)
                (declare (ignore repo)) (funcall on-complete receipt)))
             (nerimux::%open-client-worktree-pane
              (lambda (&rest args) (declare (ignore args)) (incf starts) nil))
             (nerimux/vcs:delete-worktree-async
              (lambda (&rest args) (declare (ignore args)) (incf deletes))))
          (nerimux::%client-create-detached-worktree repository conn session)
          (nerimux::%handle-multi-key-message session conn #(120))
          (expect (= 1 starts))
          (expect (null (nerimux/workspace-model:worktree-panes worktree)))
          (expect (eq :transient (nerimux::client-conn-modal conn)))
          (nerimux::%handle-multi-key-message session conn #(27))
          (expect (= 0 deletes))))))
  (it "only explicit cancel queues guarded nonforce deletion and holds a reservation until callback"
    (%with-assignment-fixture
      (let ((calls 0) (complete nil) (guard nil))
        (with-stubbed-fdefinition
            ((nerimux/vcs:create-detached-worktree-async
              (lambda (repo &key on-complete &allow-other-keys)
                (declare (ignore repo)) (funcall on-complete receipt)))
             (nerimux/vcs:delete-worktree-async
              (lambda (wt &key force before-delete on-complete &allow-other-keys)
                (expect (eq wt worktree)) (expect (not force))
                (expect (nerimux::%worktree-cancel-pending-p wt))
                (incf calls) (setf complete on-complete guard before-delete))))
          (nerimux::%client-create-detached-worktree repository conn session)
          (let ((state (nerimux::client-conn-workspace-assignment conn)))
            (nerimux::%close-client-transient conn)
            (expect (= 0 calls))
            (nerimux::%show-worktree-assignment conn state)
            (nerimux::%handle-multi-key-message session conn #(113))
            (expect (= 1 calls))
            (expect (functionp guard))
            (expect (nerimux::%worktree-cancel-pending-p worktree))
            (setf (nerimux/workspace-model:worktree-head worktree) "changed")
            (expect (handler-case (progn (funcall guard) nil) (error () t)))
            (funcall complete t)
            (expect (not (nerimux::%worktree-cancel-pending-p worktree))))))))
  (it "refuses duplicate assignment cancellation reservations"
    (%with-assignment-fixture
      (let ((deletes 0))
        (with-stubbed-fdefinition
            ((nerimux/vcs:create-detached-worktree-async
              (lambda (repo &key on-complete &allow-other-keys)
                (declare (ignore repo)) (funcall on-complete receipt)))
             (nerimux/vcs:delete-worktree-async
              (lambda (&rest args) (declare (ignore args)) (incf deletes))))
          (nerimux::%client-create-detached-worktree repository conn session)
          (let ((state (nerimux::client-conn-workspace-assignment conn)))
            (setf (gethash (nerimux::%workspace-cancel-key
                            (nerimux::workspace-assignment-path state))
                           nerimux::*workspace-cancel-reservations*)
                  state)
            (nerimux::%handle-multi-key-message session conn #(113))
            (expect (= 0 deletes))
            (expect (eq :retained (nerimux::workspace-assignment-phase state)))
            (expect (search "already pending"
                            (first (nerimux::client-conn-message-log conn)))))))))
  (it "preserves changed or occupied created workspaces before deletion is queued"
    (dolist (mode '(:dirty :locked :head :branch :pane :identity :running-agent :missing))
      (%with-assignment-fixture
        (let ((deletes 0))
          (with-stubbed-fdefinition
              ((nerimux/vcs:create-detached-worktree-async
                (lambda (repo &key on-complete &allow-other-keys)
                  (declare (ignore repo)) (funcall on-complete receipt)))
               (nerimux/vcs:delete-worktree-async
                (lambda (&rest args) (declare (ignore args)) (incf deletes))))
            (nerimux::%client-create-detached-worktree repository conn session)
            (ecase mode
              (:dirty (setf (nerimux/workspace-model:worktree-dirty-p worktree) t))
              (:locked (setf (nerimux/workspace-model:worktree-locked-p worktree) t))
              (:head (setf (nerimux/workspace-model:worktree-head worktree) "changed"))
              (:branch (setf (nerimux/workspace-model:worktree-branch worktree) "new-branch"))
              (:pane (setf (nerimux/workspace-model:worktree-panes worktree)
                           (list (make-no-pty-pane 99 0 0 80 24))))
              (:identity (setf (nerimux/workspace-model:worktree-id worktree) "replacement"))
              (:running-agent
               (let ((pane (make-no-pty-pane 99 0 0 80 24)))
                 (setf (nerimux/pane:pane-fd pane) 9
                       (nerimux/pane:pane-agent-kind pane) :codex)
                 (nerimux/pane:worktree-add-pane worktree pane)))
              (:missing
               (setf (nerimux/workspace-model:worktree-missing-p worktree) t)))
            (nerimux::%handle-multi-key-message session conn #(113))
            (expect (= 0 deletes))
            (expect (search "not confirmed" (first (nerimux::client-conn-message-log conn)))))))))
  (it "blocks another client's open and split before spawning or unzooming"
    (%with-r5-fixture (session conn worktree window)
      (let ((other (%make-test-conn)) (spawns 0)
            (nerimux::*workspace-cancel-reservations* (make-hash-table :test #'equal)))
        (setf (gethash (nerimux::%workspace-cancel-key
                       (nerimux/workspace-model:worktree-path worktree))
                      nerimux::*workspace-cancel-reservations*) :pending)
        (nerimux/window:window-zoom-toggle window)
        (with-stubbed-fdefinition
            ((nerimux/pane::%fork-pane
              (lambda (&rest args) (declare (ignore args)) (incf spawns))))
          (nerimux::%open-client-worktree-pane session other worktree)
          (nerimux::%workspace-prefix-split session conn :horizontal)
          (expect (= 0 spawns))
          (expect (nerimux/window:window-zoom-p window)))))))

(defun %check-assignment-real-git-guard (mode)
  (nerimux/test/vcs::%call-with-worktree-path-repository
   (lambda (repository root)
     (declare (ignore root))
     (multiple-value-bind (receipt errors)
         (nerimux/test/vcs::%detached-test-create repository)
       (expect (null errors))
       (expect receipt)
       (let* ((worktree (nerimux/vcs:detached-worktree-result-worktree receipt))
              (path (nerimux/vcs:detached-worktree-result-path receipt))
              (head (nerimux/vcs:detached-worktree-result-head receipt))
              (model-head (nerimux/workspace-model:worktree-head worktree))
              (conn (%make-test-conn :rows 200 :cols 200))
              (state nil))
         (expect worktree)
         (expect (probe-file path))
         (with-loop-state
          (let ((nerimux::*clients* (list conn))
                (nerimux/vcs::*workspace-organizations*
                 (list (nerimux/workspace-model:make-organization
                        :id "assignment-guard-org" :repositories (list repository)))))
           (with-stubbed-fdefinition
               ((nerimux/vcs:create-detached-worktree-async
                 (lambda (repo &key on-complete &allow-other-keys)
                   (expect (eq repository repo))
                   (funcall on-complete receipt))))
             (nerimux::%client-create-detached-worktree repository conn nil))
           (setf state (nerimux::client-conn-workspace-assignment conn))
           (expect (eq receipt (nerimux::workspace-assignment-receipt state)))
           (expect (eq :assigning (nerimux::workspace-assignment-phase state)))
           (expect (eq repository
                       (nerimux::%workspace-find-repository
                        (nerimux/workspace-model:repository-local-path repository))))
           (expect (equal (nerimux::workspace-assignment-path state)
                          (nerimux/workspace-model:worktree-path worktree)))
           (expect (eq worktree (nerimux::%assignment-current-worktree state)))
           (expect (equal head (nerimux::workspace-assignment-head state)))
           (expect (equal model-head (nerimux::workspace-assignment-model-head state)))
           (expect (null (nerimux/workspace-model:worktree-branch worktree)))
           (expect (null (nerimux::worktree-panes worktree)))
           (expect (not (nerimux::worktree-running-agent-p worktree)))
           (expect (not (nerimux/workspace-model:worktree-dirty-p worktree)))
           (expect (not (nerimux/workspace-model:worktree-locked-p worktree)))
           (expect (not (nerimux::worktree-missing-p worktree)))
           (expect (eq worktree (nerimux::%check-assignment-cancellation state :git-p t)))
           (ecase mode
             (:clean nil)
             (:head
              (nerimux/test/vcs::%fetch-test-git
               path "-c" "user.name=Test" "-c" "user.email=test@example.invalid"
               "-c" "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null"
               "commit" "--allow-empty" "-m" "advance"))
             (:branch
              (nerimux/test/vcs::%fetch-test-git
               path "-c" "core.hooksPath=/dev/null"
               "checkout" "-b" "assignment-guard-attached"))
             (:running-agent
              (nerimux/pane:worktree-add-pane
               worktree
               (nerimux/pane:make-pane :id 777 :fd 42 :agent-kind :claude))))
           (expect (equal model-head (nerimux/workspace-model:worktree-head worktree)))
           (expect (null (nerimux/workspace-model:worktree-branch worktree)))
           (if (eq mode :running-agent)
               (expect
                (handler-case
                    (progn (nerimux::%check-assignment-cancellation state) nil)
                  (error (condition)
                    (search "workspace changed or is in use; cancellation refused"
                            (princ-to-string condition)))))
               (expect (eq worktree (nerimux::%check-assignment-cancellation state))))
           (when (eq mode :running-agent)
             (return-from %check-assignment-real-git-guard t))
           (let ((actual-head (nerimux/test/vcs::%fetch-test-git path "rev-parse" "HEAD"))
                 (actual-branch (nerimux/test/vcs::%fetch-test-git
                                 path "rev-parse" "--abbrev-ref" "HEAD")))
             (expect (if (eq mode :head)
                         (not (equal head actual-head))
                         (equal head actual-head)))
             (expect (equal (if (eq mode :branch) "assignment-guard-attached" "HEAD")
                            actual-branch)))
           (if (eq mode :clean)
               (expect (eq worktree (nerimux::%check-assignment-cancellation state :git-p t)))
               (expect
                (handler-case
                    (progn (nerimux::%check-assignment-cancellation state :git-p t) nil)
                  (error (condition)
                    (search "workspace Git identity changed; cancellation refused"
                            (princ-to-string condition)))))))))))))

(describe "worktree assignment real Git cancellation guard"
  (it "accepts a clean detached workspace at the recorded HEAD"
    (%check-assignment-real-git-guard :clean))
  (it "rejects an actual HEAD change while the model remains unchanged"
    (%check-assignment-real-git-guard :head))
  (it "rejects an attached branch at the same HEAD while the model remains detached"
    (%check-assignment-real-git-guard :branch))
  (it "rejects cancellation while an agent is still running"
    (%check-assignment-real-git-guard :running-agent)))

(describe "worktree lifecycle acceptance"
  (it "rejects completion arguments instead of completing the selected workspace"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (dolist (command '("workspace-complete other" "wt-complete -t other"
                        "workspace-complete -t" "wt-complete --target"))
        (nerimux::%client-enter-command-mode conn command)
        (nerimux::%submit-client-command session conn)
        (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
        (expect (not (eq :confirm (nerimux::client-conn-modal conn))))
        (expect (string= "workspace-complete takes no arguments"
                         (first (nerimux::client-conn-message-log conn)))))))
  (it "launches explicit agents once and rejects duplicates before spawning"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (let ((calls nil))
        (with-stubbed-fdefinition
            ((nerimux/pane::%fork-pane
              (lambda (session id x y cols rows &key start-dir default-command)
                (declare (ignore session))
                (push (list start-dir default-command) calls)
                (let ((pane (make-no-pty-pane id x y cols rows)))
                  (setf (nerimux/pane:pane-fd pane) 9000)
                  pane))))
          (expect (nerimux::%client-open-selected-worktree-command
                   session conn "codex" :agent-kind :codex))
          (expect (equal '(("/tmp/nerimux-r5-wt" "codex")) calls))
          (expect (eq :codex (nerimux/pane:pane-agent-kind
                             (nerimux/workspace-model:worktree-agent-pane worktree))))
          (expect (not (nerimux::%client-open-selected-worktree-command
                        session conn "claude" :agent-kind :claude)))
          (expect (= 1 (length calls)))
          (nerimux/pane:pane-mark-process-exit
           (nerimux/workspace-model:worktree-agent-pane worktree) :status 0)
          (expect (nerimux::%client-open-selected-worktree-command
                   session conn "claude" :agent-kind :claude))
          (expect (= 2 (length calls)))
          (expect (eq :claude (nerimux/pane:pane-agent-kind
                              (nerimux/workspace-model:worktree-agent-pane worktree))))))))
  (it "resumes a successful agent launch even when its reader observes immediate exit"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (nerimux/workspace-model:worktree-complete worktree)
      (let ((reader-calls 0))
        (with-stubbed-fdefinition
            ((nerimux::start-reader-thread
              (lambda (pane)
                (incf reader-calls)
                (expect (eq :codex (nerimux/pane:pane-agent-kind pane)))
                (expect (eq worktree (nerimux/pane:pane-worktree pane)))
                (expect (eq pane (nerimux/workspace-model:worktree-agent-pane worktree)))
                (nerimux/pane:pane-mark-process-exit pane :status 0))))
          (expect (nerimux::%client-open-selected-worktree-command
                   session conn "codex" :agent-kind :codex)))
        (expect (= 1 reader-calls))
        (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
        (expect (eq :exited (nerimux/pane:worktree-agent-state worktree))))))
  (it "keeps completion and prevents duplicate spawning after reader startup failure"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (nerimux/workspace-model:worktree-complete worktree)
      (let ((fork (symbol-function 'nerimux/pane::%fork-pane))
            (spawn-calls 0)
            (reader-calls 0))
        (with-stubbed-fdefinition
            ((nerimux/pane::%fork-pane
              (lambda (&rest arguments)
                (incf spawn-calls)
                (apply fork arguments)))
             (nerimux::start-reader-thread
              (lambda (pane)
                (declare (ignore pane))
                (incf reader-calls)
                (error "reader startup failed"))))
          (expect (not (nerimux::%client-open-selected-worktree-command
                        session conn "codex" :agent-kind :codex)))
          (expect (nerimux/workspace-model:worktree-completed-p worktree))
          (expect (eq :running (nerimux/pane:worktree-agent-state worktree)))
          (expect (eq :codex (nerimux/pane:pane-agent-kind
                             (nerimux/workspace-model:worktree-agent-pane worktree))))
          (expect (not (nerimux::%client-open-selected-worktree-command
                        session conn "claude" :agent-kind :claude)))
          (expect (= 1 spawn-calls))
          (expect (= 1 reader-calls))))))
  (it "keeps completion and previous agent history when a replacement fails"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (nerimux::%client-open-selected-worktree-command session conn "codex" :agent-kind :codex)
      (let ((old (nerimux/workspace-model:worktree-agent-pane worktree))
            (calls 0))
        (nerimux/pane:pane-mark-process-exit old :status 0)
        (nerimux/workspace-model:worktree-complete worktree)
        (with-stubbed-fdefinition
            ((nerimux/pane::%fork-pane
              (lambda (session id x y cols rows &key start-dir default-command)
                (declare (ignore session start-dir default-command))
                (incf calls)
                (make-no-pty-pane id x y cols rows))))
          (nerimux::%client-open-selected-worktree-command session conn "codex" :agent-kind :codex)
          (expect (= 1 calls))
          (expect (nerimux/pane:pane-startup-failed-p (nerimux::client-conn-focus conn)))
          (expect (nerimux/workspace-model:worktree-completed-p worktree))
          (expect (eq old (nerimux/workspace-model:worktree-agent-pane worktree))))
        (nerimux::%focus-selected-client-worktree session conn)
        (expect (not (nerimux/workspace-model:worktree-completed-p worktree))))))
  (it "confirms a named completion without stopping the running agent"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (nerimux::%client-open-selected-worktree-command session conn "codex" :agent-kind :codex)
      (with-stubbed-fdefinition
          ((nerimux::%workspace-find-worktree
            (lambda (token &optional organizations)
              (declare (ignore organizations))
              (expect (string= token (nerimux/workspace-model:worktree-path worktree)))
              worktree)))
        (nerimux::%client-enter-command-mode conn "workspace-complete")
        (nerimux::%submit-client-command session conn)
        (expect (eq :confirm (nerimux::client-conn-modal conn)))
        (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
        (nerimux::%handle-multi-key-message session conn #(121))
        (expect (nerimux/workspace-model:worktree-completed-p worktree))
        (expect (eq :running (nerimux/pane:worktree-agent-state worktree))))))
  (it "resolves completion confirmation against the refreshed catalog and rejects removal"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (nerimux::%client-open-selected-worktree-command session conn "codex" :agent-kind :codex)
      (let ((current (nerimux/workspace-model:make-worktree
                      :path (nerimux/workspace-model:worktree-path worktree))))
        (with-stubbed-fdefinition
            ((nerimux::%workspace-find-worktree
              (lambda (token &optional organizations)
                (declare (ignore token organizations)) current)))
          (nerimux::%client-enter-command-mode conn "wt-complete")
          (nerimux::%submit-client-command session conn)
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (nerimux::%handle-multi-key-message session conn #(121))
          (expect (nerimux/workspace-model:worktree-completed-p current))
          (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
          (setf current nil)
          (nerimux::%client-complete-workspace conn)
          (nerimux::%handle-multi-key-message session conn #(121))
          (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
          (expect (string= "worktree no longer available"
                           (first (nerimux::client-conn-message-log conn)))))))))

(describe "workspace-completion-toggle"
  (it "toggles an idle workspace directly from overview"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (let ((nerimux/vcs::*workspace-organizations*
              (list (nerimux/workspace-model:repository-organization
                     (nerimux/workspace-model:worktree-repository worktree)))))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message session conn #(67))
        (expect (nerimux/workspace-model:worktree-completed-p worktree))
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message session conn #(67))
        (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "confirms running completion but clears completion without touching panes"
    (%with-r5-fixture (session conn worktree terminal-window)
      (nerimux::%client-open-selected-worktree-command session conn "codex" :agent-kind :codex)
      (let* ((nerimux/vcs::*workspace-organizations*
               (list (nerimux/workspace-model:repository-organization
                      (nerimux/workspace-model:worktree-repository worktree))))
             (window (nerimux/session:session-active-window session))
             (agent (nerimux/workspace-model:worktree-agent-pane worktree))
             (panes (copy-list (nerimux/workspace-model:worktree-panes worktree)))
             (window-panes (copy-list (nerimux/window:window-panes window)))
             (fds (mapcar #'nerimux/pane:pane-fd panes))
             (pids (mapcar #'nerimux/pane:pane-pid panes))
             (focus (nerimux::client-conn-focus conn)))
        (expect window)
        (expect (not (eq terminal-window window)))
        (expect (= 2 (length panes)))
        (expect window-panes)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message session conn #(67))
        (expect (eq :confirm (nerimux::client-conn-modal conn)))
        (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
        (nerimux::%handle-multi-key-message session conn #(110))
        (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
        (nerimux::%handle-multi-key-message session conn #(67))
        (nerimux::%handle-multi-key-message session conn #(121))
        (expect (nerimux/workspace-model:worktree-completed-p worktree))
        (nerimux::%handle-multi-key-message session conn #(67))
        (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq agent (nerimux/workspace-model:worktree-agent-pane worktree)))
        (expect (eq :running (nerimux/pane:worktree-agent-state worktree)))
        (expect (equal panes (nerimux/workspace-model:worktree-panes worktree)))
        (expect (equal window-panes (nerimux/window:window-panes window)))
        (expect (equal fds (mapcar #'nerimux/pane:pane-fd panes)))
        (expect (equal pids (mapcar #'nerimux/pane:pane-pid panes)))
        (expect (eq window (nerimux/session:session-active-window session)))
        (expect (eq focus (nerimux::client-conn-focus conn))))))

  (it "toggles the current catalog object and rejects missing selections"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (let* ((repository (nerimux/workspace-model:worktree-repository worktree))
             (nerimux/vcs::*workspace-organizations*
               (list (nerimux/workspace-model:repository-organization repository)))
             (current (nerimux/workspace-model:make-worktree
                       :repository repository
                       :path (nerimux/workspace-model:worktree-path worktree))))
        (setf (nerimux/workspace-model:worktree-completed-p current) t
              (nerimux/workspace-model:worktree-completed-p worktree) t
              (nerimux/workspace-model:repository-worktrees repository) (list current)
              (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message session conn #(67))
        (expect (not (nerimux/workspace-model:worktree-completed-p current)))
        (expect (nerimux/workspace-model:worktree-completed-p worktree))
        (setf (nerimux/workspace-model:repository-worktrees repository) nil)
        (nerimux::%handle-multi-key-message session conn #(67))
        (expect (string= "worktree no longer available"
                         (first (nerimux::client-conn-message-log conn))))
        (expect (nerimux/workspace-model:worktree-completed-p worktree))
        (setf (nerimux::client-conn-selected-worktree conn) nil)
        (nerimux::%handle-multi-key-message session conn #(67))
        (expect (string= "no worktree selected"
                         (first (nerimux::client-conn-message-log conn)))))))

  (it "re-resolves the catalog at confirmation and rejects a removed target"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (nerimux::%client-open-selected-worktree-command session conn "codex" :agent-kind :codex)
      (let* ((repository (nerimux/workspace-model:worktree-repository worktree))
             (nerimux/vcs::*workspace-organizations*
               (list (nerimux/workspace-model:repository-organization repository)))
             (current (nerimux/workspace-model:make-worktree
                       :repository repository
                       :path (nerimux/workspace-model:worktree-path worktree))))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message session conn #(67))
        (expect (eq :confirm (nerimux::client-conn-modal conn)))
        (setf (nerimux/workspace-model:repository-worktrees repository) (list current))
        (nerimux::%handle-multi-key-message session conn #(121))
        (expect (nerimux/workspace-model:worktree-completed-p current))
        (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
        (setf (nerimux/workspace-model:repository-worktrees repository) (list worktree))
        (nerimux::%handle-multi-key-message session conn #(67))
        (expect (eq :confirm (nerimux::client-conn-modal conn)))
        (setf (nerimux/workspace-model:repository-worktrees repository) nil)
        (nerimux::%handle-multi-key-message session conn #(121))
        (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
        (expect (string= "worktree no longer available"
                         (first (nerimux::client-conn-message-log conn)))))))

  (it "keeps named completion commands completion-only"
    (%with-r5-fixture (session conn worktree window)
      (declare (ignore window))
      (setf (nerimux/workspace-model:worktree-completed-p worktree) t)
      (dolist (command '("workspace-complete" "wt-complete"))
        (nerimux::%client-enter-command-mode conn command)
        (nerimux::%submit-client-command session conn)
        (expect (nerimux/workspace-model:worktree-completed-p worktree))
        (expect (null (nerimux::client-conn-modal conn)))))))

(describe "workspace-panes-acceptance-suite"

  (it "workspace-agent-stop-prefix-preserves-terminal-focus-and-attachments"
    (%with-r5-fixture (session conn worktree terminal-window)
      (let ((terminal (nerimux::client-conn-focus conn)))
        (nerimux::%client-open-selected-worktree-command session conn "codex" :agent-kind :codex)
        (nerimux::%set-client-focus conn terminal)
        (let* ((agent (nerimux/workspace-model:worktree-agent-pane worktree))
               (panes (copy-list (nerimux/workspace-model:worktree-panes worktree)))
               (windows (copy-list (nerimux/session:session-windows session)))
               (terminal-panes (copy-list (nerimux/window:window-panes terminal-window)))
               (worker nil)
               (calls 0)
               (nerimux/ports:*close-pty*
                 (lambda (fd pid)
                   (declare (ignore fd pid))
                   (incf calls)
                   (values 9 :signaled))))
          (with-stubbed-fdefinition
              ((cl-concurrent-kit:make-thread
                (lambda (function &key name)
                  (declare (ignore name))
                  (setf worker function))))
            (nerimux::%handle-multi-key-message session conn #(17))
            (nerimux::%handle-multi-key-message session conn #(75))
            (expect (functionp worker))
            (expect (= 0 calls))
            (expect (not (nerimux/pane:pane-process-exited-p agent)))
            (funcall worker)
            (nerimux::reader-eof-state agent)
            (expect (= 1 calls))
            (expect (nerimux/pane:pane-process-exited-p agent))
            (expect (eq terminal (nerimux::client-conn-focus conn)))
            (expect (= 9999 (nerimux/pane:pane-fd terminal)))
            (expect (equal panes (nerimux/workspace-model:worktree-panes worktree)))
            (expect (equal windows (nerimux/session:session-windows session)))
            (expect (equal terminal-panes (nerimux/window:window-panes terminal-window)))
            (expect (eq agent (nerimux/workspace-model:worktree-agent-pane worktree))))))))

  (it "r5-1-split-that-does-not-fit-notifies-and-changes-nothing"
    (with-loop-state
      (multiple-value-bind (session window pane)
          (make-single-pane-session :width 3 :height 2)
        (let* ((worktree
                 (nerimux/workspace-model:make-worktree :id "wt" :path "/tmp/wt" :branch "feat/tiny"))
               (conn (%make-test-conn))
               (nerimux::*clients* (list conn)))
          (nerimux/pane:worktree-add-pane worktree pane)
          (nerimux::%set-client-focus conn pane)
          (nerimux::%handle-multi-key-message session conn #(17)) ; C-q
          (nerimux::%handle-multi-key-message session conn #(45)) ; -
          (expect (= 1 (length (nerimux/window:window-panes window))))
          (expect (= 1 (length (nerimux/workspace-model:worktree-panes worktree))))
          (expect (string= "pane too small to split"
                           (first (nerimux::client-conn-message-log conn))))))))

  (it "r5-acceptance-split-focus-cap-new-window-move-close-to-empty"
    (%with-r5-fixture (session conn worktree window-1)
      (expect (= 1 (length (nerimux/window:window-panes window-1))))
      (expect (= 1 (length (nerimux/workspace-model:worktree-panes worktree))))

      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(45)) ; -
      (expect (= 2 (length (nerimux/window:window-panes window-1))))
      (expect (= 2 (length (nerimux/workspace-model:worktree-panes worktree))))
      (expect (string= "/tmp/nerimux-r5-wt"
                       (nerimux/pane:pane-start-path
                        (nerimux/window:window-active-pane window-1))))

      (let ((before (nerimux::client-conn-focus conn)))
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(107)) ; k
        (expect (not (eq before (nerimux::client-conn-focus conn)))))

      (dotimes (_ 2)
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(45)))
      (expect (= 4 (length (nerimux/window:window-panes window-1))))

      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(45))
      (expect (= 4 (length (nerimux/window:window-panes window-1)))
              )
      (expect (= 2 (length (nerimux::%worktree-windows worktree)))
              )
      (let ((window-2 (nerimux/session:session-active-window session)))
        (expect (not (eq window-1 window-2)))
        (expect (= 1 (length (nerimux/window:window-panes window-2))))
        (expect (= 5 (length (nerimux/workspace-model:worktree-panes worktree))))
        (expect (string= "feat/phase3 (2)" (nerimux/window:window-name window-2)))

        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(112)) ; p
        (expect (eq window-1 (nerimux/session:session-active-window session)))

        (dotimes (_ 3)
          (nerimux::%handle-multi-key-message session conn #(17))
          (nerimux::%handle-multi-key-message session conn #(120))) ; x
        (expect (= 1 (length (nerimux/window:window-panes window-1))))
        (expect (member window-1 (nerimux/session:session-windows session)))

        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(120))
        (expect (not (member window-1 (nerimux/session:session-windows session))))
        (expect (not (member window-1 (nerimux::%worktree-windows worktree))))
        (expect (eq window-2 (nerimux/session:session-active-window session))
                )
        (expect (eq (nerimux/window:window-active-pane window-2)
                    (nerimux::client-conn-focus conn)))

        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(120))
        (expect (null (nerimux/workspace-model:worktree-panes worktree)))
        (expect (null (nerimux/session:session-windows session)))
        (expect (eq :repolist (nerimux::client-conn-view conn))))))

  (it "r5-6-zoom-auto-unzoom-so-the-4-pane-cap-is-checked-on-the-real-count"
    (%with-r5-fixture (session conn worktree window)
      (dotimes (_ 3)
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(45)))
      (expect (= 4 (length (nerimux/window:window-panes window))))

      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(122)) ; z
      (expect (nerimux/window:window-zoom-p window))
      (expect (= 1 (length (nerimux/window:window-panes window)))
              )

      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(45)) ; -
      (expect (not (nerimux/window:window-zoom-p window)) )
      (expect (= 4 (length (nerimux/window:window-panes window)))
              )
      (expect (= 2 (length (nerimux::%worktree-windows worktree)))
              )))

  (it "r5-7-worktree-pane-startup-failure-is-recorded-as-durable-state"
    (with-loop-state
      (with-stubbed-fdefinition
          ((nerimux/pane::%fork-pane
            (lambda (session id x y cols rows &key start-dir default-command)
              (declare (ignore session start-dir default-command))
              (make-no-pty-pane id x y cols rows)))) ; fd stays -1: not live
        (let* ((organization
                 (nerimux/workspace-model:make-organization
                  :id "org" :host "github.com" :name "team"))
               (repository
                 (nerimux/workspace-model:make-repository
                  :id "repo" :organization organization
                  :specification "github.com/team/repo"))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "wt" :repository repository
                  :path "/tmp/nerimux-r5-7-wt" :branch "feat/broken"))
               (session (nerimux/session:make-session :id 1 :name "0" :windows nil))
               (conn (%make-test-conn))
               (nerimux::*clients* (list conn)))
          (nerimux/workspace-model:organization-add-repository organization repository)
          (nerimux/workspace-model:repository-add-worktree repository worktree)
          (setf (nerimux::client-conn-view conn) :repolist)
          (nerimux::%set-client-selected-tree-object conn worktree)
          (nerimux::%handle-multi-key-message session conn #(116))
          (let ((pane (nerimux/window:window-active-pane
                       (nerimux/session:session-active-window session))))
            (expect (nerimux/pane:pane-startup-failed-p pane))
            (expect (not (nerimux/pane:pane-live-p pane)))
            (expect (member pane (nerimux/workspace-model:worktree-panes worktree)))
            (expect (eq pane (nerimux::client-conn-focus conn)))
            (expect (string= "worktree pane failed to start"
                             (first (nerimux::client-conn-message-log conn))))))))))
