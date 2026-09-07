(in-package #:nerimux)

(defun %workspace-collapsed-nodes ()
  "Return the collapsed-row set after its DEFVAR is available."
  *workspace-collapsed-node-ids*)

(defun %workspace-expanded-nodes ()
  "Return the expanded repository-row set after its DEFVAR is available."
  *workspace-expanded-node-ids*)

(defun %workspace-file-diffs ()
  "Return the per-file diff cache after its DEFVAR is available."
  *workspace-file-diffs*)

(defun %set-workspace-file-diff (key value)
  "Store VALUE under KEY, evicting the oldest entry when the cache is full."
  (let* ((table (%workspace-file-diffs))
         (new-key-p (not (nth-value 1 (gethash key table)))))
    (when 
        (and new-key-p
             (>= (hash-table-count table) *workspace-file-diffs-cache-limit*))
      (let ((oldest (pop *workspace-file-diffs-order*)))
        (when oldest
          (remhash oldest table))))
    (setf (gethash key table) value)
    (when new-key-p
      (setf *workspace-file-diffs-order* (nconc *workspace-file-diffs-order*
                                                (list key))))
    value))

(defun %toggle-workspace-node-collapsed (kind id)
  "Flip the KIND (:ORGANIZATION or :REPOSITORY) / ID row's collapse state
   (R6.3's Enter-toggles-collapse behaviour)."
  (let ((key (list kind id)))
    (if (gethash key *workspace-collapsed-node-ids*)
        (remhash key *workspace-collapsed-node-ids*)
        (setf (gethash key *workspace-collapsed-node-ids*) t))))

(defun %mark-workspace-refreshing (kind id)
  "Record that the KIND/ID node's data is being refreshed (R6.2), and clear
   any stale mark on it -- a fresh attempt in flight supersedes the last
   failure until this one, too, settles."
  (let ((key (list kind id)))
    (setf (gethash key *workspace-refreshing-ids*) t)
    (remhash key *workspace-stale-ids*)))

(defun %workspace-job-begin (kind id operation object)
  (let* ((key (list kind id operation))
         (job (make-workspace-operation-job :key key :object object)))
    (setf (gethash key *workspace-operation-jobs*) job)
    (%mark-dirty)
    job))

(defun %workspace-job-update (job object state &key phase outcome)
  (when (and job
             (eq job (gethash (workspace-operation-job-key job)
                              *workspace-operation-jobs*))
             (eq object (workspace-operation-job-object job))
             (member (workspace-operation-job-state job) '(:queued :running)))
    (setf (workspace-operation-job-state job) state
          (workspace-operation-job-phase job) phase
          (workspace-operation-job-outcome job) outcome)
    (%mark-dirty)
    job))

(defun %workspace-job-retire-catalog (organizations)
  (let ((objects (loop for org in organizations append
                  (cons org (loop for repo in (organization-repositories org)
                                  append (cons repo (repository-worktrees repo)))))))
    (maphash
     (lambda (key job)
       (declare (ignore key))
       (unless (or (eq :catalog (first (workspace-operation-job-key job)))
                   (member (workspace-operation-job-object job) objects :test #'eq))
         (%workspace-job-update job (workspace-operation-job-object job)
                                :failed :outcome :retired)))
     *workspace-operation-jobs*)))

(defun %workspace-job-tick (&optional (now (get-internal-real-time)))
  (let ((tick (floor now (max 1 (floor internal-time-units-per-second 8)))))
    (when (and (/= tick *workspace-job-spinner-tick*)
               (loop for job being the hash-values of *workspace-operation-jobs*
                     thereis (and (eq :running (workspace-operation-job-state job))
                                  (not (eq :confirming (workspace-operation-job-phase job))))))
      (setf *workspace-job-spinner-tick* tick)
      (%mark-dirty)
      t)))

(defun %workspace-job-labels ()
  (let ((labels (make-hash-table :test #'equal)))
    (maphash
     (lambda (key job)
       (let* ((state (workspace-operation-job-state job))
              (phase (workspace-operation-job-phase job))
              (row (if (member (first key) '(:catalog :organization))
                       '(:section :repositories) (subseq key 0 2)))
              (label (format nil " [~(~A~):~(~A~)~@[ ~A~]~@[ ~(~A~)~]]"
                             (third key) state
                             (when (and (eq state :running) (not (eq phase :confirming)))
                               (char "|/-\\" (mod *workspace-job-spinner-tick* 4)))
                             (or phase (workspace-operation-job-outcome job)))))
         (setf (gethash row labels)
               (concatenate 'string (gethash row labels "") label))))
     *workspace-operation-jobs*)
    labels))

(defun %workspace-refresh-organizations-async (&key on-catalog on-complete on-error
                                                   on-repository-error on-progress
                                                   callback-dispatch)
  (maphash (lambda (key job)
             (when (eq (third key) :status)
               (%workspace-job-update job (workspace-operation-job-object job)
                                      :failed :outcome :retired)))
           *workspace-operation-jobs*)
  (let* ((object (gensym "CATALOG-OBJECT-"))
         (scan (%workspace-job-begin :catalog :all :scan object))
         (statuses (make-hash-table :test #'eq)))
    (labels ((settle (repository state &optional outcome)
               (%workspace-job-update (gethash repository statuses) repository state
                                      :outcome outcome))
             (fail (condition)
               (%workspace-job-update scan object :failed :outcome condition)
               (when on-error (funcall on-error condition))))
      (handler-case
          (nerimux/vcs:refresh-workspace-organizations-async
           :callback-dispatch callback-dispatch
           :on-start (lambda () (%workspace-job-update scan object :running))
           :on-progress on-progress
           :on-catalog
           (lambda (organizations)
             (%workspace-job-update scan object :succeeded)
             (%workspace-job-retire-catalog organizations)
             (dolist (org organizations)
               (dolist (repo (organization-repositories org))
                 (setf (gethash repo statuses)
                       (%workspace-job-begin :repository (repository-id repo) :status repo))))
             (when on-catalog (funcall on-catalog organizations)))
           :on-repository-start (lambda (repo) (settle repo :running))
           :on-repository (lambda (repo) (settle repo :succeeded))
           :on-repository-error
           (lambda (repo condition)
             (settle repo :failed condition)
             (when on-repository-error (funcall on-repository-error repo condition)))
           :on-complete
           (lambda (organizations)
             (maphash (lambda (repo job)
                        (declare (ignore job))
                        (settle repo :succeeded)) statuses)
             (when on-complete (funcall on-complete organizations)))
           :on-error #'fail)
        (error (condition) (fail condition))))))

(defun %workspace-fetch-async (kind object on-complete on-error callback-dispatch)
  (let ((jobs nil) (accepted-p nil) (failed-p nil))
    (labels ((update (state &optional outcome)
               (dolist (job jobs)
                 (%workspace-job-update job (workspace-operation-job-object job)
                                        state :outcome outcome)))
             (accept ()
               (setf accepted-p t)
               (push (%workspace-job-begin kind
                                           (if (eq kind :repository) (repository-id object)
                                               (organization-id object))
                                           :fetch object) jobs))
             (complete (result)
               (when accepted-p (update :succeeded))
               (when (and on-complete (not failed-p))
                 (funcall on-complete (if (and accepted-p (null result)) object result))))
             (fail (&rest arguments)
               (setf failed-p t)
               (update :failed (car (last arguments)))
               (when on-error (apply on-error arguments))))
      (handler-case
       (apply (if (eq kind :repository) #'nerimux/vcs:fetch-repository-async
                 #'nerimux/vcs:fetch-organization-async)
             object
             (list :on-accepted #'accept :on-start (lambda () (update :running))
                   :on-complete #'complete :on-error #'fail
                   :callback-dispatch callback-dispatch))
       (error (condition)
         (if (eq kind :repository)
             (fail condition)
             (progn
               (setf failed-p t)
               (update :failed condition)
               (error condition))))))))

(defun %workspace-fetch-repository-async (repository &key on-complete on-error callback-dispatch)
  (%workspace-fetch-async :repository repository on-complete on-error callback-dispatch))

(defun %workspace-fetch-organization-async (organization &key on-complete on-error callback-dispatch)
  (%workspace-fetch-async :organization organization on-complete on-error callback-dispatch))

(defun %clear-workspace-refreshing (kind id &key stale-p)
  "Settle a refresh started with %MARK-WORKSPACE-REFRESHING: always clears
   the refreshing mark; sets the stale mark when STALE-P (the refresh
   failed), else clears it (the refresh succeeded)."
  (let ((key (list kind id)))
    (remhash key *workspace-refreshing-ids*)
    (if stale-p
        (setf (gethash key *workspace-stale-ids*) t)
        (remhash key *workspace-stale-ids*))))

(defun %set-workspace-catalog-refresh-state (organizations mode &key stale-p)
  "Mark or settle every visible node in ORGANIZATIONS according to MODE.
MODE is :MARK or :SETTLE; STALE-P applies when settling."
  (labels ((visit (kind id)
             (ecase mode
               (:mark (%mark-workspace-refreshing kind id))
               (:settle (%clear-workspace-refreshing kind id :stale-p stale-p)))))
    (dolist (organization organizations)
      (visit :organization (nerimux/workspace-model:organization-id organization))
      (dolist (repository
                (nerimux/workspace-model:organization-repositories organization))
        (visit :repository (nerimux/workspace-model:repository-id repository))
        (dolist (worktree (nerimux/workspace-model:repository-worktrees repository))
          (visit :worktree (nerimux/workspace-model:worktree-id worktree)))))
    (when (eq mode :settle)
      (clrhash *workspace-file-diffs*)
      (setf *workspace-file-diffs-order* nil))
    nil))

(defun %mark-repository-node-stale (repository)
  "Mark REPOSITORY and its worktrees stale immediately."
  (%clear-workspace-refreshing :repository
                               (repository-id repository)
                               :stale-p
                               t)
  (dolist (worktree (repository-worktrees repository))
    (%clear-workspace-refreshing :worktree (worktree-id worktree) :stale-p t)))

(defun %reapply-stale-repository-marks (organizations failed-repository-ids)
  "Restore stale marks for failed repositories still present in ORGANIZATIONS."
  (dolist (organization organizations)
    (dolist 
        (repository
         (nerimux/workspace-model:organization-repositories organization))
      (when 
          (member (repository-id repository)
                  failed-repository-ids
                  :test
                  #'equal)
        (%mark-repository-node-stale repository)))))

(defun %remember-worktree-pane (worktree pane)
  "Record PANE as the one to return to next time Enter lands on WORKTREE's
   tree row (R6.3). Call this on every focus change within a worktree, not
   only from the worktree-row Enter handler itself -- the requirement is to
   remember the last-focused pane, not just the last one opened via Enter."
  (when (and worktree pane)
    (setf (gethash (worktree-id worktree) *workspace-worktree-last-pane*) pane)))

(defun %worktree-remembered-pane (worktree)
  "The pane %REMEMBER-WORKTREE-PANE last recorded for WORKTREE, or NIL when
   there is none or it has since closed. Self-healing: a pane no longer
   among WORKTREE's own panes is treated as gone and its stale entry is
   dropped here, so a caller never has to remember to clear this table when
   it closes a pane."
  (when worktree
    (let ((pane (gethash (worktree-id worktree) *workspace-worktree-last-pane*)))
      (cond
        ((null pane) nil)
        ((member pane (worktree-panes worktree) :test #'eq) pane)
        (t
          (remhash (worktree-id worktree) *workspace-worktree-last-pane*)
          nil)))))

(define-multi-msg-dispatch
  ((null type) :drop)
  ((= type +msg-detach+) :drop)
  ((or (= type +msg-attach+) (= type +msg-resize+))
   (%handle-multi-attach-or-resize session conn type payload))
  ((= type +msg-key+)
   (%handle-multi-key-message session conn payload))
  ((= type +msg-command+)
   (%handle-multi-command-message session conn payload))
  (t :drop))

(defun %settle-workspace-catalog-after-error (condition)
  "Settle the catalog as stale after its asynchronous refresh fails."
  (declare (ignore condition))
  (setf *workspace-catalog-loaded-p* t
        *workspace-scan-progress* nil)
  (%set-workspace-catalog-refresh-state
   (nerimux/vcs:workspace-organizations) :settle :stale-p t)
  (%mark-dirty))

(defun %add-client (socket)
  "Register SOCKET as a new client: build its CLIENT-CONN and mark
   the screen dirty so the new client gets an immediate paint.  Returns the
   conn, or NIL when +MAX-CLIENTS+ are already registered -- SOCKET is closed
   instead of registered in that case."
  (when (>= (length *clients*) +max-clients+)
    (close-socket socket)
    (return-from %add-client nil))
  (let ((conn (%make-client-conn :socket socket
                                 :stream (socket-stream socket)
                                 :fd     (socket-fd socket)
                                 :rows   *term-rows*
                                 :cols   *term-cols*
                                 :view   :repolist
                                 :modal  nil
                                 :viewport 0)))
    (push conn *clients*)
    (when (and (not *workspace-catalog-refresh-started-p*)
               (nerimux/vcs:vcs-package-available-p))
      (setf *workspace-catalog-refresh-started-p* t)
      (%set-workspace-catalog-refresh-state
       (nerimux/vcs:workspace-organizations) :mark)
      (let ((failed-repository-ids nil))
        (handler-case
            (%workspace-refresh-organizations-async
             :callback-dispatch #'%enqueue-main-thread-callback
             :on-progress
             (lambda (count)
               (setf *workspace-scan-progress* count)
               (%mark-dirty))
             :on-catalog
             (lambda (organizations)
               (%set-workspace-catalog-refresh-state organizations :mark)
               (%mark-dirty))
             :on-repository-error
             (lambda (repository condition)
               (declare (ignore condition))
               (pushnew (repository-id repository) failed-repository-ids
                        :test #'equal)
               (%mark-repository-node-stale repository)
               (%mark-dirty))
             :on-complete
             (lambda (organizations)
               (setf *workspace-catalog-loaded-p* t
                     *workspace-scan-progress* nil)
               (%set-workspace-catalog-refresh-state
                organizations :settle :stale-p nil)
               (%reapply-stale-repository-marks organizations failed-repository-ids)
               (dolist (client (remove-duplicates
                                (remove-if-not #'%client-live-p
                                               (copy-list *clients*))
                                :test #'eq))
                 (%rebind-client-selection client organizations)
                 (setf (client-conn-picker-items client)
                       (nerimux/picker:build-global-picker-items organizations))
                 (%picker-clamp-index client
                                      (%client-picker-visible-items client)))
               (%mark-dirty))
             :on-error
             #'%settle-workspace-catalog-after-error)
          (error (condition)
            (declare (ignore condition))
            (setf *workspace-catalog-loaded-p* t
                  *workspace-scan-progress* nil)
            (%set-workspace-catalog-refresh-state
             (nerimux/vcs:workspace-organizations) :settle :stale-p t)
            (%mark-dirty)))))
    (%mark-dirty)
    conn))

(defun %drop-client (conn &key bye)
  "Remove CONN, optionally send a bye frame, and close its socket.

   This cleanup is idempotent and never propagates I/O errors: it runs from
   error handlers and the server loop's unwind cleanup.  Unregister first,
   then close with ABORT so a broken peer cannot prevent local fd release."
  (when (member conn *clients*)
    (setf *clients* (remove conn *clients*))
    (%cancel-client-workspace-prune conn)
    (setf (client-conn-ui-prefix-p conn) nil)
    (when (and bye (streamp (client-conn-stream conn)))
      (handler-case
          (send-frame (client-conn-stream conn) (msg-bye))
        (sb-ext:timeout () nil)
        (sb-bsd-sockets:socket-error () nil)
        (stream-error () nil)))
    (let ((socket (client-conn-socket conn)))
      (when socket
        (handler-case
            (close-socket socket :abort t)
          (peer-io-failure () nil))))))
