(in-package #:nerimux)

(defun %handle-client-kill-command (session conn args)
  "Serve `nerimux kill` (R8.1): answer with OK or DENIED, then drop the client.

   The reply is not optional. send-kill-request blocks on a +msg-reply+, so a
   handler that only acted and returned would leave the CLI waiting on a server
   that considers the exchange finished. Returning :QUIT here is what stops the
   serve loop -- and it only reaches the loop because
   %handle-multi-command-message forwards this value rather than discarding it."
  (multiple-value-bind (status descriptions) 
      (%server-kill-request session (%client-kill-force-p args))
    (send-frame (client-conn-stream conn)
                (msg-reply
                 (if (eq status :denied)
                     (format nil "DENIED~{~%~A~}" descriptions)
                     "OK")))
    (%drop-client conn)
    (if (eq status :ok)
        :quit
        t)))

(defun %client-kill-force-p (args)
  "True when a kill command carried --force."
  (and args (member "--force" args :test #'string=) t))

(define-command-rules %handle-client-ui-command
                      (session conn cmd target args)
                      "Apply a client-local UI command, returning true when CMD is recognized."
                      (:kill (%handle-client-kill-command session conn args))
                      (:attach-target (%client-attach-target conn args))
                      ((:overview :workspace-overview :home)
                       (%set-client-view conn :repolist)
                       t)
                      ((:detail :pane-detail) (%set-client-view conn :pane) t)
                      ((:workspace-prefix :prefix-key :rebind-prefix)
                       (%client-rebind-prefix conn (or target (first args)))
                       t)
                      ((:workspace-refresh :vcs-refresh :refresh-workspace)
                       (%client-refresh-workspace conn))
                      ((:tree-up :worktree-up :tree-prev)
                       (%select-client-tree-relative conn
                                                     (-
                                                      (or
                                                       (%parse-client-integer
                                                        (or target (first args)))
                                                       1)))
                       t)
                      ((:tree-down :worktree-down :tree-next)
                       (%select-client-tree-relative conn
                                                     (or
                                                      (%parse-client-integer
                                                       (or target (first args)))
                                                      1))
                       t)
                      (:tree-scroll
                       (%move-client-tree-scroll conn
                                                 (or
                                                  (%parse-client-integer
                                                   (or target (first args)))
                                                  1))
                       t)
                      ((:tree-select :worktree-select)
                       (%select-client-tree-worktree conn
                                                     (or target (first args)))
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
                       (%client-create-worktree conn target args))
                      ((:worktree-delete :delete-worktree :wt-delete)
                       (%client-delete-worktree conn target args))
                      ((:worktree-lock :lock-worktree :wt-lock)
                       (%client-lock-worktree conn target args))
                      ((:worktree-unlock :unlock-worktree :wt-unlock)
                       (%client-unlock-worktree conn target args))
                      ((:worktree-prune-preview :wt-prune :wt-prune-dry-run)
                       (%client-prune-worktrees conn target args :dry-run t))
                      ((:worktree-prune-confirm :wt-prune-confirm)
                       (%client-prune-worktrees conn target args :dry-run nil))
                      (:mode
                       (let ((mode
                              (%client-ui-mode-value (or target (first args)))))
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
                       (%close-client-picker conn)
                       t)
                      ((or
                        (and (eq cmd :cancel)
                             (eq (client-conn-modal conn) :picker))
                        (and (eq cmd :accept)
                             (eq (client-conn-modal conn) :picker)))
                       (if (eq cmd :accept)
                           (%select-client-picker-item session conn)
                           (%close-client-picker conn))
                       t)
                      (:picker-accept (%select-client-picker-item session conn)
                                      t)
                      (:picker-refresh (%refresh-client-picker conn)
                                       (%mark-dirty)
                                       t)
                      ((:picker-next :picker-down :picker-prev :picker-up)
                       (let ((delta
                              (or
                               (%parse-client-integer (or target (first args)))
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
                                                 (or target (first args))
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
                           (%set-client-focus conn pane)
                           (%mark-dirty))
                         t))
                      (:viewport
                       (let ((delta
                              (%parse-client-integer (or target (first args)))))
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
