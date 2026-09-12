(in-package #:nerimux/test)

(defmacro with-workspace-prune-fixture ((conn worktrees preflights deletes) &body body)
  `(let* ((organization (nerimux/workspace-model:make-organization :id "prune-org"))
          (,worktrees
            (loop for id in '("prune-a" "prune-b")
                  for repository = (nerimux/workspace-model:make-repository
                                    :id id :organization organization)
                  for worktree = (nerimux/workspace-model:make-worktree
                                  :id id :repository repository
                                  :path (concatenate 'string "/prune-fixture/" id)
                                  :completed-p t)
                  do (nerimux/workspace-model:organization-add-repository organization repository)
                     (nerimux/workspace-model:repository-add-worktree repository worktree)
                     (setf (nerimux/workspace-model:repository-main-worktree repository) nil)
                  collect worktree))
          (,conn (%make-test-conn))
          (nerimux::*clients* (list ,conn))
          (nerimux::*server-sessions* nil)
          (nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
          (nerimux::*workspace-cancel-reservations* (make-hash-table :test #'equal))
          (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
          (,preflights nil) (,deletes nil))
     (setf (nerimux/workspace-model:organization-repositories organization)
           (nreverse (nerimux/workspace-model:organization-repositories organization))
           (nerimux::client-conn-selected-worktree ,conn) (first ,worktrees))
     (with-stubbed-fdefinition
         ((nerimux/vcs:workspace-organizations (lambda () (list organization)))
          (nerimux::%workspace-prune-directory-identity
            (lambda (worktree) (list (nerimux/workspace-model:worktree-path worktree))))
          (nerimux/vcs:read-worktree-prune-snapshot-async
            (lambda (worktree &rest options) (push (cons worktree options) ,preflights)))
          (nerimux/vcs:delete-worktree-async
            (lambda (worktree &rest options) (push (cons worktree options) ,deletes)))
          (nerimux/vcs:validate-worktree-prune-snapshot
            (lambda (worktree snapshot) (declare (ignore worktree snapshot)) t)))
       ,@body)))

(describe "workspace-prune-lifecycle"
  (it "workspace-prune-job-defaults-are-independent"
    (let ((job (nerimux::make-workspace-prune-job)))
      (expect (hash-table-p (nerimux::workspace-prune-job-operation-jobs job)))
      (expect (eq :queued (nerimux::workspace-prune-job-state job)))
      (expect (null (nerimux::workspace-prune-job-results job)))
      (expect (null (nerimux::workspace-prune-job-cancelled-p job)))))

  (it "prunes two candidates in one repository after the real refresh replaces queued objects"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (let* ((repository (nerimux/workspace-model:worktree-repository (first worktrees)))
             (second-path (nerimux/workspace-model:worktree-path (second worktrees)))
             (primary-path "/prune-fixture/primary"))
        (setf (nerimux/workspace-model:organization-repositories organization) (list repository)
              (nerimux/workspace-model:worktree-repository (second worktrees)) repository
              (nerimux/workspace-model:repository-worktrees repository) (copy-list worktrees))
        (nerimux::%client-prune-workspaces conn :all t)
        (funcall (getf (cdar preflights) :on-complete)
                 (nerimux/vcs::make-worktree-prune-snapshot))
        (nerimux/vcs::%apply-repository-refresh
         repository
         (nerimux/vcs::%make-repository-refresh
          :raw-worktrees (mapcar (lambda (path) (vcs-kit::%make-vcs-worktree :path path))
                                (list primary-path second-path))
          :status-updates (mapcar (lambda (path)
                                    (nerimux/vcs::%make-worktree-status-update :path path :ahead 0 :behind 0))
                                  (list primary-path second-path))))
        (funcall (getf (cdar deletes) :on-result)
                 (nerimux/vcs::make-worktree-delete-result :removed-p t))
        (expect (= 2 (length preflights)))
        (expect (not (eq (second worktrees) (caar preflights))))
        (expect (string= second-path (nerimux/workspace-model:worktree-path (caar preflights))))
        (funcall (getf (cdar preflights) :on-complete)
                 (nerimux/vcs::make-worktree-prune-snapshot))
        (expect (= 2 (length deletes)))
        (expect (funcall (getf (cdar deletes) :before-delete)))
        (funcall (getf (cdar deletes) :on-result)
                 (nerimux/vcs::make-worktree-delete-result :removed-p t))
        (expect (= 2 (count :removed (nerimux::workspace-prune-job-results
                                      (nerimux::client-conn-workspace-prune-job conn)) :key #'second))))))
  (it "refuses unrelated replacement objects rather than rebinding by path alone"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (nerimux::%client-prune-workspaces conn :all t)
      (let* ((old (second worktrees))
             (repository (nerimux/workspace-model:worktree-repository old)))
        (setf (nerimux/workspace-model:repository-worktrees repository)
              (list (nerimux/workspace-model:make-worktree
                     :repository repository :id (nerimux/workspace-model:worktree-id old)
                     :path (nerimux/workspace-model:worktree-path old) :completed-p t))))
      (funcall (getf (cdar preflights) :on-complete)
               (nerimux/vcs::make-worktree-prune-snapshot))
      (funcall (getf (cdar deletes) :on-result)
               (nerimux/vcs::make-worktree-delete-result :removed-p t))
      (expect (= 1 (length preflights)))
      (expect (eq :stale-workspace
                  (third (first (nerimux::workspace-prune-job-results
                                  (nerimux::client-conn-workspace-prune-job conn))))))))
  (it "refuses a queued successor whose directory was recreated at the same path"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (nerimux::%client-prune-workspaces conn :all t)
      (let* ((old (second worktrees))
             (repository (nerimux/workspace-model:worktree-repository old))
             (path (nerimux/workspace-model:worktree-path old)))
        (nerimux/vcs::%apply-repository-refresh
         repository
         (nerimux/vcs::%make-repository-refresh
          :raw-worktrees (mapcar (lambda (value) (vcs-kit::%make-vcs-worktree :path value))
                                (list "/prune-fixture/primary" path))
          :status-updates (mapcar (lambda (value)
                                   (nerimux/vcs::%make-worktree-status-update :path value :ahead 0 :behind 0))
                                  (list "/prune-fixture/primary" path))))
        (expect (not (eq old (nerimux/vcs:refreshed-worktree-successor old))))
        (funcall (getf (cdar preflights) :on-complete)
                 (nerimux/vcs::make-worktree-prune-snapshot))
        (with-stubbed-fdefinition
            ((nerimux::%workspace-prune-directory-identity
               (lambda (worktree) (list :recreated (nerimux/workspace-model:worktree-path worktree)))))
          (funcall (getf (cdar deletes) :on-result)
                   (nerimux/vcs::make-worktree-delete-result :removed-p t)))
        (expect (= 1 (length preflights)))
        (expect (eq :stale-directory
                    (third (first (nerimux::workspace-prune-job-results
                                    (nerimux::client-conn-workspace-prune-job conn)))))))))
  (it "terminates a cyclic successor chain without authorizing a replacement"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (let* ((old (first worktrees))
             (new (nerimux/workspace-model:make-worktree
                   :id (nerimux/workspace-model:worktree-id old)
                   :repository (nerimux/workspace-model:worktree-repository old)
                   :path (nerimux/workspace-model:worktree-path old)))
             (nerimux/vcs::*worktree-refresh-successors* (make-hash-table :test #'eq)))
        (setf (gethash old nerimux/vcs::*worktree-refresh-successors*) new
              (gethash new nerimux/vcs::*worktree-refresh-successors*) old)
        (expect (eq old (nerimux/vcs:refreshed-worktree-successor old))))))
  (it "rechecks cancellation attachment and directory identity after content validation"
    (dolist (change '(:cancel :attach :directory))
      (with-workspace-prune-fixture (conn worktrees preflights deletes)
        (let ((attached nil) (recreated nil))
          (nerimux::%client-prune-workspaces conn)
          (funcall (getf (cdar preflights) :on-complete)
                   (nerimux/vcs::make-worktree-prune-snapshot))
          (with-stubbed-fdefinition
              ((nerimux/vcs:validate-worktree-prune-snapshot
                 (lambda (&rest arguments)
                   (declare (ignore arguments))
                   (case change
                     (:attach (setf attached t))
                     (:directory (setf recreated t))
                     (:cancel (setf (nerimux::workspace-prune-job-cancelled-p
                                     (nerimux::client-conn-workspace-prune-job conn)) t)))
                   t))
               (nerimux::%workspace-prune-directory-identity
                 (lambda (worktree)
                   (if recreated (list :recreated)
                       (list (nerimux/workspace-model:worktree-path worktree)))))
               (nerimux::%worktree-attached-to-clients-p
                 (lambda (&rest arguments) (declare (ignore arguments)) attached)))
            (expect (signals error (funcall (getf (cdar deletes) :before-delete)))))))))
  (it "clean selected prune reserves preflight and removes without force only once"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (nerimux::%client-prune-workspaces conn)
      (expect (= 1 (length preflights)))
      (expect (nerimux::%worktree-delete-pending-p (first worktrees)))
      (let ((complete (getf (cdr (first preflights)) :on-complete))
            (snapshot (nerimux/vcs::make-worktree-prune-snapshot)))
        (funcall complete snapshot)
        (funcall complete snapshot))
      (expect (= 1 (length deletes)))
      (expect (null (getf (cdr (first deletes)) :force)))
      (expect (funcall (getf (cdr (first deletes)) :before-delete)))
      (let ((receipt (nerimux/vcs::make-worktree-delete-result :removed-p t))
            (complete (getf (cdr (first deletes)) :on-result)))
        (funcall complete receipt)
        (funcall complete receipt))
      (expect (= 1 (length (nerimux::workspace-prune-job-results
                            (nerimux::client-conn-workspace-prune-job conn)))))
      (expect (eq :succeeded (nerimux::workspace-prune-job-state
                             (nerimux::client-conn-workspace-prune-job conn))))))
  (it "workspace-job dirty cancellation continues across repositories and preserves individual outcomes"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (nerimux::%client-prune-workspaces conn :all t)
      (funcall (getf (cdr (first preflights)) :on-complete)
               (nerimux/vcs::make-worktree-prune-snapshot :changed-files '((:modified . "file"))))
      (expect (null deletes))
      (expect (eq :confirm (nerimux::client-conn-modal conn)))
      (let ((operation (gethash '(:worktree "prune-a" :prune) nerimux::*workspace-operation-jobs*)))
        (expect (eq :running (nerimux::workspace-operation-job-state operation)))
        (expect (eq :confirming (nerimux::workspace-operation-job-phase operation)))
        (nerimux::%handle-confirm-key nil conn #(110))
        (expect (eq :kept (nerimux::workspace-operation-job-state operation)))
        (expect (equal "not confirmed"
                       (nerimux::workspace-operation-job-outcome operation)))
        ;; A kept job is settled: it leaves the table so the row stops showing
        ;; the running job's "..." badge.
        (expect (null (gethash '(:worktree "prune-a" :prune)
                               nerimux::*workspace-operation-jobs*))))
      (expect (= 2 (length preflights)))
      (expect (eq (second worktrees) (caar preflights)))
      (funcall (getf (cdr (first preflights)) :on-complete)
               (nerimux/vcs::make-worktree-prune-snapshot))
      (funcall (getf (cdr (first deletes)) :on-result)
               (nerimux/vcs::make-worktree-delete-result :removed-p t :refresh-error "refresh failed"))
      (let ((operation (gethash '(:worktree "prune-b" :prune) nerimux::*workspace-operation-jobs*)))
        (expect (eq :failed (nerimux::workspace-operation-job-state operation)))
        (expect (equal "refresh failed"
                       (nerimux::workspace-operation-job-outcome operation))))
      (let ((job (nerimux::client-conn-workspace-prune-job conn)))
        (expect (eq :failed (nerimux::workspace-prune-job-state job)))
        (expect (equal '(:removed-refresh-failed :cancelled)
                       (mapcar #'second (nerimux::workspace-prune-job-results job)))))))
  (it "disconnect settles unstarted work and forbids late confirmation"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (nerimux::%client-prune-workspaces conn :all t)
      (setf nerimux::*clients* nil)
      (nerimux::%cancel-client-workspace-prune conn)
      (funcall (getf (cdr (first preflights)) :on-complete)
               (nerimux/vcs::make-worktree-prune-snapshot :changed-files '((:untracked . "new"))))
      (expect (null deletes))
      (expect (null (nerimux::client-conn-modal conn)))
      (expect (= 2 (count :cancelled
                         (nerimux::workspace-prune-job-results
                          (nerimux::client-conn-workspace-prune-job conn)) :key #'second)))))
  (it "dirty confirmation forces only after approval and rechecks lock authorization"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (nerimux::%client-prune-workspaces conn)
      (funcall (getf (cdr (first preflights)) :on-complete)
               (nerimux/vcs::make-worktree-prune-snapshot :changed-files '((:modified . "file"))))
      (nerimux::%handle-confirm-key nil conn #(121))
      (expect (= 1 (length deletes)))
      (expect (getf (cdr (first deletes)) :force))
      (setf (nerimux/workspace-model:worktree-locked-p (first worktrees)) t)
      (expect (signals error (funcall (getf (cdr (first deletes)) :before-delete))))))
  (it "live panes and attachment exclude candidates before Git work"
    (dolist (reason '(:live-pane :attached))
      (with-workspace-prune-fixture (conn worktrees preflights deletes)
        (when (eq reason :live-pane)
          (nerimux/pane:worktree-add-pane (first worktrees) (make-pane :id 900 :fd 9)))
        (with-stubbed-fdefinition
            ((nerimux::%worktree-attached-to-clients-p
               (lambda (&rest arguments)
                 (declare (ignore arguments)) (eq reason :attached))))
          (nerimux::%client-prune-workspaces conn))
        (expect (null preflights))
        (expect (null deletes))
        (expect (eq reason (third (first (nerimux::workspace-prune-job-results
                                         (nerimux::client-conn-workspace-prune-job conn)))))))))
  (it "excludes candidates with cancellation or unrelated deletion reservations"
    (dolist (reason '(:cancellation-pending :deletion-pending))
      (with-workspace-prune-fixture (conn worktrees preflights deletes)
        (let* ((worktree (first worktrees))
               (key (nerimux::%worktree-delete-key worktree)))
          (ecase reason
            (:cancellation-pending
             (setf (gethash (nerimux::%workspace-cancel-key
                             (nerimux/workspace-model:worktree-path worktree))
                            nerimux::*workspace-cancel-reservations*) t))
            (:deletion-pending
             (setf (gethash key nerimux::*worktree-delete-reservations*)
                   (nerimux::make-worktree-delete-reservation
                    :key key :worktree worktree))))
          (nerimux::%client-prune-workspaces conn)
          (expect (null preflights))
          (expect (null deletes))
          (expect (eq reason
                      (third (first (nerimux::workspace-prune-job-results
                                      (nerimux::client-conn-workspace-prune-job conn))))))))))
  (it "disconnect settles a confirming prune and records queued cancellation"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (nerimux::%client-prune-workspaces conn :all t)
      (funcall (getf (cdr (first preflights)) :on-complete)
               (nerimux/vcs::make-worktree-prune-snapshot
                :changed-files '((:modified . "file"))))
      (expect (eq :confirm (nerimux::client-conn-modal conn)))
      (setf nerimux::*clients* nil)
      (nerimux::%cancel-client-workspace-prune conn)
      (expect (null (nerimux::client-conn-modal conn)))
      (expect (= 2 (count :cancelled
                          (nerimux::workspace-prune-job-results
                           (nerimux::client-conn-workspace-prune-job conn))
                          :key #'second)))))
  (it "rejects a pending job, an active modal, and an empty selection"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (nerimux::%client-prune-workspaces conn)
      (setf (nerimux::client-conn-message-log conn) nil)
      (nerimux::%client-prune-workspaces conn)
      (expect (search "workspace prune already pending"
                      (first (nerimux::client-conn-message-log conn)))))
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (setf (nerimux::client-conn-modal conn) :picker)
      (nerimux::%client-prune-workspaces conn)
      (expect (search "workspace prune already pending"
                      (first (nerimux::client-conn-message-log conn)))))
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (setf (nerimux::client-conn-selected-worktree conn) nil)
      (nerimux::%client-prune-workspaces conn)
      (expect (search "no workspace selected"
                      (first (nerimux::client-conn-message-log conn))))))
  (it "restarts pruning after a terminal job instead of treating it as pending"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (setf (nerimux::client-conn-workspace-prune-job conn)
            (nerimux::make-workspace-prune-job
             :conn conn :state :succeeded :results '(("prune-a" :removed))))
      (nerimux::%client-prune-workspaces conn)
      (expect (= 1 (length preflights)))
      (expect (some (lambda (message)
                      (search "workspace prune queued" message))
                    (nerimux::client-conn-message-log conn)))))
  (it "path mutation during preflight excludes stale authorization"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (nerimux::%client-prune-workspaces conn)
      (setf (nerimux/workspace-model:worktree-path (first worktrees)) "/prune-fixture/replaced")
      (funcall (getf (cdr (first preflights)) :on-complete)
               (nerimux/vcs::make-worktree-prune-snapshot))
      (expect (null deletes))
      (expect (eq :stale-workspace
                  (third (first (nerimux::workspace-prune-job-results
                                  (nerimux::client-conn-workspace-prune-job conn))))))))
  (it "a missing workspace is removed without a preflight and a locked one is excluded"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (setf (nerimux/workspace-model:worktree-missing-p (first worktrees)) t
            (nerimux/workspace-model:worktree-locked-p (second worktrees)) t)
      (nerimux::%client-prune-workspaces conn :all t)
      (expect (null preflights))
      (expect (= 1 (length deletes)))
      (expect (eq (first worktrees) (caar deletes)))
      (funcall (getf (cdar deletes) :on-result)
               (nerimux/vcs::make-worktree-delete-result :removed-p t))
      (let ((results (nerimux::workspace-prune-job-results
                      (nerimux::client-conn-workspace-prune-job conn))))
        (expect (equal '(:excluded :removed) (mapcar #'second results)))
        (expect (equal '(:locked nil) (mapcar #'third results))))))

  (it "ignores stale delete callbacks and settles cancellation or exclusion"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (let ((job (nerimux::make-workspace-prune-job :conn conn)))
        (expect (null
                 (nerimux::%workspace-prune-delete
                  job (nerimux::make-worktree-delete-reservation)
                  (nerimux/vcs::make-worktree-prune-snapshot)))))
      (nerimux::%client-prune-workspaces conn)
      (let* ((job (nerimux::client-conn-workspace-prune-job conn))
             (reservation (nerimux::workspace-prune-job-reservation job)))
        (setf (nerimux::workspace-prune-job-cancelled-p job) t)
        (nerimux::%workspace-prune-delete
         job reservation (nerimux/vcs::make-worktree-prune-snapshot))
        (expect (eq :cancelled
                    (second (first (nerimux::workspace-prune-job-results job)))))))
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (nerimux::%client-prune-workspaces conn)
      (let* ((job (nerimux::client-conn-workspace-prune-job conn))
             (worktree (nerimux::workspace-prune-job-current job))
             (reservation (nerimux::workspace-prune-job-reservation job)))
        (setf (gethash (nerimux::%workspace-cancel-key
                        (nerimux/workspace-model:worktree-path worktree))
                       nerimux::*workspace-cancel-reservations*) t)
        (nerimux::%workspace-prune-delete
         job reservation (nerimux/vcs::make-worktree-prune-snapshot))
        (expect (eq :excluded
                    (second (first (nerimux::workspace-prune-job-results job))))))))

  (it "records queued cancellation while advancing a cancelled prune job"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (let ((job (nerimux::make-workspace-prune-job
                  :conn conn :queue (copy-list worktrees) :cancelled-p t)))
        (setf (nerimux::workspace-prune-job-directory-identities job)
              (make-hash-table :test #'equal))
        (nerimux::%workspace-prune-next job)
        (expect (= 2 (count :cancelled
                             (nerimux::workspace-prune-job-results job)
                             :key #'second)))
        (expect (eq :succeeded (nerimux::workspace-prune-job-state job))))))

(it "derives a directory identity from the real worktree path"
  (let ((worktree (nerimux/workspace-model:make-worktree
                   :path (namestring (truename ".")))))
    (expect (nerimux::%workspace-prune-directory-identity worktree)))))

(defun %expect-attached-worktree-delete (view modal target connected session-p blocked)
  (dolist (force '(nil t))
    (with-fake-session (session :nwindows 2 :npanes 2)
      (let* ((display-window (first (nerimux/session:session-windows session)))
             (focus-window (second (nerimux/session:session-windows session)))
             (focus (nerimux/window:window-active-pane focus-window))
             (display (second (nerimux/window:window-panes display-window)))
             (stdin (make-pane :id 99 :fd -1))
             (pane (ecase target
                     (:focus focus)
                     (:display display)
                     ((:stdin :history) stdin)))
             (worktree (nerimux/workspace-model:make-worktree
                        :id "attached" :path "/tmp/attached"))
             (requester (%make-test-conn))
             (observer (%make-test-conn))
             (unrelated (when (and (not blocked) session-p
                                   (not (eq target :display)))
                          (%make-test-conn)))
             (nerimux::*clients* (append (if connected
                                             (list requester observer)
                                             (list requester))
                                         (when unrelated (list unrelated))))
             (nerimux::*server-sessions* (when session-p (list (cons "test" session))))
             (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
             (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (calls nil))
        (unwind-protect
             (progn
               (nerimux/session:session-select-window session display-window)
               (dolist (window (nerimux/session:session-windows session))
                 (dolist (item (nerimux/window:window-panes window))
                   (setf (nerimux/pane:pane-fd item) -1)))
               (if (eq target :history)
                   (setf (nerimux/workspace-model:worktree-agent-pane worktree) pane)
                   (nerimux/pane:worktree-add-pane worktree pane))
               (setf (nerimux::client-conn-view requester) :repolist
                     (nerimux::client-conn-view observer) view
                     (nerimux::client-conn-modal observer) modal
                     (nerimux::client-conn-focus observer) focus
                     (nerimux::client-conn-stdin-target observer)
                     (if (eq modal :scrollback)
                         display
                         (when (member target '(:stdin :history)) stdin))
                     (fdefinition 'nerimux/vcs:vcs-package-available-p) (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received &key force on-complete on-error on-result callback-dispatch)
                       (declare (ignore on-complete on-error on-result callback-dispatch))
                       (push (list received force) calls)
                       t))
               (when unrelated
                 (setf (nerimux::client-conn-view unrelated) :pane
                       (nerimux::client-conn-focus unrelated) display)
                 (expect (not (member pane (nerimux/window:window-panes display-window))))
                 (expect (not (eq pane (nerimux::%resolve-client-focus-pane
                                        session nil unrelated)))))
               (nerimux::%set-client-selected-tree-object requester worktree)
               (expect (not (nerimux/pane:pane-live-p pane)))
               (expect (not (eq display-window focus-window)))
               (expect (not (eq display focus)))
               (expect (eq focus (nerimux::%resolve-client-focus-pane session nil observer)))
               (nerimux::%client-delete-worktree
                requester nil (if force '("--confirm" "--force") '("--confirm")))
               (if blocked
                   (progn
                     (expect (null calls))
                     (expect (string=
                              "worktree delete requires detaching its connected clients"
                              (first (nerimux::client-conn-message-log requester))))
                     (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*))))
                   (expect (equal (list (list worktree force)) calls)))
               (expect (eq worktree (nerimux::client-conn-selected-worktree requester)))
               (expect (not (nerimux/pane:pane-live-p pane)))
               (expect (eq pane (if (eq target :history)
                                   (nerimux/workspace-model:worktree-agent-pane worktree)
                                   (first (nerimux/workspace-model:worktree-panes worktree))))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn))))))

(defun %expect-pending-worktree-delete-picker (pending-p)
  (with-fake-session (session :nwindows 2)
    (let* ((organization (nerimux/workspace-model:make-organization :id "org"))
           (repository (nerimux/workspace-model:make-repository
                        :id "repo" :organization organization))
           (worktree (nerimux/workspace-model:make-worktree
                      :id "pending-feature" :repository repository
                      :path "/tmp/pending-feature" :branch "pending-feature"))
           (original-window (first (nerimux/session:session-windows session)))
           (target-window (second (nerimux/session:session-windows session)))
           (original-pane (nerimux/window:window-active-pane original-window))
           (target-pane (nerimux/window:window-active-pane target-window))
           (conn (%make-test-conn))
           (nerimux::*clients* (list conn))
           (nerimux::*server-sessions* (list (cons "test" session)))
           (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
           (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
           (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
           (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
           (calls nil)
           (completion nil))
      (unwind-protect
           (progn
             (nerimux/workspace-model:organization-add-repository organization repository)
             (nerimux/workspace-model:repository-add-worktree repository worktree)
             (nerimux/pane:worktree-add-pane worktree target-pane)
             (nerimux/session:session-select-window session original-window)
             (setf (nerimux/pane:pane-fd target-pane) -1
                   (nerimux::client-conn-view conn) :repolist
                   (nerimux::client-conn-focus conn) original-pane
                   (fdefinition 'nerimux/vcs:vcs-package-available-p) (lambda () t)
                   (fdefinition 'nerimux/vcs:delete-worktree-async)
                   (lambda (received &key force on-complete on-error on-result callback-dispatch)
                     (declare (ignore force on-complete on-error callback-dispatch))
                     (push received calls)
                     (setf completion on-result)
                     t))
             (nerimux::%set-client-selected-tree-object conn worktree)
             (expect (not (nerimux/pane:pane-live-p target-pane)))
             (expect (not (eq original-window target-window)))
             (when pending-p
               (nerimux::%client-delete-worktree conn nil '("--confirm"))
               (expect (equal (list worktree) calls))
               (expect (functionp completion)))
             (nerimux::%set-client-modal conn :picker)
             (setf (nerimux::client-conn-picker-items conn)
                   (nerimux/picker:build-global-picker-items (list organization))
                   (nerimux::client-conn-picker-query conn) "pending-feature")
             (expect (eq worktree
                         (nerimux::%picker-item-worktree
                          (nerimux::%picker-selected-item conn))))
             (expect (eq target-pane (nerimux::%client-worktree-pane session worktree)))
             (if pending-p
                 (progn
                   (nerimux::%select-client-picker-item session conn)
                   (expect (eq original-window
                               (nerimux/session:session-active-window session)))
                   (expect (eq original-pane (nerimux::client-conn-focus conn)))
                   (expect (eq :repolist (nerimux::client-conn-view conn))))
                 (progn
                   (expect (nerimux::%select-client-picker-item session conn))
                   (expect (eq target-window
                               (nerimux/session:session-active-window session)))
                   (expect (eq target-pane (nerimux::client-conn-focus conn)))
                   (expect (eq :pane (nerimux::client-conn-view conn)))
                   (expect (null (nerimux::client-conn-modal conn)))
                   (expect (null calls)))))
        (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
              (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

(describe "server-multi-suite"

  (it "pending-worktree-delete keys survive model reconstruction and release only their owner"
    (let* ((nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
           (first (nerimux/workspace-model:make-worktree :id "old" :path "/tmp/pending-model"
                   :repository (nerimux/workspace-model:make-repository :specification "owner/project")))
           (second (nerimux/workspace-model:make-worktree :id "new" :path "/tmp/pending-model"
                    :repository (nerimux/workspace-model:make-repository :specification "owner/project")))
           (unrelated (nerimux/workspace-model:make-worktree :id "other" :path "/tmp/pending-model"
                       :repository (nerimux/workspace-model:make-repository :specification "owner/other")))
           (key (nerimux::%worktree-delete-key first))
           (owner (nerimux::make-worktree-delete-reservation :key key :worktree first))
           (other (nerimux::make-worktree-delete-reservation :key key :worktree second)))
      (setf (gethash key nerimux::*worktree-delete-reservations*) owner)
      (expect (nerimux::%worktree-delete-pending-p second))
      (expect (not (nerimux::%worktree-delete-pending-p unrelated)))
      (nerimux::%finish-worktree-delete other nil)
      (expect (eq owner (gethash key nerimux::*worktree-delete-reservations*)))
      (nerimux::%finish-worktree-delete owner nil)
      (expect (not (nerimux::%worktree-delete-pending-p second)))))

  (it "pending-worktree-delete detaches captured dead panes after snapshot unlinking"
    (with-fake-session (session :nwindows 2 :npanes 1)
      (let* ((nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
             (nerimux::*server-sessions* (list (cons "test" session)))
             (window (second (nerimux/session:session-windows session)))
             (pane (nerimux/window:window-active-pane window))
             (unrelated (nerimux/window:window-active-pane
                         (first (nerimux/session:session-windows session))))
             (agent (make-pane :id 99 :fd -1))
             (worktree (nerimux/workspace-model:make-worktree :id "gone" :path "/tmp/gone"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (key (nerimux::%worktree-delete-key worktree))
             (owner (nerimux::make-worktree-delete-reservation
                     :key key :worktree worktree :panes (list pane agent))))
        (nerimux/pane:worktree-add-pane worktree pane)
        (setf (nerimux/pane:pane-fd pane) -1
              (nerimux/pane:pane-worktree pane) nil
              (nerimux/pane:pane-fd unrelated) 42
              (nerimux/workspace-model:worktree-agent-pane worktree) agent
              (nerimux::client-conn-focus conn) pane
              (nerimux::client-conn-stdin-target conn) agent
              (nerimux::client-conn-selected-worktree conn) worktree
              (gethash key nerimux::*worktree-delete-reservations*) owner)
        (nerimux::%finish-worktree-delete owner t)
        (expect (null (nerimux/pane:pane-window pane)))
        (expect (not (member window (nerimux/session:session-windows session))))
        (expect (null (nerimux::client-conn-focus conn)))
        (expect (null (nerimux::client-conn-stdin-target conn)))
        (expect (null (nerimux::client-conn-selected-worktree conn)))
        (expect (null (nerimux/workspace-model:worktree-agent-pane worktree)))
        (expect (nerimux/pane:pane-live-p unrelated))
        (expect (nerimux/pane:pane-window unrelated))
        (nerimux::%finish-worktree-delete owner nil)
        (expect (eq owner (gethash key nerimux::*worktree-delete-reservations*))))))

  (it "pending-worktree-delete-keeps-live-panes-and-nonempty-windows"
    (with-fake-session (session :nwindows 1 :npanes 2)
      (let* ((nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
             (nerimux::*server-sessions* (list (cons "test" session)))
             (window (first (nerimux/session:session-windows session)))
             (panes (nerimux/window:window-panes window))
             (dead (first panes))
             (live (second panes))
             (worktree (nerimux/workspace-model:make-worktree :id "partly-gone"
                                                               :path "/tmp/partly-gone"))
             (key (nerimux::%worktree-delete-key worktree))
             (owner (nerimux::make-worktree-delete-reservation
                     :key key :worktree worktree :panes (list dead live))))
        (nerimux/pane:worktree-add-pane worktree dead)
        (nerimux/pane:worktree-add-pane worktree live)
        (setf (nerimux/pane:pane-fd dead) -1
              (nerimux/pane:pane-worktree dead) nil
              (nerimux/pane:pane-fd live) 42
              (gethash key nerimux::*worktree-delete-reservations*) owner)
        (let ((nerimux/ports:*resize-pty*
                (lambda (fd rows cols)
                  (declare (ignore fd rows cols)))))
          (nerimux::%finish-worktree-delete owner t))
        (expect (null (nerimux/pane:pane-window dead)))
        (expect (eq window (nerimux/pane:pane-window live)))
        (expect (equal (list live) (nerimux/window:window-panes window)))
        (expect (member window (nerimux/session:session-windows session)))
        (expect (equal (list live)
                       (nerimux/workspace-model:worktree-panes worktree))))))

  (it "pending-worktree-delete removed markers recover only when the directory returns"
    (let* ((nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
           (worktree (nerimux/workspace-model:make-worktree :id "recreated" :path "/tmp/recreated"))
           (key (nerimux::%worktree-delete-key worktree))
           (owner (nerimux::make-worktree-delete-reservation
                   :key key :worktree worktree :phase :removed))
           (probe (fdefinition 'uiop:directory-exists-p))
           (exists nil))
      (unwind-protect
           (progn
             (setf (gethash key nerimux::*worktree-delete-reservations*) owner
                   (fdefinition 'uiop:directory-exists-p)
                   (lambda (path) (expect (equal path "/tmp/recreated")) exists))
             (expect (nerimux::%worktree-delete-pending-p worktree))
             (setf exists t)
             (expect (not (nerimux::%worktree-delete-pending-p worktree)))
             (expect (zerop (hash-table-count nerimux::*worktree-delete-reservations*))))
        (setf (fdefinition 'uiop:directory-exists-p) probe))))

  (it "pending-worktree-delete prevents picker reattachment to an existing pane"
    (%expect-pending-worktree-delete-picker t))

  (it "pending-worktree-delete permits picker attachment without a pending delete"
    (%expect-pending-worktree-delete-picker nil))

  (it "attached-worktree-delete protects actual input and displayed panes even with force"
    (dolist (case '((:pane nil :focus)
                    (:pane nil :display)
                    (:pane nil :stdin)
                    (:pane nil :history)
                    (:pane :help :focus)
                    (:pane :confirm :display)
                    (:pane :scrollback :focus)
                    (:unknown nil :focus)
                    (:repolist :picker :display)
                    (:status :picker :display)))
      (destructuring-bind (view modal target) case
        (%expect-attached-worktree-delete view modal target t t t))))

  (it "attached-worktree-delete permits remembered and disconnected attachments"
    (dolist (case '((:repolist nil :focus t)
                    (:status nil :focus t)
                    (:repolist nil :stdin t)
                    (:status nil :stdin t)
                    (:status :help :focus t)
                    (:repolist :picker :focus t)
                    (:pane nil :focus nil)
                    (:pane nil :display nil)))
      (destructuring-bind (view modal target connected) case
        (%expect-attached-worktree-delete view modal target connected t nil))))

  (it "attached-worktree-delete permits overview deletion without a session"
    (%expect-attached-worktree-delete :repolist nil :focus t nil nil))

  (it "overview-worktree-delete-protects-live-panes-even-with-force"
    (dolist (pane-state '(:live :dead :none))
      (dolist (force '(nil t))
        (with-fake-session (s)
          (let* ((worktree
                   (nerimux/workspace-model:make-worktree
                    :id "feature" :path "/tmp/feature" :branch "feature/test"))
                 (pane (unless (eq pane-state :none)
                         (make-pane :id 99 :fd (if (eq pane-state :live) 42 -1))))
                 (conn (%make-test-conn))
                 (nerimux::*clients* (list conn))
                 (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
                 (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
                 (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
                 (calls nil))
            (unwind-protect
                 (progn
                   (when pane
                     (nerimux/pane:worktree-add-pane worktree pane))
                   (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                         (lambda () t)
                         (fdefinition 'nerimux/vcs:delete-worktree-async)
                         (lambda (received-worktree &key force on-complete on-result
                                   on-error callback-dispatch)
                           (declare (ignore on-complete on-error on-result callback-dispatch))
                           (push (list received-worktree force) calls)
                           t))
                   (setf (nerimux::client-conn-view conn) :repolist)
                   (nerimux::%set-client-selected-tree-object conn worktree)
                   (nerimux::%handle-multi-key-message s conn #(58))
                   (nerimux::%handle-multi-key-message
                    s conn
                    (cl-codec-kit:string-to-octets
                     (if force "wt-delete --confirm --force" "wt-delete --confirm")
                     :encoding :utf-8))
                   (nerimux::%handle-multi-key-message s conn #(13))
                   (if (eq pane-state :live)
                       (progn
                         (expect (null calls))
                         (expect (string=
                                  "close its 1 pane first (C-q x)"
                                  (first (nerimux::client-conn-message-log conn))))
                         (expect (nerimux/pane:pane-live-p pane)))
                       (expect (equal (list (list worktree force)) calls)))
                   (expect (eq worktree
                               (nerimux::client-conn-selected-worktree conn)))
                   (expect (equal (when pane (list pane))
                                  (nerimux/workspace-model:worktree-panes worktree))))
              (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                    (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))))

  (it "live-pane-delete-worker-error-clears-ui-refreshing"
    (with-fake-session (s)
      (let* ((repository (nerimux/workspace-model:make-repository
                          :id "repo" :specification "workspace-owner/repo"))
             (main-worktree (nerimux/workspace-model:make-worktree
                             :id "main" :repository repository
                             :path "/tmp/main" :branch "main"))
             (worktree (nerimux/workspace-model:make-worktree
                        :id "feature" :repository repository
                        :path "/tmp/feature" :branch "feature/test"))
             (pane (make-pane :id 99 :fd -1))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux::*main-thread-callbacks* nil)
             (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
             (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (dispatched 0))
        (unwind-protect
             (progn
               (nerimux/workspace-model:repository-add-worktree repository main-worktree)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (nerimux/pane:worktree-add-pane worktree pane)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree &key force on-complete on-error on-result
                               callback-dispatch)
                       (expect (eq worktree received-worktree))
                       (expect force)
                       (setf (nerimux/pane:pane-fd pane) 42)
                       (let ((pending nil))
                         (sb-thread:join-thread
                          (funcall delete-fn received-worktree
                                   :force force :on-complete on-complete :on-result on-result
                                   :on-error on-error
                                   :callback-dispatch
                                   (lambda (thunk) (push thunk pending))))
                         (dolist (thunk (nreverse pending))
                           (incf dispatched)
                           (funcall callback-dispatch thunk)))))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn (cl-codec-kit:string-to-octets
                        "wt-delete --confirm --force" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (= 1 dispatched))
               (expect (= 1 (hash-table-count nerimux::*workspace-refreshing-ids*)))
               (expect (= 1 (length nerimux::*main-thread-callbacks*)))
               (nerimux::%drain-main-thread-callbacks)
               (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
               (expect (= 1 (hash-table-count nerimux::*workspace-stale-ids*)))
               (expect (string=
                        "worktree delete failed: Close the worktree's live panes before deleting it."
                        (first (nerimux::client-conn-message-log conn))))
               (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))
               (expect (equal (list worktree main-worktree)
                              (nerimux/workspace-model:repository-worktrees repository)))
               (expect (equal (list pane)
                              (nerimux/workspace-model:worktree-panes worktree)))
               (expect (nerimux/pane:pane-live-p pane)))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

  (it "workspace-job worktree-create-now-reports-synchronous-vcs-errors"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo" :organization organization
              :specification "github.com/team/repo"))
           (conn (%make-test-conn))
           (create-fn (fdefinition 'nerimux/vcs:create-worktree-async)))
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux/vcs:create-worktree-async)
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (error "synthetic create failure")))
             (expect (nerimux::%client-create-worktree-now
                      repository "feature/test" conn nil))
             (expect (eq :failed (nerimux::workspace-operation-job-state
                                  (gethash '(:repository "repo" :create)
                                           nerimux::*workspace-operation-jobs*)))))
        (setf (fdefinition 'nerimux/vcs:create-worktree-async) create-fn))))

  (it "worktree-create-now-opens-a-shell-for-the-named-worktree"
    (with-fake-session (session)
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
                :path "/tmp/feature" :branch "feature/test"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (create-fn (fdefinition 'nerimux/vcs:create-worktree-async))
             (focus-fn (fdefinition 'nerimux::%open-client-worktree-pane))
             (started nil)
             (focused nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:create-worktree-async)
                     (lambda (received-repository &key on-start on-complete
                               &allow-other-keys)
                       (expect (eq repository received-repository))
                       (when on-start
                         (funcall on-start)
                         (setf started t))
                       (funcall on-complete worktree)
                       t)
                     (fdefinition 'nerimux::%open-client-worktree-pane)
                     (lambda (received-session received-conn received-worktree)
                       (setf focused (list received-session received-conn received-worktree))
                       t))
               (expect (nerimux::%client-create-worktree-now
                        repository "feature/test" conn session))
               (expect started)
               (expect (equal (list session conn worktree) focused))
               (expect (eq worktree
                           (nerimux::client-conn-selected-worktree conn)))
               (expect (string= "worktree created: /tmp/feature"
                                (first (nerimux::client-conn-message-log conn)))))
          (setf (fdefinition 'nerimux/vcs:create-worktree-async) create-fn
                (fdefinition 'nerimux::%open-client-worktree-pane) focus-fn)))))

  (it "overview-worktree-prune-confirm-without-confirm-is-rejected"
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
                :id "stale"
                :repository repository
                :path "/tmp/stale"
                :branch "feature/stale"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (prune-fn (fdefinition 'nerimux/vcs:prune-worktrees-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error
                                callback-dispatch)
                       (declare (ignore verbose on-error callback-dispatch))
                       (setf call (list received-repository dry-run))
                       (funcall on-complete "")
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-prune-confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (string= "wt-prune-confirm: add --confirm to run"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (equal (list worktree)
                              (nerimux/workspace-model:repository-worktrees repository)))
               (expect (nerimux::%client-ui-keys-p conn)))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  (it "overview-worktree-prune-confirm-without-preview-runs"
    ;; `wt-prune-confirm --confirm\' used to call raw `git worktree prune\',
    ;; then later ran the same workspace prune `w P\' does at once with no
    ;; confirm view; it now opens that same confirm view, and its eligibility
    ;; count -- not the prune worker's own per-worktree classification -- is
    ;; what decides whether anything is offered to prune at all. The only
    ;; worktree here is the repository's primary, always excluded, so nothing
    ;; is eligible and the confirm view never opens.
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
                :id "stale"
                :repository repository
                :path "/tmp/stale"
                :branch "feature/stale"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux::*server-sessions* nil)
             (nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
             (nerimux::*workspace-cancel-reservations* (make-hash-table :test #'equal))
             (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () t))
             (nerimux/vcs:workspace-organizations (lambda () (list organization))))
          (setf (nerimux::client-conn-view conn) :repolist)
          (nerimux::%set-client-selected-tree-object conn repository)
          (nerimux::%handle-multi-key-message s conn #(58))
          (nerimux::%handle-multi-key-message
           s conn
           (cl-codec-kit:string-to-octets
            "wt-prune-confirm --confirm" :encoding :utf-8))
          (nerimux::%handle-multi-key-message s conn #(13))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (string= "nothing to prune"
                           (first (nerimux::client-conn-message-log conn))))
          (expect (equal (list worktree)
                         (nerimux/workspace-model:repository-worktrees repository)))
          (expect (null (gethash '(:worktree "stale" :prune)
                                 nerimux::*workspace-operation-jobs*)))
          (expect (nerimux::%client-ui-keys-p conn))))))

  (it "multi-picker-regex-toggle-is-client-local"
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
                :branch "feature/picker"))
             (conn (%make-test-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-query conn) "feature/.+")
        (expect (null (nerimux::client-conn-picker-regex-p conn)))
        (expect (null (nerimux::%client-picker-visible-items conn)))
        (nerimux::%handle-multi-key-message s conn #(18))
        (expect (nerimux::client-conn-picker-regex-p conn))
        (expect (= 1 (length (nerimux::%client-picker-visible-items conn))))
        (expect (nerimux::%handle-client-ui-command
                 s conn :picker-regex "off" nil))
        (expect (null (nerimux::client-conn-picker-regex-p conn)))
        (expect (null (nerimux::%client-picker-visible-items conn))))))

  (it "multi-picker-key-input-filters-by-query-and-selects-worktree"
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
                :branch "feature/picker"))
             (conn (%make-test-conn))
             (pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s))))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux/pane:worktree-add-pane worktree pane)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (loop for character across "feature"
              do (nerimux::%handle-multi-key-message
                  s conn (vector (char-code character))))
        (expect (string= "feature" (nerimux::client-conn-picker-query conn)))
        (expect (equal '(:worktree :pane)
                       (mapcar #'nerimux/picker:picker-item-kind
                               (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq pane (nerimux::client-conn-focus conn))))))

  (it "assignment-guards-pending-delete-and-cancellation-before-showing-assignment"
    (with-loop-state
      (let* ((organization
               (nerimux/workspace-model:make-organization :id "assignment-org"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "assignment-repo" :organization organization))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "assignment-worktree" :repository repository
                :path "/tmp/assignment-worktree" :head "head"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
             (nerimux::*workspace-cancel-reservations* (make-hash-table :test #'equal))
             (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
             (key (nerimux::%worktree-delete-key worktree))
             (cancel-key (nerimux::%workspace-cancel-key
                          (nerimux/workspace-model:worktree-path worktree))))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux::%client-assign-worktree nil conn)
        (expect (string= "select a worktree first"
                         (first (nerimux::client-conn-message-log conn))))
        (setf (nerimux::client-conn-message-log conn) nil
              (nerimux::client-conn-selected-worktree conn) worktree
              (nerimux::client-conn-workspace-assignment conn)
              (nerimux::make-workspace-assignment
               :repository repository :phase :creating))
        (nerimux::%client-assign-worktree nil conn)
        (expect (string= "workspace operation is pending"
                         (first (nerimux::client-conn-message-log conn))))
        (setf (nerimux::client-conn-message-log conn) nil
              (nerimux::client-conn-workspace-assignment conn) nil
              (gethash key nerimux::*worktree-delete-reservations*)
              (nerimux::make-worktree-delete-reservation
               :key key :worktree worktree))
        (nerimux::%client-assign-worktree nil conn)
        (expect (string= "worktree deletion is pending"
                         (first (nerimux::client-conn-message-log conn))))
        (setf (nerimux::client-conn-message-log conn) nil
              (gethash cancel-key nerimux::*workspace-cancel-reservations*) t)
        (remhash key nerimux::*worktree-delete-reservations*)
        (nerimux::%client-assign-worktree nil conn)
        (expect (string= "worktree cancellation is pending"
                         (first (nerimux::client-conn-message-log conn))))
        (setf (nerimux::client-conn-message-log conn) nil)
        (remhash cancel-key nerimux::*workspace-cancel-reservations*)
        (nerimux::%client-assign-worktree nil conn)
        (expect (eq :assigning
                    (nerimux::workspace-assignment-phase
                     (nerimux::client-conn-workspace-assignment conn)))))))

  (it "detached-worktree-create-retains-assignment-after-synchronous-error"
    (with-loop-state
      (let* ((organization
               (nerimux/workspace-model:make-organization :id "create-org"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "create-repo" :organization organization))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
             (calls 0))
        (setf (nerimux::client-conn-workspace-assignment conn)
              (nerimux::make-workspace-assignment
               :repository repository :phase :creating))
        (with-stubbed-fdefinition
            ((nerimux/vcs:create-detached-worktree-async
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (incf calls))))
          (nerimux::%client-create-detached-worktree repository conn nil)
          (expect (zerop calls))
          (expect (string= "finish the pending workspace operation first"
                           (first (nerimux::client-conn-message-log conn)))))
        (setf (nerimux::client-conn-message-log conn) nil
              (nerimux::client-conn-workspace-assignment conn) nil)
        (with-stubbed-fdefinition
            ((nerimux/vcs:create-detached-worktree-async
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error "synthetic detached create failure"))))
          (nerimux::%client-create-detached-worktree repository conn nil))
        (let ((job (gethash '(:repository "create-repo" :create)
                            nerimux::*workspace-operation-jobs*)))
          (expect (eq :failed (nerimux::workspace-operation-job-state job))))
        (expect (eq :retained
                    (nerimux::workspace-assignment-phase
                     (nerimux::client-conn-workspace-assignment conn))))
        (expect (search "workspace create failed: synthetic detached create failure"
                        (first (nerimux::client-conn-message-log conn)))))))

  (it "worktree-delete-settles-asynchronous-and-synchronous-failures"
    (dolist (mode '(:callback :synchronous))
      (with-loop-state
        (let* ((repository
                 (nerimux/workspace-model:make-repository :id "delete-repo"))
               (main-worktree
                 (nerimux/workspace-model:make-worktree
                  :id "delete-main" :repository repository :path "/tmp/delete-main"
                  :branch "main"))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "delete-feature" :repository repository
                  :path "/tmp/delete-feature" :branch "feature/delete"))
               (conn (%make-test-conn))
               (result-callback nil)
               (nerimux::*clients* (list conn))
               (nerimux::*server-sessions* nil)
               (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
               (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
               (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal)))
          (nerimux/workspace-model:repository-add-worktree repository main-worktree)
          (nerimux/workspace-model:repository-add-worktree repository worktree)
          (nerimux::%set-client-selected-tree-object conn worktree)
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () t))
               (nerimux/vcs:delete-worktree-async
                 (lambda (received-worktree &key on-result &allow-other-keys)
                   (expect (eq worktree received-worktree))
                   (if (eq mode :callback)
                       (setf result-callback on-result)
                       (error "synthetic worktree delete failure"))
                   t)))
            (nerimux::%client-delete-worktree conn nil '("--confirm"))
            (when (eq mode :callback)
              (funcall result-callback
                       (nerimux/vcs::make-worktree-delete-result
                        :removed-p nil :error "synthetic worktree delete failure"))))
          (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
          (expect (= 1 (hash-table-count nerimux::*workspace-stale-ids*)))
          (expect (search "worktree delete failed: synthetic worktree delete failure"
                          (first (nerimux::client-conn-message-log conn))))))))

  (it "rejects pending deletion and reports refresh failures"
    (with-loop-state
      (let* ((repository
               (nerimux/workspace-model:make-repository :id "delete-refresh-repo"))
             (main-worktree
               (nerimux/workspace-model:make-worktree
                :id "delete-refresh-main" :repository repository :path "/tmp/delete-refresh-main"
                :branch "main"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "delete-refresh-feature" :repository repository
                :path "/tmp/delete-refresh-feature" :branch "feature/delete-refresh"))
             (conn (%make-test-conn))
             (result-callback nil)
             (nerimux::*clients* (list conn))
             (nerimux::*server-sessions* nil)
             (nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
             (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal)))
        (nerimux/workspace-model:repository-add-worktree repository main-worktree)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (setf (gethash (nerimux::%worktree-delete-key worktree)
                       nerimux::*worktree-delete-reservations*)
              (nerimux::make-worktree-delete-reservation
               :key (nerimux::%worktree-delete-key worktree)
               :worktree worktree))
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () t))
             (nerimux/vcs:delete-worktree-async
               (lambda (received-worktree &key on-result &allow-other-keys)
                 (expect (eq worktree received-worktree))
                 (setf result-callback on-result)
                 t)))
          (nerimux::%client-delete-worktree conn nil '(
            "--confirm"))
          (expect (search "worktree deletion is pending"
                          (first (nerimux::client-conn-message-log conn))))
          (remhash (nerimux::%worktree-delete-key worktree)
                   nerimux::*worktree-delete-reservations*)
          (setf (nerimux::client-conn-message-log conn) nil)
          (nerimux::%client-delete-worktree conn nil '("--confirm"))
          (funcall result-callback
                   (nerimux/vcs::make-worktree-delete-result
                    :removed-p t :refresh-error "synthetic refresh failure")))
        (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
        (expect (= 1 (hash-table-count nerimux::*workspace-stale-ids*)))
        (expect (search "worktree deleted; refresh failed: synthetic refresh failure"
                        (first (nerimux::client-conn-message-log conn)))))))

  (it "workspace-prune-settles-preflight-and-delete-worker-failures"
    (dolist (mode '(:preflight :delete))
      (with-workspace-prune-fixture (conn worktrees preflights deletes)
        (let ((snapshot-complete nil)
              (snapshot-error nil)
              (delete-result nil))
          (with-stubbed-fdefinition
              ((nerimux/vcs:read-worktree-prune-snapshot-async
                 (lambda (worktree &key on-complete on-error &allow-other-keys)
                   (declare (ignore worktree))
                   (setf snapshot-complete on-complete
                         snapshot-error on-error)))
               (nerimux/vcs:delete-worktree-async
                 (lambda (worktree &key on-result &allow-other-keys)
                   (declare (ignore worktree))
                   (setf delete-result on-result))))
            (nerimux::%client-prune-workspaces conn)
            (if (eq mode :preflight)
                (funcall snapshot-error "synthetic preflight failure")
                (progn
                  (funcall snapshot-complete
                           (nerimux/vcs::make-worktree-prune-snapshot
                            :changed-files nil))
                  (funcall delete-result
                           (nerimux/vcs::make-worktree-delete-result
                            :removed-p nil :error "synthetic prune delete failure")))))
          (let ((job (nerimux::client-conn-workspace-prune-job conn)))
            (expect (eq :failed (nerimux::workspace-prune-job-state job)))
            (expect (eq :failed
                        (second (first (nerimux::workspace-prune-job-results job))))))
          (let ((operation
                  (gethash '(:worktree "prune-a" :prune)
                           nerimux::*workspace-operation-jobs*)))
            (expect (eq :failed (nerimux::workspace-operation-job-state operation))))))))

  (it "tracks prune worker starts and synchronous failures"
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (with-stubbed-fdefinition
          ((nerimux/vcs:read-worktree-prune-snapshot-async
             (lambda (worktree &key on-start &allow-other-keys)
               (declare (ignore worktree))
               (funcall on-start)
               (error "synthetic synchronous preflight failure"))))
        (nerimux::%client-prune-workspaces conn))
      (let ((job (nerimux::client-conn-workspace-prune-job conn))
            (operation
              (gethash '(:worktree "prune-a" :prune)
                       nerimux::*workspace-operation-jobs*)))
        (expect (eq :failed (nerimux::workspace-prune-job-state job)))
        (expect (eq :failed (nerimux::workspace-operation-job-state operation)))))
    (with-workspace-prune-fixture (conn worktrees preflights deletes)
      (let ((snapshot-complete nil))
        (with-stubbed-fdefinition
            ((nerimux/vcs:read-worktree-prune-snapshot-async
               (lambda (worktree &key on-start on-complete &allow-other-keys)
                 (declare (ignore worktree))
                 (funcall on-start)
                 (setf snapshot-complete on-complete)))
             (nerimux/vcs:delete-worktree-async
               (lambda (worktree &key on-start &allow-other-keys)
                 (declare (ignore worktree))
                 (funcall on-start)
                 (error "synthetic synchronous delete failure"))))
          (nerimux::%client-prune-workspaces conn)
          (funcall snapshot-complete
                   (nerimux/vcs::make-worktree-prune-snapshot :changed-files nil)))
        (let ((job (nerimux::client-conn-workspace-prune-job conn))
              (operation
                (gethash '(:worktree "prune-a" :prune)
                         nerimux::*workspace-operation-jobs*)))
          (expect (eq :failed (nerimux::workspace-prune-job-state job)))
          (expect (eq :failed (nerimux::workspace-operation-job-state operation))))))))
