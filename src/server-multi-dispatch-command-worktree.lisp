(in-package #:nerimux)

(declaim (special *workspace-operation-jobs*))

(defun %worktree-live-pane-count (worktree)
  "How many of WORKTREE's panes still have a running process, agent included."
  (length (remove-duplicates
           (remove-if-not
            #'pane-live-p
            (remove nil
                    (cons (nerimux/workspace-model:worktree-agent-pane worktree)
                          (copy-list
                           (nerimux/workspace-model:worktree-panes worktree)))))
           :test #'eq)))

(defun %worktree-command-text (operation worktree)
  (format nil "git worktree ~A ~A" operation
          (nerimux/workspace-model:worktree-path worktree)))

(defvar *worktree-layout-noted-repository-ids* (make-hash-table :test #'equal)
  "Repository ids already told once where their worktrees are being put.")

(defun %note-worktree-layout (conn repository path)
  "State once where a checkout's worktrees go.

They live in .worktrees, which nerimux has git ignore so the repository does
not turn dirty the moment one is created; when that ignore cannot be written
they go next to the repository instead. A bare repository has no working tree
to keep clean, so it is left unsaid there."
  (let* ((root (string-right-trim
                "/" (nerimux/workspace-model:repository-local-path repository)))
         (id (nerimux/workspace-model:repository-id repository))
         (length (length root)))
    (unless (or (gethash id *worktree-layout-noted-repository-ids*)
                (and (> length 4) (string= ".git" root :start2 (- length 4))))
      (setf (gethash id *worktree-layout-noted-repository-ids*) t)
      ;; The model path is git's own resolved one, which on macOS differs from
      ;; the repository path by /private, so the directory name is what can be
      ;; compared: .worktrees inside, -worktrees beside.
      (%client-notify conn
                      (if (and (stringp path) (search "/.worktrees/" path))
                          "worktrees live in .worktrees, ignored in .git/info/exclude"
                          "worktrees go beside the repo: .worktrees is not ignored")))))

(defun %client-delete-worktree (conn target args)
  (if (not (%client-boolean-option-p args '("--confirm" "confirm")))
      (progn
        (%client-notify conn "wt-delete: add --confirm to run")
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
          ((nerimux/workspace-model:worktree-locked-p worktree)
            (%client-notify conn "worktree is locked: w u unlocks it")
            t)
          ((plusp (%worktree-live-pane-count worktree))
            (%client-notify conn
                            (format nil "close its ~D pane~:P first (C-q x)"
                                    (%worktree-live-pane-count worktree)))
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
                     (%client-log-process conn
                                          (%worktree-command-text "remove" worktree)
                                          nil
                                          (princ-to-string condition))
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
                                                                 (%client-log-process
                                                                  conn
                                                                  (%worktree-command-text "remove" worktree)
                                                                  t
                                                                  "")
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

(defun %reselect-refreshed-worktree (conn worktree)
  "Point CONN's selection at the struct the refresh WORKTREE just triggered
produced.

A worktree operation refreshes the repository, and that rebuild allocates a
fresh struct for every worktree. A client still holding the old one keeps
rendering the state it had: the detail panel went on reading `locked' for
several seconds after an unlock, until the next `g' moved the selection."
  (let ((current (nerimux/vcs:refreshed-worktree-successor worktree)))
    (when (and current
               (not (eq current worktree))
               (eq worktree (client-conn-selected-worktree conn)))
      (%set-client-selected-worktree conn current))))

(defmacro %define-worktree-state-operation
    (name operation command progressive complete &rest operation-arguments)
  "Define a worktree lock or unlock command.

Neither takes --confirm: both are reversible by the opposite key, and the `w`
transient could only reach them by pre-filling a flag the documented command
line never mentioned."
  `(defun ,name (conn target args)
     (declare (ignorable args))
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
                   (%client-log-process conn
                                        (%worktree-command-text ,command worktree)
                                        nil
                                        (princ-to-string condition))
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
                              (%reselect-refreshed-worktree conn worktree)
                              (%refresh-client-picker conn)
                              (%client-log-process
                               conn
                               (%worktree-command-text ,command worktree)
                               t
                               "")
                              (%client-notify
                               conn
                               (format nil "worktree ~A" ,complete))
                              (%mark-dirty))
                            :on-error
                            #'%on-error)
              (error (condition)
                (%on-error condition))))
          t)))))

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

(defun %workspace-prune-preview-text (worktrees)
  "What a prune of WORKTREES would do: how many it would remove, how many it
would keep, and why -- read from the same classification the prune itself
applies, without touching anything."
  (let ((prunable 0)
        (kept 0)
        (reasons nil))
    (dolist (worktree worktrees)
      (let ((reason (%workspace-prune-exclusion worktree)))
        (if reason
            (progn
              (incf kept)
              (pushnew (%workspace-prune-reason-text :excluded reason)
                       reasons :test #'equal))
            (incf prunable))))
    (if (zerop prunable)
        "nothing to prune"
        (format nil "~D prunable, ~D kept~@[ (~{~A~^, ~})~]"
                prunable kept (remove nil (nreverse reasons))))))

(defun %client-prune-worktrees (conn target args &key dry-run)
  "Preview the workspace prune, or run it once the user has confirmed.

`wt-prune' and `wt-prune-confirm' are the `:' prompt's way into the prune
`w p' / `w P' runs: one implementation, the same completed/live-pane/locked/
primary classification, the same removal. They used to wrap `git worktree
prune', which only drops administrative files for directories already gone and
has no notion of nerimux's `completed' flag, so marking a worktree complete and
running `wt-prune-confirm --confirm' reported nothing to prune and removed
nothing.

DRY-RUN must default true at every call site; a caller passes DRY-RUN NIL only
after the user asked for the prune itself, which still requires an explicit
--confirm option, so a prune can never be reached by a single accidental
keystroke."
  (declare (ignore target))
  (cond
    ((and (not dry-run)
          (not (%client-boolean-option-p args '("--confirm" "confirm"))))
     (%client-notify conn "wt-prune-confirm: add --confirm to run")
     t)
    ((not (nerimux/vcs:vcs-package-available-p))
     (%client-notify conn "VCS unavailable")
     t)
    (dry-run
     (%client-notify conn
                     (format nil "worktree prune preview: ~A"
                             (%workspace-prune-preview-text
                              (%workspace-worktrees))))
     (%mark-dirty)
     t)
    (t
     ;; --CONFIRM is one gate; %CONFIRM-CLIENT-PRUNE-WORKSPACES's confirm view
     ;; is the one that actually prunes, on `y', mirroring `w P'. It refuses to
     ;; open while a modal owns the client, and the `:' prompt is still up
     ;; while the command it submitted runs.
     (when (eq (client-conn-modal conn) :command)
       (%set-client-modal conn nil))
     (%confirm-client-prune-workspaces conn t))))


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


(defun %assignment-subtitle (state)
  "`org/repo · branch' for the Assign panel, the way the status header and the
   picker name the same worktree.  The absolute path it replaces was mostly
   the ghq root, repeated on every panel.  A bare clone's specification ends
   in \".git\", which the tree already strips before display, so the panel
   strips it too rather than showing the on-disk suffix."
  (let* ((repository (workspace-assignment-repository state))
         (raw-specification (and repository
                                 (nerimux/workspace-model:repository-specification
                                  repository)))
         (specification (and raw-specification (plusp (length raw-specification))
                             (%workspace-strip-dot-git raw-specification)))
         (worktree (and repository (%assignment-current-worktree state)))
         (branch (or (and worktree
                          (nerimux/workspace-model:worktree-branch worktree))
                     (workspace-assignment-head state))))
    (cond
      ((and specification branch) (format nil "~A · ~A" specification branch))
      (specification specification)
      (t (workspace-assignment-path state)))))

(defun %show-worktree-assignment (conn state)
  (let ((view (nerimux/renderer:make-transient-view
               :title "Assign agent"
               :subtitle (%assignment-subtitle state)
               :arguments nil
               :actions '((#\x "Codex (bypass sandbox)" nil)
                          (#\c "Claude (skip permissions)" nil)
                          (#\t "Terminal" nil)
                          (#\k "Discard worktree" nil)))))
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


(defun %client-create-detached-worktree (repository conn session &key (mode :assign))
  "Create a detached worktree under REPOSITORY and hand it to the user.

MODE :ASSIGN offers the new worktree in the Assign transient; :SHELL opens a
plain shell in it straight away, the same pane `t' opens on an existing
worktree, for callers that already know what the worktree is for."
  (let ((previous (client-conn-workspace-assignment conn)))
    (when (and previous (member (workspace-assignment-phase previous)
                                '(:creating :assigning :deleting)))
      (%client-notify conn "finish the pending workspace operation first")
      (return-from %client-create-detached-worktree t)))
  (let ((state (make-workspace-assignment :repository repository))
        (job (%workspace-job-begin :repository (repository-id repository) :create repository)))
    (setf (client-conn-workspace-assignment conn) state)
    (%client-notify conn "fetching the default branch and creating a workspace")
    (flet ((failed (condition)
             (%workspace-job-update job repository :failed :outcome condition)
             (setf (workspace-assignment-phase state) :retained)
             (%client-log-process conn "git worktree add --detach" nil
                                  (princ-to-string condition))
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
               (let ((fetch-error
                       (nerimux/vcs:detached-worktree-result-fetch-error receipt)))
                 (when fetch-error
                   ;; Advisory: the start point resolved from the local refs
                   ;; anyway, so the user is told what did not happen rather
                   ;; than losing the worktree over it.
                   (%client-log-process conn "git fetch origin" nil
                                        (princ-to-string fetch-error))))
               (%client-log-process
                conn
                (format nil "git worktree add --detach ~A"
                        (workspace-assignment-path state))
                t "")
               (when (and (%client-live-p conn)
                          (eq state (client-conn-workspace-assignment conn)))
                 (%note-worktree-layout conn repository
                                        (workspace-assignment-path state))
                 (if (or (null worktree)
                         (nerimux/vcs:detached-worktree-result-refresh-error receipt))
                     (%client-notify
                      conn (format nil "workspace created at ~A; refresh failed: ~A"
                                   (workspace-assignment-path state)
                                   (nerimux/vcs:detached-worktree-result-refresh-error receipt)))
                     (progn
                       (%set-client-selected-worktree conn worktree)
                       (if (eq mode :shell)
                           (when (and session
                                      (%open-client-worktree-pane session conn
                                                                  worktree))
                             (setf (workspace-assignment-phase state) :done)
                             (%set-client-view conn :pane))
                           (%show-worktree-assignment conn state)))))
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


(defun %close-worktree-assignment (conn state)
  "Close the Assign transient and keep the worktree it offers.

The worktree exists because the user asked for it; stepping back out of a menu
is not a request to delete it. It stays selected, with no shell open yet, and
`k` is what discards it."
  (%close-client-transient conn)
  (setf (workspace-assignment-phase state) :retained)
  (let ((worktree (%assignment-current-worktree state)))
    (when worktree
      (%set-client-selected-worktree conn worktree)))
  t)


(defun %handle-worktree-assignment-key (session conn state payload)
  (cond
    ((or (%client-byte-p payload 27) (%client-key-p payload #\q))
     (when (%client-byte-p payload 27) (%client-esc-swallow-start conn))
     (%close-worktree-assignment conn state))
    ((%client-key-p payload #\k)
     (%cancel-worktree-assignment conn state))
    ((or (%client-key-p payload #\x)
         (%client-key-p payload #\c)
         (%client-key-p payload #\t))
     (let* ((worktree (%assignment-current-worktree state))
            (agent-kind (cond ((%client-key-p payload #\x) :codex)
                              ((%client-key-p payload #\c) :claude))))
       (when (%reject-pending-worktree-attachment conn :worktree worktree)
         (return-from %handle-worktree-assignment-key t))
       (if (null worktree)
           (%client-notify conn "workspace changed; refresh before assigning")
           (multiple-value-bind (handled started)
               (%open-client-worktree-pane
                session conn (progn
                               (setf (workspace-assignment-receipt state) nil)
                               worktree)
                :default-command (case agent-kind
                                   (:codex +workspace-codex-command+)
                                   (:claude +workspace-claude-command+))
                :agent-kind agent-kind)
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
    (when (and (%workspace-job-update
                operation
                (when operation (workspace-operation-job-object operation))
                state :phase phase :outcome outcome)
               (eq state :kept))
      ;; :KEPT is settled and has nothing for the row to show. Only :SUCCEEDED
      ;; retires a job on its own, so leaving this one in the table left the
      ;; running job's "..." badge on every worktree a prune-all merely looked
      ;; at, until the server was restarted.
      (remhash (workspace-operation-job-key operation) *workspace-operation-jobs*))))


(defun %workspace-prune-directory-identity (worktree)
  (ignore-errors
    (nerimux/vcs::%prune-file-identity
     (string-right-trim "/" (worktree-path worktree)) t)))


(defun %workspace-prune-directory-current-p (job worktree)
  "True while WORKTREE's directory is the one the prune was authorized against.

A worktree whose directory is already gone has no identity to compare, and
that is the case prune exists to clean up, so its authorization is that it was
missing when queued and is missing still."
  (let ((expected (workspace-prune-job-current-directory-identity job))
        (current (%workspace-prune-directory-identity worktree)))
    (if expected
        (equal expected current)
        (and (null current) (worktree-missing-p worktree)))))


(defun %workspace-prune-exclusion (worktree &optional reservation)
  (multiple-value-bind (classification reason)
      (nerimux/workspace-model:worktree-prune-classification worktree)
    (cond
      ((and reservation
            (not (and (eq worktree (worktree-delete-reservation-worktree reservation))
                      (equal (%worktree-delete-key worktree)
                             (worktree-delete-reservation-key reservation))))) :stale-workspace)
      ((not (eq worktree (%workspace-find-worktree (worktree-path worktree)))) :stale-workspace)
      ;; :MISSING is the classification for a worktree whose directory is gone,
      ;; which is a prune target and not an exclusion.
      ((not (member classification '(:candidate :missing))) reason)
      ((%worktree-attached-to-clients-p (%attach-target-session) worktree *clients*) :attached)
      ((%worktree-cancel-pending-p worktree) :cancellation-pending)
      ((and (%worktree-delete-pending-p worktree)
            (not (eq reservation (gethash (%worktree-delete-key worktree)
                                         *worktree-delete-reservations*)))) :deletion-pending))))


(defun %workspace-prune-reason-text (outcome detail)
  "Why one worktree was not pruned, in the words the user needs to act on."
  (case detail
    (:live-pane "has panes")
    (:not-completed-or-agent-exited "not completed")
    (:locked "locked")
    (:primary "main worktree")
    (:attached "open in a client")
    ((:cancellation-pending :deletion-pending) "busy")
    ((:stale-workspace :stale-directory) "changed")
    (:missing-repository "no repository")
    (:disconnected "client gone")
    (t (cond ((eq outcome :cancelled) "not confirmed")
             (detail (princ-to-string detail))))))


(defun %workspace-prune-confirmation-required-p (worktree)
  "True when pruning WORKTREE would delete uncommitted changes or an unresolved
   conflict along with it -- WORKTREE-PRUNE-CLASSIFICATION's second value,
   which no caller read before the prune confirmation named it."
  (eq :confirmation-required
      (nth-value 1 (nerimux/workspace-model:worktree-prune-classification worktree))))

(defun %workspace-prune-confirmation-required-worktrees (worktrees)
  "The dirty or conflicted candidates among WORKTREES, named in the prune
   confirmation so uncommitted work is not force-deleted in silence."
  (remove-if-not #'%workspace-prune-confirmation-required-p worktrees))

(defun %worktree-prune-confirm-label (worktree)
  "`org/repo · branch' for WORKTREE in the prune confirm view, the same shape
   %ASSIGNMENT-SUBTITLE uses for the Assign panel."
  (let* ((repository (nerimux/workspace-model:worktree-repository worktree))
         (raw-specification (and repository
                                 (nerimux/workspace-model:repository-specification
                                  repository)))
         (specification (and raw-specification (plusp (length raw-specification))
                             (%workspace-strip-dot-git raw-specification)))
         (branch (nerimux/workspace-model:worktree-branch worktree)))
    (cond
      ((and specification branch) (format nil "~A · ~A" specification branch))
      (specification specification)
      (t (worktree-path worktree)))))


(defun %workspace-prune-record (job worktree outcome &optional detail)
  (let ((reason (%workspace-prune-reason-text outcome detail))
        (removed-p (member outcome '(:removed :removed-refresh-failed))))
    (%workspace-prune-operation-update job worktree
                                       (cond ((eq outcome :removed) :succeeded)
                                             ((member outcome '(:excluded :cancelled)) :kept)
                                             (t :failed))
                                       :outcome (or reason outcome))
    (push (list (%worktree-delete-key worktree) outcome detail)
          (workspace-prune-job-results job))
    (%client-log-process (workspace-prune-job-conn job)
                         (%worktree-command-text "remove" worktree)
                         (not (null removed-p))
                         (or reason ""))
    (%client-notify (workspace-prune-job-conn job)
                    (format nil "~A ~A~@[: ~A~]"
                            (cond (removed-p "pruned")
                                  ((member outcome '(:excluded :cancelled)) "kept")
                                  (t "prune failed"))
                            (worktree-path worktree) reason))))


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
            worktree :force (not (null (and snapshot
                                            (nerimux/vcs:worktree-prune-snapshot-changed-files
                                             snapshot))))
            :callback-dispatch #'%enqueue-main-thread-callback
            :on-start (lambda () (%workspace-prune-operation-update job worktree :running))
            :before-delete
            (lambda ()
              (when (or (workspace-prune-job-cancelled-p job)
                        (not (%client-live-p conn))
                        (not (%workspace-prune-directory-current-p job worktree))
                        (%workspace-prune-exclusion worktree reservation))
                (error "workspace prune authorization no longer valid"))
              (when snapshot
                (nerimux/vcs:validate-worktree-prune-snapshot worktree snapshot))
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
  "Read what would be lost before deleting, then delete.

A worktree whose directory is gone has nothing left to read and nothing left
to lose, so it goes straight to removal: the snapshot would only fail on the
missing directory and turn the repair into an error."
  (let ((conn (workspace-prune-job-conn job))
        (worktree (workspace-prune-job-current job)))
    (when (worktree-missing-p worktree)
      (return-from %workspace-prune-preflight
        (%workspace-prune-delete job reservation nil)))
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
          for worktree = (nerimux/vcs:refreshed-worktree-successor queued)
          do (let ((reason (%workspace-prune-exclusion worktree)))
               (cond
                 ((or (workspace-prune-job-cancelled-p job) (not (%client-live-p conn)))
                  (%workspace-prune-record job worktree :cancelled :disconnected))
                 (reason (%workspace-prune-record job worktree :excluded reason))
                 ((let ((identity (gethash queued (workspace-prune-job-directory-identities job))))
                    (not (and (equal identity (%workspace-prune-directory-identity worktree))
                              (or identity (worktree-missing-p worktree)))))
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
    (let* ((results (workspace-prune-job-results job))
           (pruned (count-if (lambda (result)
                               (member (second result) '(:removed :removed-refresh-failed)))
                             results))
           (kept (remove-if (lambda (result)
                              (member (second result) '(:removed :removed-refresh-failed)))
                            results))
           (reasons (remove-duplicates
                     (remove nil (mapcar (lambda (result)
                                           (%workspace-prune-reason-text (second result)
                                                                         (third result)))
                                         kept))
                     :test #'string= :from-end t)))
      (%client-notify conn
                      (format nil "pruned ~D, kept ~D~@[ (~{~A~^, ~})~]"
                              pruned (length kept) reasons)))))


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
