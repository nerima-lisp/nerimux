(in-package #:nerimux)

(defun %client-delete-worktree (conn target args)
  (if (not (%client-boolean-option-p args '("--confirm" "confirm")))
      (progn
        (%client-notify conn "worktree delete requires --confirm")
        t)
      (let ((worktree (%client-operation-worktree conn target))
            (force (%client-boolean-option-p args '("--force" "force"))))
        (cond
          ((not worktree)
            (%client-notify conn "worktree delete requires a worktree")
            t)
          ((%worktree-delete-pending-p worktree)
            (%client-notify conn "worktree deletion is pending")
            t)
          ((or (some #'pane-live-p
                     (nerimux/workspace-model:worktree-panes worktree))
               (let ((pane (nerimux/workspace-model:worktree-agent-pane worktree)))
                 (and pane (pane-live-p pane))))
            (%client-notify conn "worktree delete requires closing its live panes")
            t)
          ((%worktree-attached-to-clients-p
            (%attach-target-session) worktree *clients*)
            (%client-notify conn "worktree delete requires detaching its connected clients")
            t)
          ((not (nerimux/vcs:vcs-package-available-p))
            (%client-notify conn "VCS adapter unavailable")
            t)
          (t
            (%client-notify conn
                            (format nil
                                    "deleting worktree ~A"
                                    (nerimux/workspace-model:worktree-path
                                     worktree)))
            (%mark-workspace-refreshing :worktree
                                        (nerimux/workspace-model:worktree-id
                                         worktree))
            (let* ((key (%worktree-delete-key worktree))
                   (reservation
                     (make-worktree-delete-reservation
                      :key key :worktree worktree
                      :panes (remove-duplicates
                              (remove nil
                                      (cons (nerimux/workspace-model:worktree-agent-pane worktree)
                                            (copy-list (nerimux/workspace-model:worktree-panes worktree))))
                              :test #'eq))))
              (setf (gethash key *worktree-delete-reservations*) reservation)
            (flet ((%on-error (condition)
                     (%finish-worktree-delete reservation nil)
                     (%clear-workspace-refreshing :worktree
                                                  (nerimux/workspace-model:worktree-id
                                                   worktree)
                                                  :stale-p
                                                  t)
                     (%client-notify conn
                                     (format nil
                                             "worktree delete failed: ~A"
                                             condition))
                     (%mark-dirty)))
              (handler-case (nerimux/vcs:delete-worktree-async worktree
                                                               :force
                                                               force
                                                               :callback-dispatch
                                                               #'%enqueue-main-thread-callback
                                                               :on-result
                                                               (lambda (result)
                                                                 (block settle
                                                                 (unless (nerimux/vcs:worktree-delete-result-removed-p result)
                                                                   (%on-error (nerimux/vcs:worktree-delete-result-error result))
                                                                   (return-from settle nil))
                                                                 (%finish-worktree-delete reservation t)
                                                                 (%clear-workspace-refreshing
                                                                  :worktree
                                                                  (nerimux/workspace-model:worktree-id
                                                                   worktree)
                                                                  :stale-p (not (null (nerimux/vcs:worktree-delete-result-refresh-error result))))
                                                                 (%refresh-client-picker
                                                                  conn)
                                                                 (%client-notify
                                                                  conn
                                                                  (if (nerimux/vcs:worktree-delete-result-refresh-error result)
                                                                      (format nil "worktree deleted; refresh failed: ~A"
                                                                              (nerimux/vcs:worktree-delete-result-refresh-error result))
                                                                      "worktree deleted"))
                                                                 (%mark-dirty)))
                                                               )
                (error (condition)
                  (%on-error condition)))))
            t)))))

(defmacro %define-worktree-state-operation
    (name operation command progressive complete &rest operation-arguments)
  `(defun ,name (conn target args)
     (%with-client-confirmation (conn args ,command)
       (let ((worktree (%client-operation-worktree conn target)))
         (cond
           ((not worktree)
            (%client-notify conn
                            (format nil "worktree ~A requires a worktree"
                                    ,command))
            t)
           ((not (nerimux/vcs:vcs-package-available-p))
            (%client-notify conn "VCS unavailable")
            t)
           (t
            (%client-notify conn
                            (format nil "~A worktree ~A"
                                    ,progressive
                                    (nerimux/workspace-model:worktree-path
                                     worktree)))
            (%mark-workspace-refreshing
             :worktree
             (nerimux/workspace-model:worktree-id worktree))
            (flet ((%on-error (condition)
                     (%clear-workspace-refreshing
                      :worktree
                      (nerimux/workspace-model:worktree-id worktree)
                      :stale-p
                      t)
                     (%client-notify
                      conn
                      (format nil "worktree ~A failed: ~A"
                              ,command
                              condition))
                     (%mark-dirty)))
              (handler-case
                  (,operation worktree
                              ,@operation-arguments
                              :callback-dispatch
                              #'%enqueue-main-thread-callback
                              :on-complete
                              (lambda (ignored)
                                (declare (ignore ignored))
                                (%clear-workspace-refreshing
                                 :worktree
                                 (nerimux/workspace-model:worktree-id
                                  worktree))
                                (%refresh-client-picker conn)
                                (%client-notify
                                 conn
                                 (format nil "worktree ~A" ,complete))
                                (%mark-dirty))
                              :on-error
                              #'%on-error)
                (error (condition)
                  (%on-error condition))))
            t))))))

(%define-worktree-state-operation
 %client-lock-worktree
 nerimux/vcs:lock-worktree-async
 "lock"
 "locking"
 "locked"
 :reason
 (%client-option-value args '("--reason" "reason")))

(%define-worktree-state-operation
 %client-unlock-worktree
 nerimux/vcs:unlock-worktree-async
 "unlock"
 "unlocking"
 "unlocked")

(defun %client-prune-worktrees (conn target args &key dry-run)
  "Preview or perform a git worktree prune for the target repository.

DRY-RUN must default true at every call site; a caller passes DRY-RUN NIL
only after the user has confirmed a previewed prune, and even then this
function still requires both an explicit --confirm option AND that a dry-run
preview was already shown to CONN for this same repository (tracked via
CLIENT-CONN-PENDING-PRUNE-PREVIEW-REPOSITORY-ID) — so a prune can never be
reached by a single accidental keystroke, a scripted --confirm with no
preview, or a preview of a different repository."
  (if (and (not dry-run)
           (not (%client-boolean-option-p args '("--confirm" "confirm"))))
      (progn
        (%client-notify conn "worktree prune requires --confirm")
        t)
      (let ((repository (%client-selected-repository conn target))
            (verbose (%client-boolean-option-p args '("--verbose" "verbose"))))
        (cond
          ((not repository)
            (%client-notify conn "worktree prune requires a repository")
            t)
          ((and (not dry-run)
                (not
                 (equal (client-conn-pending-prune-preview-repository-id conn)
                        (nerimux/workspace-model:repository-id repository))))
            (%client-notify conn
                            "worktree prune requires a preview first: run wt-prune, then wt-prune-confirm --confirm")
            t)
          ((not (nerimux/vcs:vcs-package-available-p))
          (%client-notify conn "VCS unavailable")
            t)
          (t
            (%client-notify conn
                            (if dry-run
                                "previewing worktree prune"
                                "pruning worktrees"))
            (%mark-workspace-refreshing :repository
                                        (nerimux/workspace-model:repository-id
                                         repository))
            (flet ((%on-error (condition)
                     (%clear-workspace-refreshing :repository
                                                  (nerimux/workspace-model:repository-id
                                                   repository)
                                                  :stale-p
                                                  t)
                     (%client-notify conn
                                     (format nil
                                             "worktree prune failed: ~A"
                                             condition))
                     (%mark-dirty)))
              (handler-case (nerimux/vcs:prune-worktrees-async repository
                                                               :dry-run
                                                               dry-run
                                                               :verbose
                                                               verbose
                                                               :callback-dispatch
                                                               #'%enqueue-main-thread-callback
                                                               :on-complete
                                                               (lambda (output)
                                                                 (%clear-workspace-refreshing
                                                                  :repository
                                                                  (nerimux/workspace-model:repository-id
                                                                   repository))
                                                                 (setf (client-conn-pending-prune-preview-repository-id
                                                                        conn) (and
                                                                               dry-run
                                                                               (nerimux/workspace-model:repository-id
                                                                                repository)))
                                                                 (%refresh-client-picker
                                                                  conn)
                                                                 (%client-notify
                                                                  conn
                                                                  (if dry-run
                                                                      (format
                                                                       nil
                                                                       "worktree prune preview: ~A"
                                                                       (if (and
                                                                            (stringp
                                                                             output)
                                                                            (plusp
                                                                             (length
                                                                              output)))
                                                                           output
                                                                           "nothing to prune"))
                                                                      "worktrees pruned"))
                                                                 (%mark-dirty))
                                                               :on-error
                                                               #'%on-error)
                (error (condition)
                  (%on-error condition))))
            t)))))


(defun %assignment-current-worktree (state)
  (let* ((repository (%workspace-find-repository
                      (nerimux/workspace-model:repository-local-path
                       (workspace-assignment-repository state))))
         (worktree (and repository
                        (nerimux/workspace-model:repository-worktree-by-path
                         repository (workspace-assignment-path state)))))
    (and worktree
         (equal (workspace-assignment-worktree-id state)
                (nerimux/workspace-model:worktree-id worktree))
         worktree)))


(defun %show-worktree-assignment (conn state)
  (let ((view (nerimux/renderer:make-transient-view
               :title "Assign agent"
               :subtitle (workspace-assignment-path state)
               :arguments nil
               :actions '((#\x "Codex" nil) (#\c "Claude" nil)))))
    (setf (workspace-assignment-phase state) :assigning
          (workspace-assignment-view state) view
          (client-conn-workspace-assignment conn) state
          (client-conn-transient-view conn) view)
    (%set-client-view conn :repolist)
    (%set-client-modal conn :transient)
    (%mark-dirty)
    t))


(defun %client-assign-worktree (session conn &optional worktree)
  (declare (ignore session))
  (let* ((worktree (or worktree (client-conn-selected-worktree conn)))
         (previous (client-conn-workspace-assignment conn)))
    (cond
      ((and previous (member (workspace-assignment-phase previous)
                             '(:creating :deleting)))
       (%client-notify conn "workspace operation is pending"))
      ((null worktree) (%client-notify conn "select a worktree first"))
      ((%worktree-delete-pending-p worktree)
       (%client-notify conn "worktree deletion is pending"))
      ((%worktree-cancel-pending-p worktree)
       (%client-notify conn "worktree cancellation is pending"))
      (t
       (%show-worktree-assignment
        conn (make-workspace-assignment
              :repository (nerimux/workspace-model:worktree-repository worktree)
              :path (worktree-path worktree)
              :head (nerimux/workspace-model:worktree-head worktree)
              :model-head (nerimux/workspace-model:worktree-head worktree)
              :worktree-id (nerimux/workspace-model:worktree-id worktree))))))
  t)


(defun %client-create-detached-worktree (repository conn session)
  (declare (ignore session))
  (let ((previous (client-conn-workspace-assignment conn)))
    (when (and previous (member (workspace-assignment-phase previous)
                                '(:creating :assigning :deleting)))
      (%client-notify conn "finish the pending workspace operation first")
      (return-from %client-create-detached-worktree t)))
  (let ((state (make-workspace-assignment :repository repository))
        (job (%workspace-job-begin :repository (repository-id repository) :create repository)))
    (setf (client-conn-workspace-assignment conn) state)
    (%client-notify conn "fetching origin/main and creating workspace")
    (flet ((failed (condition)
             (%workspace-job-update job repository :failed :outcome condition)
             (setf (workspace-assignment-phase state) :retained)
             (%client-notify conn (format nil "workspace create failed: ~A" condition))
             (%mark-dirty)))
      (handler-case
          (nerimux/vcs:create-detached-worktree-async
           repository :callback-dispatch #'%enqueue-main-thread-callback
           :on-start (lambda () (%workspace-job-update job repository :running))
           :on-error #'failed
           :on-complete
           (lambda (receipt)
             (let ((worktree (nerimux/vcs:detached-worktree-result-worktree receipt)))
               (%workspace-job-update
                job repository
                (if (or (null worktree) (nerimux/vcs:detached-worktree-result-refresh-error receipt))
                    :failed :succeeded)
                :outcome (when (or (null worktree) (nerimux/vcs:detached-worktree-result-refresh-error receipt))
                           :created-refresh-failed))
               (setf (workspace-assignment-receipt state) receipt
                     (workspace-assignment-path state)
                     (if worktree
                         (nerimux/workspace-model:worktree-path worktree)
                         (nerimux/vcs:detached-worktree-result-path receipt))
                     (workspace-assignment-head state)
                     (nerimux/vcs:detached-worktree-result-head receipt)
                     (workspace-assignment-model-head state)
                     (and worktree (nerimux/workspace-model:worktree-head worktree))
                     (workspace-assignment-worktree-id state)
                     (and worktree (nerimux/workspace-model:worktree-id worktree))
                     (workspace-assignment-phase state) :retained)
               (when (and (%client-live-p conn)
                          (eq state (client-conn-workspace-assignment conn)))
                 (if (or (null worktree)
                         (nerimux/vcs:detached-worktree-result-refresh-error receipt))
                     (%client-notify
                      conn (format nil "workspace created at ~A; refresh failed: ~A"
                                   (workspace-assignment-path state)
                                   (nerimux/vcs:detached-worktree-result-refresh-error receipt)))
                     (progn
                       (%set-client-selected-worktree conn worktree)
                       (%show-worktree-assignment conn state))))
               (%mark-dirty))))
        (error (condition) (failed condition)))))
  t)


(defun %check-assignment-cancellation (state &key git-p)
  (let ((worktree (%assignment-current-worktree state)))
    (unless (and (workspace-assignment-receipt state)
                 worktree
                 (equal (workspace-assignment-model-head state)
                        (nerimux/workspace-model:worktree-head worktree))
                 (null (nerimux/workspace-model:worktree-branch worktree))
                 (null (worktree-panes worktree))
                 (not (worktree-running-agent-p worktree))
                 (not (nerimux/workspace-model:worktree-dirty-p worktree))
                 (not (nerimux/workspace-model:worktree-locked-p worktree))
                 (not (worktree-missing-p worktree)))
      (error "workspace changed or is in use; cancellation refused"))
    (when git-p
      (let ((handle (vcs-kit:make-repository
                     (nerimux/workspace-model:worktree-path worktree))))
        (unless (and (equal (workspace-assignment-head state)
                            (vcs-kit:git-rev-parse-value handle "--verify" "HEAD"))
                     (equal "HEAD"
                            (vcs-kit:git-rev-parse-value handle "--abbrev-ref" "HEAD")))
          (error "workspace Git identity changed; cancellation refused"))))
    worktree))


(defun %cancel-worktree-assignment (conn state)
  (%close-client-transient conn)
  (setf (workspace-assignment-phase state) :retained)
  (unless (workspace-assignment-receipt state)
    (return-from %cancel-worktree-assignment t))
  (let* ((path (workspace-assignment-path state))
         (key (%workspace-cancel-key path)))
    (labels ((release-reservation ()
               (when (eq state (gethash key *workspace-cancel-reservations*))
                 (remhash key *workspace-cancel-reservations*)))
             (failed (condition)
               (release-reservation)
               (setf (workspace-assignment-phase state) :retained)
               (%client-notify conn
                               (format nil "workspace cancellation not confirmed at ~A: ~A"
                                       path condition))
               (%mark-dirty)))
      (handler-case
          (let ((worktree (%check-assignment-cancellation state)))
            (when (gethash key *workspace-cancel-reservations*)
              (error "workspace cancellation is already pending"))
            (setf (gethash key *workspace-cancel-reservations*) state
                  (workspace-assignment-phase state) :deleting)
            (nerimux/vcs:delete-worktree-async
             worktree :force nil
             :before-delete (lambda () (%check-assignment-cancellation state :git-p t))
             :callback-dispatch #'%enqueue-main-thread-callback
             :on-complete
             (lambda (result)
               (declare (ignore result))
               (release-reservation)
               (setf (workspace-assignment-phase state) :done)
               (%client-notify conn (format nil "cancelled workspace ~A" path))
               (%mark-dirty))
             :on-error #'failed))
        (error (condition) (failed condition)))))
  t)


(defun %handle-worktree-assignment-key (session conn state payload)
  (cond
    ((or (%client-byte-p payload 27) (%client-key-p payload #\q))
     (when (%client-byte-p payload 27) (%client-esc-swallow-start conn))
     (%cancel-worktree-assignment conn state))
    ((or (%client-key-p payload #\x) (%client-key-p payload #\c))
     (let* ((worktree (%assignment-current-worktree state))
            (codex-p (%client-key-p payload #\x)))
       (when (%reject-pending-worktree-attachment conn :worktree worktree)
         (return-from %handle-worktree-assignment-key t))
       (if (null worktree)
           (%client-notify conn "workspace changed; refresh before assigning")
           (multiple-value-bind (handled started)
               (%open-client-worktree-pane
                session conn (progn
                               (setf (workspace-assignment-receipt state) nil)
                               worktree)
                :default-command (if codex-p +workspace-codex-command+
                                     +workspace-claude-command+)
                :agent-kind (if codex-p :codex :claude))
             (declare (ignore handled))
             (if started
                 (progn
                   (setf (workspace-assignment-phase state) :done)
                   (%close-client-transient conn))
                 (%show-worktree-assignment conn state)))))))
  t)


(defun %worktree-attached-to-clients-p (session worktree clients)
  (when session
    (let ((panes (nerimux/workspace-model:worktree-panes worktree))
          (agent-pane (nerimux/workspace-model:worktree-agent-pane worktree))
          (window (session-active-window session)))
      (flet ((owned-pane-p (pane)
               (and pane (or (eq pane agent-pane)
                             (member pane panes :test #'eq)))))
        (some (lambda (client)
                (let ((pane-view-p (not (member (client-conn-view client)
                                                '(:repolist :status)))))
                  (or (and pane-view-p
                           (or (owned-pane-p (client-conn-stdin-target client))
                               (owned-pane-p (%resolve-client-focus-pane
                                              session nil client))))
                      (and (or pane-view-p
                               (eq (client-conn-modal client) :picker))
                           window
                           (some #'owned-pane-p
                                 (nerimux/window:window-panes window))))))
              clients)))))


(defun %finish-worktree-delete (reservation removed-p)
  (let ((key (worktree-delete-reservation-key reservation)))
    (when (eq reservation (gethash key *worktree-delete-reservations*))
      (if (not removed-p)
          (when (eq (worktree-delete-reservation-phase reservation) :pending)
            (remhash key *worktree-delete-reservations*))
          (progn
            (setf (worktree-delete-reservation-phase reservation) :removed)
            (dolist (pane (worktree-delete-reservation-panes reservation))
              (unless (pane-live-p pane)
                (let ((window (pane-window pane)))
                  (when window
                    (nerimux/window:window-remove-pane window pane)
                    (unless (window-panes window)
                      (dolist (entry *server-sessions*)
                        (when (member window (session-windows (cdr entry)))
                          (session-remove-window (cdr entry) window))))))
                (dolist (worktree (remove nil (remove-duplicates
                                              (list (worktree-delete-reservation-worktree reservation)
                                                    (nerimux/pane:pane-worktree pane)))))
                  (setf (worktree-panes worktree) (remove pane (worktree-panes worktree)))
                  (when (eq pane (nerimux/workspace-model:worktree-agent-pane worktree))
                    (setf (nerimux/workspace-model:worktree-agent-pane worktree) nil)))
                (setf (pane-window pane) nil
                      (nerimux/pane:pane-worktree pane) nil)
                (dolist (client *clients*)
                  (when (eq pane (client-conn-focus client))
                    (when (client-conn-host-focused-p client)
                      (%client-focus-event-report client pane nil))
                    (setf (client-conn-focus client) nil))
                  (when (eq pane (client-conn-stdin-target client))
                    (setf (client-conn-stdin-target client) nil)))))
            (dolist (client *clients*)
              (when (equal key (%worktree-delete-key
                               (client-conn-selected-worktree client)))
                (setf (client-conn-selected-worktree client) nil
                      (client-conn-selected-tree-object client) nil))))))))


(defun %workspace-prune-operation-update (job worktree state &key phase outcome)
  (let ((operation (gethash (%worktree-delete-key worktree)
                            (workspace-prune-job-operation-jobs job))))
    (%workspace-job-update operation
                           (when operation (workspace-operation-job-object operation))
                           state :phase phase :outcome outcome)))


(defun %workspace-prune-directory-identity (worktree)
  (ignore-errors
    (nerimux/vcs::%prune-file-identity
     (string-right-trim "/" (worktree-path worktree)) t)))


(defun %workspace-prune-directory-current-p (job worktree)
  (let ((expected (workspace-prune-job-current-directory-identity job)))
    (and expected (equal expected (%workspace-prune-directory-identity worktree)))))


(defun %workspace-prune-exclusion (worktree &optional reservation)
  (multiple-value-bind (classification reason)
      (nerimux/workspace-model:worktree-prune-classification worktree)
    (cond
      ((and reservation
            (not (and (eq worktree (worktree-delete-reservation-worktree reservation))
                      (equal (%worktree-delete-key worktree)
                             (worktree-delete-reservation-key reservation))))) :stale-workspace)
      ((not (eq worktree (%workspace-find-worktree (worktree-path worktree)))) :stale-workspace)
      ((not (eq classification :candidate)) reason)
      ((%worktree-attached-to-clients-p (%attach-target-session) worktree *clients*) :attached)
      ((%worktree-cancel-pending-p worktree) :cancellation-pending)
      ((and (%worktree-delete-pending-p worktree)
            (not (eq reservation (gethash (%worktree-delete-key worktree)
                                         *worktree-delete-reservations*)))) :deletion-pending))))


(defun %workspace-prune-record (job worktree outcome &optional detail)
  (%workspace-prune-operation-update job worktree
                                     (if (eq outcome :removed) :succeeded :failed)
                                     :outcome outcome)
  (push (list (%worktree-delete-key worktree) outcome detail)
        (workspace-prune-job-results job))
  (%client-notify (workspace-prune-job-conn job)
                  (format nil "workspace prune ~A ~A: ~A~@[ (~A)~]"
                          (first (%worktree-delete-key worktree))
                          (worktree-path worktree) outcome detail)))


(defun %workspace-prune-settle (job reservation outcome &optional detail)
  (when (eq reservation (workspace-prune-job-reservation job))
    (%finish-worktree-delete reservation (member outcome '(:removed :removed-refresh-failed)))
    (%workspace-prune-record job (workspace-prune-job-current job) outcome detail)
    (setf (workspace-prune-job-reservation job) nil
          (workspace-prune-job-current job) nil)
    (%workspace-prune-next job)))


(defun %cancel-client-workspace-prune (conn)
  (let ((job (client-conn-workspace-prune-job conn)))
    (when job
      (setf (workspace-prune-job-cancelled-p job) t)
      (dolist (worktree (workspace-prune-job-queue job))
        (%workspace-prune-record job worktree :cancelled :disconnected))
      (setf (workspace-prune-job-queue job) nil)
      (when (eq (workspace-prune-job-state job) :confirming)
        (%close-confirm-view conn)
        (%workspace-prune-settle job (workspace-prune-job-reservation job)
                                 :cancelled :disconnected)))))


(defun %workspace-prune-delete (job reservation snapshot)
  (unless (and (eq reservation (workspace-prune-job-reservation job))
               (member (workspace-prune-job-state job) '(:running :confirming)))
    (return-from %workspace-prune-delete nil))
  (let* ((conn (workspace-prune-job-conn job))
         (worktree (workspace-prune-job-current job))
         (reason (%workspace-prune-exclusion worktree reservation)))
    (cond
      ((or (workspace-prune-job-cancelled-p job) (not (%client-live-p conn)))
       (%workspace-prune-settle job reservation :cancelled :disconnected))
      (reason (%workspace-prune-settle job reservation :excluded reason))
      (t
       (setf (workspace-prune-job-state job) :deleting)
       (%workspace-prune-operation-update job worktree :queued)
       (handler-case
           (nerimux/vcs:delete-worktree-async
            worktree :force (not (null (nerimux/vcs:worktree-prune-snapshot-changed-files snapshot)))
            :callback-dispatch #'%enqueue-main-thread-callback
            :on-start (lambda () (%workspace-prune-operation-update job worktree :running))
            :before-delete
            (lambda ()
              (when (or (workspace-prune-job-cancelled-p job)
                        (not (%client-live-p conn))
                        (not (%workspace-prune-directory-current-p job worktree))
                        (%workspace-prune-exclusion worktree reservation))
                (error "workspace prune authorization no longer valid"))
              (nerimux/vcs:validate-worktree-prune-snapshot worktree snapshot)
              (when (or (workspace-prune-job-cancelled-p job)
                        (not (%client-live-p conn))
                        (not (%workspace-prune-directory-current-p job worktree))
                        (%workspace-prune-exclusion worktree reservation))
                (error "workspace prune authorization changed during validation"))
              t)
            :on-result
            (lambda (result)
              (%workspace-prune-settle
               job reservation
               (if (nerimux/vcs:worktree-delete-result-removed-p result)
                   (if (nerimux/vcs:worktree-delete-result-refresh-error result)
                       :removed-refresh-failed :removed)
                   :failed)
               (or (nerimux/vcs:worktree-delete-result-error result)
                   (nerimux/vcs:worktree-delete-result-refresh-error result)))))
         (error (condition) (%workspace-prune-settle job reservation :failed condition)))))))


(defun %workspace-prune-preflight (job reservation)
  (let ((conn (workspace-prune-job-conn job))
        (worktree (workspace-prune-job-current job)))
    (handler-case
        (nerimux/vcs:read-worktree-prune-snapshot-async
         worktree :callback-dispatch #'%enqueue-main-thread-callback
         :on-start (lambda () (%workspace-prune-operation-update job worktree :running))
         :on-error (lambda (condition)
                     (when (eq (workspace-prune-job-state job) :running)
                       (%workspace-prune-settle job reservation :failed condition)))
         :on-complete
         (lambda (snapshot)
           (when (and (eq reservation (workspace-prune-job-reservation job))
                      (eq (workspace-prune-job-state job) :running))
             (cond
               ((or (workspace-prune-job-cancelled-p job) (not (%client-live-p conn)))
                (%workspace-prune-settle job reservation :cancelled :disconnected))
               ((%workspace-prune-exclusion worktree reservation)
                (%workspace-prune-settle job reservation :excluded
                                         (%workspace-prune-exclusion worktree reservation)))
               ((nerimux/vcs:worktree-prune-snapshot-changed-files snapshot)
                (setf (workspace-prune-job-state job) :confirming)
                (%workspace-prune-operation-update job worktree :running :phase :confirming)
                (%open-confirm-view
                 conn "WORKSPACE PRUNE"
                 (list (cons "repository" (first (%worktree-delete-key worktree)))
                       (cons "workspace" (worktree-path worktree))
                       (cons "agent final state" (format nil "~A" (nerimux/pane:worktree-agent-state worktree)))
                       (cons "changed files"
                             (format nil "~{~A~^; ~}"
                                     (mapcar (lambda (entry) (format nil "~A ~A" (car entry) (cdr entry)))
                                             (nerimux/vcs:worktree-prune-snapshot-changed-files snapshot)))))
                 (lambda () (%workspace-prune-delete job reservation snapshot))
                 :on-cancel (lambda () (%workspace-prune-settle job reservation :cancelled))))
               (t (%workspace-prune-delete job reservation snapshot))))))
      (error (condition) (%workspace-prune-settle job reservation :failed condition)))))


(defun %workspace-prune-next (job)
  (let ((conn (workspace-prune-job-conn job)))
    (loop for queued = (pop (workspace-prune-job-queue job))
          while queued
          for worktree = (nerimux/vcs::%refreshed-worktree-successor queued)
          do (let ((reason (%workspace-prune-exclusion worktree)))
               (cond
                 ((or (workspace-prune-job-cancelled-p job) (not (%client-live-p conn)))
                  (%workspace-prune-record job worktree :cancelled :disconnected))
                 (reason (%workspace-prune-record job worktree :excluded reason))
                 ((let ((identity (gethash queued (workspace-prune-job-directory-identities job))))
                    (not (and identity (equal identity (%workspace-prune-directory-identity worktree)))))
                  (%workspace-prune-record job worktree :excluded :stale-directory))
                 (t
                  (unless (eq queued worktree)
                    (setf (gethash (%worktree-delete-key worktree)
                                   (workspace-prune-job-operation-jobs job))
                          (%workspace-job-begin :worktree (worktree-id worktree) :prune worktree)))
                  (let ((reservation
                          (make-worktree-delete-reservation
                           :key (%worktree-delete-key worktree) :worktree worktree
                           :panes (remove-duplicates
                                   (remove nil (cons (nerimux/workspace-model:worktree-agent-pane worktree)
                                                     (copy-list (worktree-panes worktree)))) :test #'eq))))
                    (setf (gethash (%worktree-delete-key worktree) *worktree-delete-reservations*) reservation
                          (workspace-prune-job-current job) worktree
                          (workspace-prune-job-current-directory-identity job)
                          (gethash queued (workspace-prune-job-directory-identities job))
                          (workspace-prune-job-reservation job) reservation
                          (workspace-prune-job-state job) :running)
                    (%client-notify conn (format nil "workspace prune running: ~A" (worktree-path worktree)))
                    (%workspace-prune-preflight job reservation)
                    (return-from %workspace-prune-next nil))))))
    (setf (workspace-prune-job-state job)
          (if (find-if (lambda (result) (member (second result) '(:failed :removed-refresh-failed)))
                       (workspace-prune-job-results job)) :failed :succeeded))
    (%client-notify conn (format nil "workspace prune ~A: ~D removed, ~D excluded, ~D cancelled, ~D failed"
                                (workspace-prune-job-state job)
                                (count-if (lambda (result) (member (second result) '(:removed :removed-refresh-failed)))
                                          (workspace-prune-job-results job))
                                (count :excluded (workspace-prune-job-results job) :key #'second)
                                (count :cancelled (workspace-prune-job-results job) :key #'second)
                                (count-if (lambda (result) (member (second result) '(:failed :removed-refresh-failed)))
                                          (workspace-prune-job-results job))))))


(defun %client-prune-workspaces (conn &key all)
  (let ((old (client-conn-workspace-prune-job conn))
        (worktrees (if all (%workspace-worktrees)
                       (when (client-conn-selected-worktree conn)
                         (list (client-conn-selected-worktree conn))))))
    (cond
      ((or (client-conn-modal conn)
           (and old (not (member (workspace-prune-job-state old) '(:succeeded :failed)))))
       (%client-notify conn "workspace prune already pending or modal active"))
      ((null worktrees) (%client-notify conn "no workspace selected for prune"))
      (t
       (let* ((identities (make-hash-table :test #'eq))
              (job (make-workspace-prune-job :conn conn :queue (copy-list worktrees)
                                             :directory-identities identities)))
         (dolist (worktree worktrees)
           (setf (gethash worktree identities) (%workspace-prune-directory-identity worktree)
                 (gethash (%worktree-delete-key worktree) (workspace-prune-job-operation-jobs job))
                 (%workspace-job-begin :worktree (worktree-id worktree) :prune worktree)))
         (setf (client-conn-workspace-prune-job conn) job)
         (%client-notify conn (format nil "workspace prune queued: ~D workspaces" (length worktrees)))
         (%workspace-prune-next job)))))
  t)
