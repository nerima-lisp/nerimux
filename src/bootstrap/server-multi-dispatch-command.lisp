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
                (msg-reply (if (eq status :denied)
                               (format nil "DENIED~{~%~A~}" descriptions)
                               "OK")))
    (%drop-client conn)
    (if (eq status :ok) :quit t)))

(defun %client-kill-force-p (args)
  "True when a kill command carried --force."
  (and args (member "--force" args :test #'string=) t))

(defun %handle-client-ui-command (session conn cmd target args)
  "Apply a client-local UI command, returning true when CMD is recognized."
  (cond
    ((eq cmd :kill)
     (%handle-client-kill-command session conn args))
    ((eq cmd :attach-target)
     (%client-attach-target conn args))
    ((member cmd '(:overview :workspace-overview :home) :test #'eq)
     (%set-client-view conn :overview)
     t)
    ((member cmd '(:detail :pane-detail) :test #'eq)
     (%set-client-view conn :detail)
     t)
    ((member cmd '(:workspace-prefix :prefix-key :rebind-prefix) :test #'eq)
     (%client-rebind-prefix conn (or target (first args)))
     t)
    ((member cmd '(:workspace-refresh :vcs-refresh :refresh-workspace)
             :test #'eq)
     (%client-refresh-workspace conn))
    ((member cmd '(:tree-up :worktree-up :tree-prev) :test #'eq)
     (%select-client-tree-relative
      conn
      (- (or (%parse-client-integer (or target (first args))) 1)))
     t)
    ((member cmd '(:tree-down :worktree-down :tree-next) :test #'eq)
     (%select-client-tree-relative
      conn
      (or (%parse-client-integer (or target (first args))) 1))
     t)
    ((eq cmd :tree-scroll)
     (%move-client-tree-scroll
      conn
      (or (%parse-client-integer (or target (first args))) 1))
     t)
    ((member cmd '(:tree-select :worktree-select) :test #'eq)
     (%select-client-tree-worktree conn (or target (first args)))
     t)
    ((eq cmd :tree-top)
     (%set-client-selected-tree-object conn (first (%workspace-tree-objects)))
     t)
    ((eq cmd :tree-bottom)
     (%set-client-selected-tree-object conn (car (last (%workspace-tree-objects))))
     t)
    ((member cmd '(:worktree-create :create-worktree :wt-create) :test #'eq)
     (%client-create-worktree conn target args))
    ((member cmd '(:worktree-delete :delete-worktree :wt-delete) :test #'eq)
     (%client-delete-worktree conn target args))
    ((member cmd '(:worktree-lock :lock-worktree :wt-lock) :test #'eq)
     (%client-lock-worktree conn target args))
    ((member cmd '(:worktree-unlock :unlock-worktree :wt-unlock) :test #'eq)
     (%client-unlock-worktree conn target args))
    ((member cmd '(:worktree-prune-preview :wt-prune :wt-prune-dry-run)
             :test #'eq)
     (%client-prune-worktrees conn target args :dry-run t))
    ((member cmd '(:worktree-prune-confirm :wt-prune-confirm) :test #'eq)
     (%client-prune-worktrees conn target args :dry-run nil))
    ((eq cmd :mode)
     (let ((mode (%client-ui-mode-value (or target (first args)))))
       (when mode
         (cond
           ((eq mode :picker)
            (%open-client-picker conn))
           ((eq mode :copy)
            (%client-enter-copy-mode session conn))
           (t
            (%transition-client-ui-mode conn mode)
            (%mark-dirty)))
         t)))
    ((member cmd '(:picker-open :picker :enter-picker) :test #'eq)
     (%open-client-picker conn)
     t)
    ((member cmd '(:picker-close :picker-cancel) :test #'eq)
     (%close-client-picker conn)
     t)
    ((or (and (eq cmd :cancel)
              (eq (client-conn-mode conn) :picker))
         (and (eq cmd :accept)
              (eq (client-conn-mode conn) :picker)))
     (if (eq cmd :accept)
         (%select-client-picker-item session conn)
         (%close-client-picker conn))
     t)
    ((eq cmd :picker-accept)
     (%select-client-picker-item session conn)
     t)
    ((eq cmd :picker-refresh)
     (%refresh-client-picker conn)
     (%mark-dirty)
     t)
    ((member cmd '(:picker-next :picker-down :picker-prev :picker-up)
             :test #'eq)
     (let ((delta (or (%parse-client-integer (or target (first args))) 1)))
       (%move-client-picker-index
        conn
        (if (member cmd '(:picker-prev :picker-up) :test #'eq)
            (- delta)
            delta))
       t))
    ((eq cmd :picker-backspace)
     (%delete-client-picker-query-character conn)
     t)
    ((eq cmd :picker-query)
     (%set-client-picker-query conn (or target (first args) ""))
     t)
    ((eq cmd :picker-regex)
     (%set-client-picker-regex conn
                               (or target (first args))
                               (or target args))
     t)
    ((%client-ui-mode-p cmd)
     (cond
       ((eq cmd :picker)
        (%open-client-picker conn))
       ((eq cmd :copy)
        (%client-enter-copy-mode session conn))
       (t
        (%transition-client-ui-mode conn cmd)
        (%mark-dirty)))
     t)
    ((member cmd '(:enter-normal :enter-input :enter-copy :enter-command
                   :cancel :accept :toggle-copy)
             :test #'eq)
     (cond
       ((or (eq cmd :enter-copy)
            (and (eq cmd :toggle-copy)
                 (not (eq (client-conn-mode conn) :copy))))
        (%client-enter-copy-mode session conn))
       ((and (eq cmd :toggle-copy)
             (eq (client-conn-mode conn) :copy))
        (%client-exit-copy-mode session conn))
       ((and (eq (client-conn-mode conn) :copy)
             (member cmd '(:cancel :accept) :test #'eq))
        (%client-exit-copy-mode session conn))
       (t
        (%transition-client-ui-mode conn cmd)
        (%mark-dirty)))
     t)
    ((eq cmd :focus)
     (let ((pane (%resolve-client-focus-pane
                  session (or target (first args)) conn)))
       (when pane
         (%set-client-focus conn pane)
         (%mark-dirty))
       t))
    ((eq cmd :viewport)
     (let ((delta (%parse-client-integer (or target (first args)))))
       (when delta
         (%move-client-viewport conn delta)
         (%mark-dirty))
       t))
    (t nil)))

(defun %handle-multi-command-message (session conn payload)
  "Run a forwarded client-local UI command, returning the loop disposition."
  (multiple-value-bind (cmd target args) (decode-command-payload payload)
    (let ((result (%handle-client-ui-command session conn cmd target args)))
      (cond
        ;; The handler's own value decides the disposition. This used to be
        ;; discarded to NIL unconditionally, which made :QUIT unreachable from
        ;; any forwarded command however the handler was written -- the key path
        ;; already forwarded its handler's value, which is why C-q d worked and
        ;; nothing on this path could ever stop the server.
        (result (if (eq result :quit) :quit nil))
        ;; Anything the workspace UI does not recognize is rejected.  This used
        ;; to fall through to %dispatch-forwarded-command, which ran the name
        ;; against a server-side command table -- that fallthrough was the only
        ;; thing making the forwarded-command surface reachable from `:`.
        (cmd
         (%client-notify conn (format nil "unknown command: ~(~A~)" cmd))
         (%mark-dirty)
         nil)
        (t (%mark-dirty) nil)))))
