(in-package #:nerimux)

(defun %client-kill-denied-message (descriptions)
  (format nil "kill refused: ~D pane~:P still open, retry with :kill --force"
          (length descriptions)))

(defun %handle-client-kill-command (session conn args)
  "Serve `nerimux kill` (R8.1): answer with OK or DENIED, then drop the client.

   The reply is not optional. send-kill-request blocks on a +msg-reply+, so a
   handler that only acted and returned would leave the CLI waiting on a server
   that considers the exchange finished. Returning :QUIT here is what stops the
   serve loop -- and it only reaches the loop because
   %handle-multi-command-message forwards this value rather than discarding it.

   Typed at the `:' prompt there is no CLI waiting for a frame and no reason to
   hang up on a refusal: the attached client is shown why the kill was refused
   and keeps its session. An accepted kill has already stopped the server by
   the time %SERVER-KILL-REQUEST returns, so that path still ends the loop."
  (multiple-value-bind (status descriptions)
      (%server-kill-request session (%client-kill-force-p args))
    (cond
      (*client-command-line-p*
       (if (eq status :ok)
           :quit
           (progn (%client-notify conn (%client-kill-denied-message descriptions))
                  t)))
      (t
       (%queue-client-control-frame
        conn
        (msg-reply
         (if (eq status :denied)
             (format nil "DENIED~{~%~A~}" descriptions)
             "OK")))
       (%drop-client conn :after-flush t)
       (if (eq status :ok)
           :quit
           t)))))

(defun %client-kill-force-p (args)
  "True when a kill command carried --force."
  (and args (member "--force" args :test #'string=) t))

(defun %client-clone-repository (conn target args)
  (cond
    ((or target (/= (length args) 1))
     (%client-notify conn "clone takes one source")
     t)
    ((not (nerimux/vcs:vcs-package-available-p))
     (%client-notify conn "VCS adapter unavailable")
     t)
    (t
     (let ((repository nil)
           (job nil)
           (specification nil))
       (labels ((find-repository (source)
                  (loop for organization in (nerimux/vcs:workspace-organizations)
                        thereis
                        (find source
                              (nerimux/workspace-model:organization-repositories
                               organization)
                              :key #'nerimux/workspace-model:repository-specification
                              :test #'string=)))
                (register-repository (source)
                  (or (find-repository source)
                      (let* ((parts (uiop:split-string source :separator '(#\/)))
                             (organization
                               (progn
                                 (unless (and (= (length parts) 3)
                                              (every (lambda (part)
                                                       (plusp (length part)))
                                                     parts))
                                   (error "invalid canonical clone specification"))
                                 (nerimux/workspace-model:make-organization
                                  :host (first parts)
                                  :name (second parts))))
                             (repository
                               (nerimux/workspace-model:make-repository
                                :specification source)))
                        (nerimux/workspace-model:organization-add-repository
                         organization repository)
                        (nerimux/vcs:merge-workspace-organizations
                         (list organization))
                        (or (find-repository source) repository))))
                (ensure-job ()
                  (setf repository (register-repository specification))
                  (unless (and job
                               (eq job
                                   (gethash
                                    (list :repository
                                          (nerimux/workspace-model:repository-id
                                           repository)
                                          :clone)
                                    *workspace-operation-jobs*))
                               (eq repository
                                   (workspace-operation-job-object job))
                               (member (workspace-operation-job-state job)
                                       '(:queued :running)))
                    (setf job
                          (%workspace-job-begin
                           :repository
                           (nerimux/workspace-model:repository-id repository)
                           :clone
                           repository)))
                  job)
                (fail (reason command)
                  (when specification
                    (ensure-job)
                    (%workspace-job-update job repository :failed :outcome reason))
                  (when (and specification (%client-live-p conn))
                    (%client-log-process conn command nil reason))
                  (when (%client-live-p conn)
                    (%client-notify conn (format nil "clone failed: ~A" reason)))
                  (%mark-dirty))
                (clone-failed (condition)
                  (fail (if (typep condition 'nerimux/vcs:clone-error)
                            (nerimux/vcs:clone-error-reason condition)
                            "clone failed")
                        (and specification
                             (format nil "ghq get --bare ~A" specification))))
                (worktree-failed (condition)
                  (declare (ignore condition))
                  (fail "default branch worktree could not be created"
                        "git worktree add --detach"))
                (worktree-complete (receipt)
                  (ensure-job)
                  (let ((worktree
                          (nerimux/vcs:detached-worktree-result-worktree receipt)))
                    (if (or (null worktree)
                            (nerimux/vcs:detached-worktree-result-refresh-error
                             receipt))
                        (worktree-failed nil)
                        (progn
                          (unless
                              (member worktree
                                      (nerimux/workspace-model:repository-worktrees
                                       repository)
                                      :test #'eq)
                            (nerimux/workspace-model:repository-add-worktree
                             repository worktree))
                          (%workspace-job-update job repository :succeeded)
                          (when (nerimux/vcs:detached-worktree-result-fetch-error
                                 receipt)
                            (%client-log-process
                             conn "git fetch origin" nil
                             "fetch failed; used local refs"))
                          (%client-log-process
                           conn
                           (format nil
                                   "ghq get --bare ~A; git worktree add --detach"
                                   specification)
                           t
                           "")
                          (when (%client-live-p conn)
                            (%set-client-selected-worktree conn worktree)
                            (%client-notify
                             conn
                             (format nil "worktree created: ~A"
                                     (%worktree-display-path
                                      (nerimux/workspace-model:worktree-path
                                       worktree))))
                            (%refresh-client-picker
                             conn
                             :on-complete
                             (lambda (organizations)
                               (let ((refreshed-worktree
                                       (%workspace-find-worktree-for-attach
                                        (nerimux/workspace-model:worktree-path worktree)
                                        organizations)))
                                 (when (and refreshed-worktree
                                            (or (null (client-conn-selected-worktree conn))
                                                (eq worktree
                                                    (client-conn-selected-worktree conn))))
                                   (%set-client-selected-worktree
                                    conn refreshed-worktree))))))
                          (%mark-dirty)))))
                (create-default-worktree ()
                  (ensure-job)
                  (%workspace-job-update job repository :running :phase :worktree)
                  (handler-case
                      (nerimux/vcs:create-detached-worktree-async
                       repository
                       :callback-dispatch #'%enqueue-main-thread-callback
                       :on-start
                       (lambda ()
                         (ensure-job)
                         (%workspace-job-update job repository :running
                                                :phase :worktree))
                       :on-error #'worktree-failed
                       :on-complete #'worktree-complete)
                    (error (condition)
                      (worktree-failed condition))))
                (clone-complete (result)
                  (ensure-job)
                  (setf (nerimux/workspace-model:repository-local-path repository)
                        (nerimux/vcs:clone-result-local-path result))
                  (create-default-worktree))
                (clone-started (source)
                  (setf specification source)
                  (ensure-job)
                  (%workspace-job-update job repository :running)
                  (%client-notify conn (format nil "cloning ~A" source))
                  (%mark-dirty)))
         (handler-case
             (nerimux/vcs:clone-bare-repository-async
              (first args)
              :callback-dispatch #'%enqueue-main-thread-callback
              :on-start #'clone-started
              :on-complete #'clone-complete
              :on-error #'clone-failed)
           (error (condition)
             (clone-failed condition)))
         t)))))

(defun %client-complete-workspace (conn)
  (let* ((selected (client-conn-selected-worktree conn))
         (worktree (and selected (%workspace-find-worktree (worktree-path selected)))))
    (cond
      ((null selected) (%client-notify conn "no worktree selected"))
      ((null worktree) (%client-notify conn "worktree no longer available"))
      ((worktree-completed-p worktree)
       (setf (worktree-completed-p worktree) nil)
       (%client-notify conn "completion cleared")
       (%mark-dirty))
      ((worktree-running-agent-p worktree)
       (%open-confirm-view
        conn "WORKSPACE COMPLETE"
        (list (cons "workspace" (worktree-path worktree))
              (cons "effect" "mark completed; agent keeps running"))
        (lambda ()
          (let ((current (%workspace-find-worktree (worktree-path worktree))))
            (if current
                (progn (worktree-complete current)
                       (%client-notify conn "marked complete")
                       (%mark-dirty))
                (%client-notify conn "worktree no longer available"))))))
      (t
       (worktree-complete worktree)
       (%client-notify conn "marked complete")
       (%mark-dirty))))
  t)

(defun %workspace-prune-eligible-worktrees (worktrees)
  "The WORKTREES a prune would actually remove -- exactly what
   %WORKSPACE-PRUNE-EXCLUSION lets through at prune time, attached/pending
   checks included. Classification alone under-excludes: a worktree open in a
   client or mid cancellation/deletion classifies as :CANDIDATE but is never
   pruned, so counting it here promised work the job was never going to do."
  (remove-if #'%workspace-prune-exclusion worktrees))

(defun %confirm-client-prune-workspaces (conn all)
  "Ask before pruning, then run the job from the confirmation's y.
   %CLIENT-PRUNE-WORKSPACES refuses to start while a modal owns the client, so
   the confirmation has to close before the job begins rather than wrap it --
   which is also what lets the `:' prompt reach prune at all, since the command
   modal is still up while the command runs."
  (let* ((worktrees (if all
                        (%workspace-prune-eligible-worktrees
                         (%workspace-worktrees))
                        (let ((selected (client-conn-selected-worktree conn)))
                          (and selected (list selected)))))
         (count (length worktrees))
         (dirty (%workspace-prune-confirmation-required-worktrees worktrees)))
    (cond
      ((and all (null worktrees)) (%client-notify conn "nothing to prune"))
      ((null worktrees)
       (%client-notify conn "no workspace selected for prune"))
      (t
       (%open-confirm-view
        conn
        (if all "PRUNE ALL WORKSPACES" "PRUNE WORKSPACE")
        (append
         (list (cons "workspaces" (format nil "~D" count))
               (cons "effect" "each eligible worktree is removed"))
         (when dirty
           (list (cons "these have uncommitted changes and will be deleted with them"
                       (format nil "~{~A~^, ~}"
                               (mapcar #'%worktree-prune-confirm-label dirty))))))
        (lambda () (%client-prune-workspaces conn :all all))))))
  t)
(define-command-rules %handle-client-ui-command
                      (session conn cmd target args)
                      "Apply a client-local UI command, returning true when CMD is recognized."
                      (:kill (%handle-client-kill-command session conn args))
                      (:attach-target (%client-attach-target conn args))
                      ((:overview :workspace-overview :home)
                       (%set-client-view conn :repolist)
                       (%client-notify conn "view: overview")
                       t)
                      ((:detail :pane-detail)
                       (%set-client-view conn :pane)
                       (%client-notify conn "view: pane")
                       t)
                      ((:workspace-prefix :prefix-key :rebind-prefix)
                       (%client-rebind-prefix conn (command-argument))
                       t)
                      ((:workspace-refresh :vcs-refresh :refresh-workspace :refresh)
                       (%client-refresh-workspace conn))
                      ((:tree-up :worktree-up :tree-prev)
                       (%select-client-tree-relative conn
                                                     (-
                                                      (or
                                                       (%parse-client-integer
                                                        (command-argument))
                                                       1)))
                       t)
                      ((:tree-down :worktree-down :tree-next)
                       (%select-client-tree-relative conn
                                                     (or
                                                      (%parse-client-integer
                                                       (command-argument))
                                                      1))
                       t)
                      (:tree-scroll
                       (%move-client-tree-scroll conn
                                                 (or
                                                  (%parse-client-integer
                                                   (command-argument))
                                                  1))
                       t)
                      ((:tree-select :worktree-select)
                       (%select-client-tree-worktree conn
                                                     (command-argument))
                       t)
                      (:tree-top
                       (%set-client-selected-tree-object conn
                                                         (first
                                                          (%workspace-tree-objects
                                                           (nerimux/vcs:workspace-organizations)
                                                           (client-conn-tree-filter
                                                            conn))))
                       t)
                      (:tree-bottom
                       (%set-client-selected-tree-object conn
                                                         (car
                                                          (last
                                                           (%workspace-tree-objects
                                                            (nerimux/vcs:workspace-organizations)
                                                            (client-conn-tree-filter
                                                             conn)))))
                       t)
                      ((:worktree-create :create-worktree :wt-create)
                       (or (%client-report-missing-target conn target)
                           (%client-create-worktree conn target args)))
                      (:clone (%client-clone-repository conn target args))
                      ((:workspace-complete :wt-complete)
                       (if (eq cmd :workspace-complete)
                           (progn
                             (%client-notify conn "deprecated command: workspace-complete; use wt-complete")
                             t)
                           (if (or target args)
                               (progn
                                 (%client-notify conn "wt-complete takes no arguments")
                                 t)
                               (%client-complete-workspace conn))))
                      ((:worktree-delete :delete-worktree :wt-delete)
                       (or (%client-report-missing-target conn target
                                                          #'%workspace-find-worktree)
                           (%client-delete-worktree conn target args)))
                      ((:workspace-prune :workspace-prune-all)
                       (%client-notify
                        conn
                        (if (eq cmd :workspace-prune)
                            "deprecated command: workspace-prune; use w p"
                            "deprecated command: workspace-prune-all; use w P"))
                       t)
                      ((:worktree-lock :lock-worktree :wt-lock)
                       (or (%client-report-missing-target conn target
                                                          #'%workspace-find-worktree)
                           (%client-lock-worktree conn target args)))
                      ((:worktree-unlock :unlock-worktree :wt-unlock)
                       (or (%client-report-missing-target conn target
                                                          #'%workspace-find-worktree)
                           (%client-unlock-worktree conn target args)))
                      ((:worktree-prune-preview :wt-prune :wt-prune-dry-run)
                       (or (%client-report-missing-target conn target)
                           (%client-prune-worktrees conn target args
                                                    :dry-run t)))
                      ((:worktree-prune-confirm :wt-prune-confirm)
                       (or (%client-report-missing-target conn target)
                           (%client-prune-worktrees conn target args
                                                    :dry-run nil)))
                      (:mode
                       (let ((mode
                              (%client-ui-mode-value (command-argument))))
                         (when mode
                           (cond
                             ((eq mode :picker) (%open-client-picker conn))
                             ((eq mode :copy)
                              (%client-enter-copy-mode session conn))
                             (t
                               (%transition-client-ui-mode conn mode)
                               (%mark-dirty)))
                           t)))
                      ((:picker-open :picker :enter-picker)
                       (%open-client-picker conn)
                       t)
                      ((:picker-close :picker-cancel)
                       (%close-client-picker conn session)
                       t)
                      ((or
                        (and (eq cmd :cancel)
                             (eq (client-conn-modal conn) :picker))
                        (and (eq cmd :accept)
                             (eq (client-conn-modal conn) :picker)))
                       (if (eq cmd :accept)
                           (%select-client-picker-item session conn)
                           (%close-client-picker conn session))
                       t)
                      (:picker-accept (%select-client-picker-item session conn)
                                      t)
                      (:picker-refresh (%refresh-client-picker conn)
                                       (%mark-dirty)
                                       t)
                      ((:picker-next :picker-down :picker-prev :picker-up)
                       (let ((delta
                              (or
                               (%parse-client-integer (command-argument))
                               1)))
                         (%move-client-picker-index conn
                                                    (if (member cmd
                                                                '(:picker-prev
                                                                  :picker-up)
                                                                :test
                                                                #'eq)
                                                        (- delta)
                                                        delta))
                         t))
                      (:picker-backspace
                       (%delete-client-picker-query-character conn)
                       t)
                      (:picker-query
                       (%set-client-picker-query conn
                                                 (or target (first args) ""))
                       t)
                      (:picker-regex
                       (%set-client-picker-regex conn
                                                 (command-argument)
                                                 (or target args))
                       t)
                      ((%client-ui-mode-p cmd)
                       (cond
                         ((eq cmd :copy) (%client-enter-copy-mode session conn))
                         (t
                           (%transition-client-ui-mode conn cmd)
                           (%mark-dirty)))
                       t)
                      ((:enter-normal :enter-input
                                      :enter-copy
                                      :enter-command
                                      :cancel
                                      :accept
                                      :toggle-copy)
                       (cond
                         ((or (eq cmd :enter-copy)
                              (and (eq cmd :toggle-copy)
                                   (not
                                    (eq (client-conn-modal conn) :scrollback))))
                          (%client-enter-copy-mode session conn))
                         ((and (eq cmd :toggle-copy)
                               (eq (client-conn-modal conn) :scrollback))
                          (%client-exit-copy-mode session conn))
                         ((and (eq (client-conn-modal conn) :scrollback)
                               (member cmd '(:cancel :accept) :test #'eq))
                          (%client-exit-copy-mode session conn))
                         (t
                           (%transition-client-ui-mode conn cmd)
                           (%mark-dirty)))
                       t)
                      (:focus
                       (let ((pane
                              (%resolve-client-focus-pane session
                                                          (or target
                                                              (first args))
                                                          conn)))
                         (when pane
                           (%set-client-focus conn pane session)
                           (%mark-dirty))
                         t))
                      (:viewport
                       (let ((delta
                              (%parse-client-integer (command-argument))))
                         (when delta
                           (%move-client-viewport conn delta)
                           (%mark-dirty))
                         t))
                      (t nil))

(defun %handle-multi-command-message (session conn payload)
  "Run a forwarded client-local UI command, returning the loop disposition."
  (multiple-value-bind (cmd target args) (decode-command-payload payload)
    (let ((result (%handle-client-ui-command session conn cmd target args)))
      (cond
        (result (if (eq result :quit) :quit nil))
        (cmd
         (%client-notify conn (format nil "unknown command: ~(~A~)" cmd))
         (%mark-dirty)
         nil)
        (t (%mark-dirty) nil)))))
