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
            (nerimux/vcs:refresh-workspace-organizations-async
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
