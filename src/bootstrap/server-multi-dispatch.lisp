(in-package #:nerimux)

(defvar *runtime-recovery-items* nil)

(defvar *last-selected-worktree-token* nil
  "Stable selector for the most recently selected worktree across clients.")

;;;; Multi-client message handlers extracted from server-multi.lisp.
;;;;
;;;; The event loop keeps the dispatch table, while these helpers own the
;;;; per-message policy for attach/resize, keys, and forwarded commands.

;;; This macro is defined here (the first file that uses it) so it is available
;;; at compile time for the handlers below AND for server-multi.lisp /
;;; server-multi-loop.lisp, which load after this file.  A prior refactor left
;;; the definition in server-multi.lisp — loaded LATER — so the macro calls
;;; here were compiled as calls to an undefined function, leaving CONDITION an
;;; unbound variable at runtime.
(defmacro with-loop-safe-error (binding &body body)
  "Run BODY, catching any ERROR so one bad client/command can never wedge the
   multi-client event loop.  On success, returns BODY's value; on an ERROR,
   evaluates and returns ON-ERROR instead — optionally with the condition bound
   to CONDITION-VAR so ON-ERROR can log it.  This is the single shape behind
   this file's 'never let one client take down the server loop' invariant."
  (let ((condition-var (first binding))
        (on-error (getf (rest binding) :on-error)))
    `(handler-case (progn ,@body)
       (error ,(if condition-var (list condition-var) '())
         ,on-error))))

(defun %handle-multi-attach-or-resize (session conn type payload)
  "Update CONN's geometry from PAYLOAD, keep attach -r state, refresh client
   ordering for window-size latest, and reapply the effective shared size."
  (multiple-value-bind (rows cols) (decode-size payload)
    (setf (client-conn-rows conn) rows
          (client-conn-cols conn) cols))
  ;; attach-session -r carries read-only state in the optional attach flags byte.
  (when (= type +msg-attach+)
    (setf (client-conn-read-only-p conn)
          (logtest (decode-attach-flags payload) +attach-flag-read-only+)))
  ;; Keep this client most-recent so window-size latest follows the active peer.
  (setf *clients* (cons conn (remove conn *clients*)))
  (%apply-effective-size session)
  nil)

(defun %handle-multi-key-message (session conn payload)
  "Feed PAYLOAD through the stdin-target fast path or the shared key pipeline."
  (multiple-value-bind (prefix-handled prefix-result)
      (%handle-workspace-prefix-key conn payload)
    (if prefix-handled
        prefix-result
        (cond
          ((and (eq (client-conn-mode conn) :normal)
                (%client-byte-p payload 16))
           (%open-client-picker conn))
          ((eq (client-conn-mode conn) :picker)
           (%handle-client-picker-key-payload session conn payload))
          ((eq (client-conn-mode conn) :input)
           (%handle-client-input-key-payload session conn payload))
          ((eq (client-conn-mode conn) :copy)
           (%handle-client-copy-key-payload session conn payload))
          ((eq (client-conn-mode conn) :command)
           (%handle-client-command-key-payload session conn payload))
          ;; A key the workspace UI does not bind is dropped in :normal mode.
          ;; It used to fall through to process-client-keys, the tmux keystroke
          ;; pipeline (prefix key + key tables) -- that fallthrough was the only
          ;; thing making tmux prefix bindings reachable from an attached
          ;; client.  Typing into a pane is what :input mode is for; a
          ;; split-window -I stdin-target still gets fed directly.
          ((eq (client-conn-mode conn) :normal)
           (or (%handle-client-normal-key-payload session conn payload)
               (%feed-client-stdin-target conn payload)))
          (t
           (%feed-client-stdin-target conn payload))))))

(defun %feed-client-stdin-target (conn payload)
  "Feed PAYLOAD to CONN's split-window -I stdin target, if it has one.
   Returns NIL either way: an unbound key is a no-op, not a loop disposition."
  (let ((stdin-target (client-conn-stdin-target conn)))
    (when (and stdin-target (not (client-conn-read-only-p conn)))
      (pane-feed stdin-target payload)
      (%mark-dirty))
    nil))

(defun %handle-workspace-prefix-key (conn payload)
  "Handle the client-local prefix and `d` detach binding.

The prefix is consumed before the stdin-target path, so C-q d always detaches
the terminal connection while leaving the resident panes and runtime intact.
Any non-`d` byte after the prefix is passed through to the normal key pipeline.
"
  (let ((single-byte (and (arrayp payload)
                          (= (length payload) 1)
                          (aref payload 0))))
    (cond
      ((client-conn-ui-prefix-p conn)
       (setf (client-conn-ui-prefix-p conn) nil)
       (if (and (integerp single-byte)
                (= single-byte (char-code #\d)))
           (values t :drop)
           (values nil nil)))
      ((and (integerp single-byte)
            (= single-byte (client-conn-workspace-prefix-code conn)))
       (setf (client-conn-ui-prefix-p conn) t)
       (values t nil))
      (t
       (values nil nil)))))

(defparameter +client-ui-modes+ '(:normal :input :copy :command :picker))

(defun %client-picker-items (conn)
  (or (client-conn-picker-items conn)
      (setf (client-conn-picker-items conn)
            (nerimux/picker:build-global-picker-items
             (nerimux/vcs:workspace-organizations)))))

(defun %picker-clamp-index (conn items)
  (setf (client-conn-picker-index conn)
        (if items
            (min (1- (length items))
                 (max 0 (client-conn-picker-index conn)))
            0)))

(defun %deduplicate-client-picker-items (items)
  (let ((worktrees nil))
    (loop for item in items
          for worktree = (nerimux/picker:picker-item-worktree item)
          unless (and worktree (member worktree worktrees :test #'eq))
            collect (progn
                      (when worktree
                        (push worktree worktrees))
                      item))))

(defun %client-picker-visible-items (conn)
  (let* ((filtered (nerimux/picker:filter-global-picker-items
                    (%client-picker-items conn)
                    (client-conn-picker-query conn)
                    :regex-p (client-conn-picker-regex-p conn)))
         (items (%deduplicate-client-picker-items filtered)))
    (%picker-clamp-index conn items)
    items))

(defun %picker-item-worktree (item)
  (or (nerimux/picker:picker-item-worktree item)
      (let ((repository (nerimux/picker:picker-item-repository item)))
        (or (and repository
                 (or (nerimux/model:repository-main-worktree repository)
                     (first (nerimux/model:repository-worktrees repository))))
            (let ((organization (nerimux/picker:picker-item-organization item)))
              (when organization
                (loop for repository in
                        (nerimux/model:organization-repositories organization)
                      for worktree =
                        (or (nerimux/model:repository-main-worktree repository)
                            (first (nerimux/model:repository-worktrees repository)))
                      when worktree return worktree)))))))

(defun %workspace-worktrees (&optional (organizations (nerimux/vcs:workspace-organizations)))
  "Return the catalog worktrees in stable organization/repository order."
  (loop for organization in organizations
        append (loop for repository in
                         (nerimux/model:organization-repositories organization)
                     append (copy-list
                             (nerimux/model:repository-worktrees repository)))))

(defun %workspace-tree-objects
    (&optional (organizations (nerimux/vcs:workspace-organizations)))
  (loop for organization in organizations
        append
        (cons organization
              (loop for repository in
                        (nerimux/model:organization-repositories organization)
                    append
                    (cons repository
                          (copy-list
                           (nerimux/model:repository-worktrees repository)))))))

(defun %workspace-repository-attention-p (repository)
  (or (nerimux/model:repository-dirty-p repository)
      (nerimux/model:repository-conflict-p repository)
      (plusp (nerimux/model:repository-ahead repository))
      (plusp (nerimux/model:repository-behind repository))
      (nerimux/model:repository-missing-p repository)
      (some #'nerimux/model:worktree-attention-p
            (nerimux/model:repository-worktrees repository))))

(defun %workspace-attention-items
    (&optional (organizations (nerimux/vcs:workspace-organizations))
               (messages nil))
  "Return attention objects in the same order as the attention renderer.

The objects remain the domain instances used by the catalog, so selecting an
entry can focus its pane or return to the matching worktree without parsing a
display label back into a target string."
  (let ((items nil))
    (dolist (organization organizations)
      (dolist (repository (nerimux/model:organization-repositories organization))
        (dolist (worktree (nerimux/model:repository-worktrees repository))
          (when (nerimux/model:worktree-attention-p worktree)
            (push worktree items))
          (dolist (pane (reverse (nerimux/model:worktree-panes worktree)))
            (when (nerimux/model:pane-attention-p pane)
              (push pane items))))
        (when (%workspace-repository-attention-p repository)
          (push repository items))))
    (dolist (recovery-item (reverse *runtime-recovery-items*))
      (push recovery-item items))
    (dolist (message (reverse messages))
      (push message items))
    (nreverse items)))

(defun %attention-clamp-index (conn items)
  (setf (client-conn-attention-index conn)
        (if items
            (min (1- (length items))
                 (max 0 (client-conn-attention-index conn)))
            0)))

(defun %refresh-client-attention
    (conn &optional (organizations (nerimux/vcs:workspace-organizations)))
  (let* ((old-items (client-conn-attention-items conn))
         (old-object (nth (client-conn-attention-index conn) old-items))
         (items (%workspace-attention-items
                 organizations
                 (client-conn-message-log conn)))
         (old-index (and old-object (position old-object items :test #'eq))))
    (setf (client-conn-attention-items conn) items)
    (if old-index
        (setf (client-conn-attention-index conn) old-index)
        (%attention-clamp-index conn items))
    items))

(defun %workspace-worktree-matches-token-p (worktree token)
  (or (eq worktree token)
      (and (stringp token)
           (or (string= token (nerimux/model:worktree-id worktree))
               (string= token (nerimux/model:worktree-path worktree))
               (and (nerimux/model:worktree-branch worktree)
                    (string= token
                             (princ-to-string
                              (nerimux/model:worktree-branch worktree))))))))

(defun %workspace-find-worktree (token &optional (organizations
                                                  (nerimux/vcs:workspace-organizations)))
  (when token
    (find-if (lambda (worktree)
               (%workspace-worktree-matches-token-p worktree token))
             (%workspace-worktrees organizations))))

(defun %workspace-directory-prefix-p (directory path)
  (and (stringp directory)
       (stringp path)
       (let ((prefix (if (and (plusp (length directory))
                              (char= (char directory (1- (length directory)))
                                     #\/))
                         directory
                         (concatenate 'string directory "/"))))
         (or (string= directory path)
             (and (>= (length path) (length prefix))
                  (string= prefix path :end2 (length prefix)))))))

(defun %workspace-find-worktree-for-attach (token organizations)
  (or (%workspace-find-worktree token organizations)
      (find-if (lambda (worktree)
                 (%workspace-directory-prefix-p
                  token
                  (nerimux/model:worktree-path worktree)))
               (%workspace-worktrees organizations))))

(defun %worktree-selection-token (worktree)
  (and worktree
       (or (nerimux/model:worktree-id worktree)
           (nerimux/model:worktree-path worktree)
           (and (nerimux/model:worktree-branch worktree)
                (princ-to-string (nerimux/model:worktree-branch worktree))))))

(defun %organization-selection-token (organization)
  (and organization
       (or (nerimux/model:organization-id organization)
           (and (nerimux/model:organization-host organization)
                (nerimux/model:organization-name organization)
                (format nil "~A/~A"
                        (nerimux/model:organization-host organization)
                        (nerimux/model:organization-name organization))))))

(defun %repository-selection-token (repository)
  (and repository
       (or (nerimux/model:repository-id repository)
           (nerimux/model:repository-specification repository)
           (nerimux/model:repository-local-path repository)
           (nerimux/model:repository-path repository))))

(defun %tree-object-selection-token (object)
  (typecase object
    (nerimux/model:organization
     (list :organization (%organization-selection-token object)))
    (nerimux/model:repository
     (list :repository (%repository-selection-token object)))
    (nerimux/model:worktree
     (list :worktree (%worktree-selection-token object)))))

(defun %client-tree-object (conn)
  (or (client-conn-selected-tree-object conn)
      (client-conn-selected-worktree conn)
      (and (client-conn-focus conn)
           (nerimux/model:pane-worktree (client-conn-focus conn)))))

(defun %client-tree-selection-token (conn)
  (%tree-object-selection-token (%client-tree-object conn)))

(defun %client-selection-token (conn)
  (let ((worktree (or (client-conn-selected-worktree conn)
                      (and (client-conn-focus conn)
                           (nerimux/model:pane-worktree
                            (client-conn-focus conn))))))
    (%worktree-selection-token worktree)))

(defun %client-attach-selection (conn organizations)
  (let* ((explicit (client-conn-attach-target conn))
         (cwd (client-conn-attach-cwd conn))
         (previous (or (%client-selection-token conn)
                       *last-selected-worktree-token*))
         (worktree (or (and (stringp explicit)
                            (plusp (length explicit))
                            (%workspace-find-worktree-for-attach
                             explicit organizations))
                       (and (stringp cwd)
                            (plusp (length cwd))
                            (%workspace-find-worktree-for-attach cwd organizations))
                       (and previous
                            (%workspace-find-worktree previous organizations)))))
    (when worktree
      (%set-client-selected-worktree conn worktree))
    (when (and (stringp explicit)
               (plusp (length explicit))
               organizations
               (null worktree))
      (%client-notify conn (format nil "attach target not found: ~A" explicit)))
    worktree))

(defun %rebind-client-selection (conn organizations)
  (or (%client-attach-selection conn organizations)
      (let* ((token (%client-tree-selection-token conn))
             (object (%workspace-find-tree-object token organizations)))
        (%set-client-selected-tree-object conn object))))

(defun %set-client-selected-tree-object (conn object)
  (let ((worktree (and (typep object 'nerimux/model:worktree) object)))
    (setf (client-conn-selected-tree-object conn) object
          (client-conn-selected-worktree conn) worktree)
    (when worktree
      (setf *last-selected-worktree-token*
            (%worktree-selection-token worktree)))
    (%mark-dirty)
    object))

(defun %set-client-selected-worktree (conn worktree)
  (%set-client-selected-tree-object conn worktree))

(defun %move-client-tree-scroll (conn delta)
  (let* ((objects (%workspace-tree-objects))
         (visible-rows (max 1 (- (client-conn-rows conn) 4)))
         (maximum (max 0 (- (length objects) visible-rows))))
    (when (integerp delta)
      (setf (client-conn-tree-scroll conn)
            (max 0 (min maximum
                        (+ (client-conn-tree-scroll conn) delta))))))
  (%mark-dirty)
  (client-conn-tree-scroll conn))

(defun %select-client-tree-worktree (conn token)
  (let* ((objects (%workspace-tree-objects))
         (object (or (%workspace-find-tree-object token)
                     (%client-tree-object conn)
                     (nth (client-conn-tree-scroll conn) objects))))
    (when object
      (%set-client-selected-tree-object conn object))))

(defun %refresh-client-picker (conn &key on-complete on-error)
  (if (nerimux/vcs:vcs-package-available-p)
      (handler-case
          (nerimux/vcs:refresh-workspace-organizations-async
           :on-complete
           (lambda (organizations)
             (dolist (client
                       (remove-duplicates
                        (remove-if-not #'%client-live-p
                                       (cons conn (copy-list *clients*)))
                        :test #'eq))
               (%rebind-client-selection client organizations)
               (setf (client-conn-picker-items client)
                     (nerimux/picker:build-global-picker-items organizations))
               (%picker-clamp-index client
                                    (%client-picker-visible-items client))
               (%refresh-client-attention client organizations))
             (when (and on-complete (%client-live-p conn))
               (funcall on-complete organizations))
             (%mark-dirty))
           :on-error
           (lambda (condition)
             (when (and on-error (%client-live-p conn))
               (funcall on-error condition))
             (%mark-dirty)))
        (error (condition)
          (when (and on-error (%client-live-p conn))
            (funcall on-error condition))
          (%mark-dirty)))
      (let ((organizations (nerimux/vcs:workspace-organizations)))
        (setf (client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items organizations))
        (%refresh-client-attention conn organizations)
        (when on-complete
          (funcall on-complete organizations))))
  conn)

(defun %open-client-picker (conn)
  (setf (client-conn-mode conn) :picker
        (client-conn-picker-query conn) ""
        (client-conn-picker-regex-p conn) nil
        (client-conn-picker-index conn) 0
        (client-conn-picker-items conn)
        (nerimux/picker:build-global-picker-items
         (nerimux/vcs:workspace-organizations)))
  (%refresh-client-picker conn)
  (%mark-dirty)
  conn)

(defun %close-client-picker (conn)
  (setf (client-conn-mode conn) :normal
        (client-conn-view conn) (if (client-conn-focus conn)
                                    :detail
                                    :overview)
        (client-conn-picker-query conn) ""
        (client-conn-picker-regex-p conn) nil
        (client-conn-picker-index conn) 0)
  (%mark-dirty)
  conn)

(defun %picker-selected-item (conn)
  (let ((items (%client-picker-visible-items conn)))
    (and items
         (nth (client-conn-picker-index conn) items))))

(defun %worktree-window-name (worktree)
  (or (and (worktree-branch worktree)
           (plusp (length (worktree-branch worktree)))
           (worktree-branch worktree))
      (and (worktree-path worktree)
           (plusp (length (worktree-path worktree)))
           (worktree-path worktree))
      (worktree-id worktree)
      "worktree"))

(defun %client-worktree-pane (session worktree)
  (and worktree
       (find worktree
             (all-panes session)
             :key #'nerimux/model:pane-worktree
             :test #'eq)))

(defun %open-client-worktree-pane (session conn worktree)
  (let ((path (and worktree (worktree-path worktree))))
    (cond
      ((null worktree)
       nil)
      ((not (and (stringp path) (plusp (length path))))
       (%client-notify conn "worktree has no path")
       nil)
      ((worktree-missing-p worktree)
       (unless (worktree-missing-p worktree)
         (setf (worktree-missing-p worktree) t)
         (when (worktree-repository worktree)
           (repository-recompute-status (worktree-repository worktree))))
       (%client-notify conn "worktree is missing")
       nil)
      (t
       (handler-case
           (let ((*term-rows* (client-conn-rows conn))
                 (*term-cols* (client-conn-cols conn)))
             (let* ((window (%workspace-new-window
                             session
                             :name (%worktree-window-name worktree)
                             :start-dir path))
                    (pane (window-active-pane window)))
               (if pane
                   (progn
                     (worktree-add-pane worktree pane)
                     (%set-client-selected-worktree conn worktree)
                     (%set-client-focus conn pane)
                     (%mark-dirty)
                     t)
                   (progn
                     (%client-notify conn "worktree pane unavailable")
                     nil))))
         (error (condition)
           (%client-notify
            conn
            (format nil "worktree open failed: ~A" condition))
           nil))))))

(defun %select-client-attention-relative (conn delta)
  (let ((items (%refresh-client-attention conn)))
    (when items
      (setf (client-conn-attention-index conn)
            (max 0
                 (min (1- (length items))
                      (+ (client-conn-attention-index conn) delta)))))
    (%mark-dirty)
    t))

(defun %runtime-recovery-path (item)
  (getf item :worktree-path))

(defun %runtime-recovery-command (item)
  (or (getf item :start-command)
      (and (getf item :pane-state)
           (getf (getf item :pane-state) :start-command))
      ""))

(defun %runtime-recovery-valid-path-p (path)
  (or (null path)
      (and (stringp path)
           (plusp (length path))
           (probe-file path))))

(defun %remove-runtime-recovery-item (item)
  (setf *runtime-recovery-items*
        (remove item *runtime-recovery-items* :test #'eq))
  item)

(defun %recover-client-attention-item (session conn item)
  (let* ((kind (getf item :kind))
         (pane (getf item :pane))
         (path (%runtime-recovery-path item))
         (command (%runtime-recovery-command item)))
    (cond
      ((not (%runtime-recovery-valid-path-p path))
       (%client-notify conn "runtime recovery path is missing"))
      ((eq kind :lost-pane)
       (if (and pane (not (nerimux/model:pane-live-p pane)))
           (handler-case
               (progn
                 (respawn-pane session pane
                               :start-dir path
                               :default-command
                               (and (plusp (length command)) command))
                 (start-reader-thread pane)
                 (let ((window (nerimux/model:pane-window pane)))
                   (when window
                     (nerimux/model:window-select-pane window pane)))
                 (%set-client-focus conn pane)
                 (%remove-runtime-recovery-item item)
                 (%client-notify conn "runtime pane restarted"))
             (error (condition)
               (%client-notify
                conn
                (format nil "runtime pane restart failed: ~A" condition))))
           (%client-notify conn "runtime pane is unavailable")))
      ((eq kind :orphan-pane)
       (handler-case
           (let* ((window (%workspace-new-window
                           session
                           :name (or (getf item :window-name) "recovered")
                           :start-dir path
                           :start-reader-p nil))
                  (new-pane (and window (window-active-pane window))))
             (if new-pane
                 (progn
                   (respawn-pane session new-pane
                                 :start-dir path
                                 :default-command
                                 (and (plusp (length command)) command))
                   (start-reader-thread new-pane)
                   (when (getf item :pane-state)
                     (%runtime-restore-pane-state
                      new-pane
                      (getf item :pane-state)))
                   (setf (pane-dead-status new-pane) nil
                         (pane-dead-signal new-pane) nil
                         (pane-dead-time new-pane) nil
                         (pane-process-exited-p new-pane) nil
                         (pane-non-zero-exit-p new-pane) nil
                         (pane-startup-failed-p new-pane) nil)
                   (let ((worktree (%workspace-find-worktree path)))
                     (when worktree
                       (worktree-add-pane worktree new-pane)
                       (%set-client-selected-worktree conn worktree)))
                   (nerimux/model:window-select-pane window new-pane)
                   (%set-client-focus conn new-pane)
                   (%remove-runtime-recovery-item item)
                   (%client-notify conn "runtime pane recreated"))
                 (%client-notify conn "runtime pane is unavailable")))
         (error (condition)
           (%client-notify
            conn
            (format nil "runtime pane recreation failed: ~A" condition)))))
      (t
       (%client-notify conn "runtime recovery item is unsupported")))
    (%mark-dirty)
    t))

(defun %focus-client-attention (session conn)
  (let* ((items (%refresh-client-attention conn))
         (item (nth (client-conn-attention-index conn) items)))
    (cond
      ((typep item 'nerimux/model:pane)
       (%set-client-focus conn item))
      ((typep item 'nerimux/model:worktree)
       (%set-client-selected-worktree conn item)
       (let ((pane (%client-worktree-pane session item)))
         (if pane
             (%set-client-focus conn pane)
             (%open-client-worktree-pane session conn item))))
      ((typep item 'nerimux/model:repository)
       (let* ((worktree (or (nerimux/model:repository-main-worktree item)
                            (first (nerimux/model:repository-worktrees item))))
              (pane (%client-worktree-pane session worktree)))
         (if worktree
             (progn
               (%set-client-selected-tree-object conn worktree)
               (if pane
                   (%set-client-focus conn pane)
                   (%open-client-worktree-pane session conn worktree)))
             (progn
               (%set-client-selected-tree-object conn item)
               (%client-notify conn "repository has no worktree")))))
      ((and (listp item) (getf item :runtime-recovery-p))
       (%recover-client-attention-item session conn item))
      ((stringp item)
       (%client-notify conn item)))
    (%mark-dirty)
    t))

(defun %select-client-picker-item (session conn)
  (let* ((item (%picker-selected-item conn))
         (worktree (and item (%picker-item-worktree item)))
         (object (or worktree
                     (and item
                          (or (nerimux/picker:picker-item-repository item)
                              (nerimux/picker:picker-item-organization item)))))
         (pane (%client-worktree-pane session worktree))
         (window (and pane (nerimux/model:pane-window pane))))
    (cond
      ((and pane window)
       (nerimux/model:session-select-window session window)
       (nerimux/model:window-select-pane window pane)
       (%set-client-selected-worktree conn worktree)
       (%set-client-focus conn pane)
       (%close-client-picker conn)
       (%mark-dirty)
       t)
      (worktree
       (when (%open-client-worktree-pane session conn worktree)
         (%close-client-picker conn)
         t))
      (object
       (%set-client-selected-tree-object conn object)
       (%close-client-picker conn)
       (%client-notify
        conn
        (typecase object
          (nerimux/model:repository
           "repository selected; use :wt-create --branch <branch> --confirm")
          (nerimux/model:organization
           "organization selected; select a repository first")
          (t "picker item has no worktree")))
       t)
      (t nil))))

(defun %set-client-picker-query (conn value)
  (when (stringp value)
    (setf (client-conn-picker-query conn) value
          (client-conn-picker-index conn) 0)
    (%mark-dirty)
    t))

(defun %set-client-picker-regex (conn value supplied-p)
  (setf (client-conn-picker-regex-p conn)
        (if (not supplied-p)
            (not (client-conn-picker-regex-p conn))
            (cond
              ((member value '(:on "on" "true" "1" t) :test #'equal) t)
              ((member value '(:off "off" "false" "0" nil) :test #'equal) nil)
              (t (client-conn-picker-regex-p conn))))
        (client-conn-picker-index conn) 0)
  (%mark-dirty)
  (client-conn-picker-regex-p conn))

(defun %delete-client-picker-query-character (conn)
  (let ((query (client-conn-picker-query conn)))
    (when (plusp (length query))
      (setf (client-conn-picker-query conn)
            (subseq query 0 (1- (length query)))
            (client-conn-picker-index conn) 0)
      (%mark-dirty)
      t)))

(defun %append-client-picker-query-octets (conn payload)
  (let ((text
          (cond
            ((stringp payload) payload)
            ((vectorp payload)
             (handler-case
                 (cl-codec-kit:octets-to-string payload :encoding :utf-8)
               (error () nil))))))
    (when (and text
               (every (lambda (character)
                        (>= (char-code character) 32))
                      text))
      (setf (client-conn-picker-query conn)
            (concatenate 'string (client-conn-picker-query conn) text)
            (client-conn-picker-index conn) 0)
      (%mark-dirty)
      t)))

(defun %move-client-picker-index (conn delta)
  (let ((items (%client-picker-visible-items conn)))
    (when items
      (setf (client-conn-picker-index conn)
            (mod (+ (client-conn-picker-index conn) delta)
                 (length items)))
      (%mark-dirty)
      t)))

(defun %handle-client-picker-key-payload (session conn payload)
  (cond
    ((or (equalp payload #(13))
         (equalp payload #(10)))
     (%select-client-picker-item session conn))
    ((equalp payload #(27))
     (%close-client-picker conn)
     t)
    ((equalp payload #(18))
     (%set-client-picker-regex conn nil nil))
    ((equalp payload #(27 91 65))
     (%move-client-picker-index conn -1))
    ((equalp payload #(27 91 66))
     (%move-client-picker-index conn 1))
    ((equalp payload #(27 91 67))
     (%move-client-picker-index conn 1))
    ((equalp payload #(27 91 68))
     (%move-client-picker-index conn -1))
    ((or (equalp payload #(8))
         (equalp payload #(127)))
     (%delete-client-picker-query-character conn))
    (t
     (%append-client-picker-query-octets conn payload))))

(defun %client-single-byte (payload)
  (cond
    ((and (arrayp payload) (= (length payload) 1))
     (aref payload 0))
    ((and (stringp payload) (= (length payload) 1))
     (char-code (char payload 0)))))

(defun %client-byte-p (payload byte)
  (eql (%client-single-byte payload) byte))

(defun %client-key-p (payload character)
  (%client-byte-p payload (char-code character)))

(defun %client-key-sequence-p (payload sequence)
  (equalp payload sequence))

(defun %client-payload-text (payload)
  (cond
    ((stringp payload) payload)
    ((vectorp payload)
     (handler-case
         (cl-codec-kit:octets-to-string payload :encoding :utf-8)
       (error () nil)))))

(defun %client-enter-input-mode (conn)
  (%transition-client-ui-mode conn :enter-input)
  (%mark-dirty)
  t)

(defun %client-enter-command-mode (conn &optional (initial-buffer ""))
  (setf (client-conn-command-return-view conn)
        (client-conn-view conn))
  (%transition-client-ui-mode conn :enter-command)
  (setf (client-conn-command-buffer conn)
        (if (stringp initial-buffer) initial-buffer ""))
  (%mark-dirty)
  t)

(defun %client-restore-command-view (conn)
  (let ((view (client-conn-command-return-view conn)))
    (when (member view '(:overview :detail :attention) :test #'eq)
      (setf (client-conn-view conn) view))
    (setf (client-conn-command-return-view conn) nil)))

(defun %client-select-pane-direction (session conn direction)
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (window (and pane (nerimux/model:pane-window pane)))
         (neighbor (and window (pane-neighbor window pane direction))))
    (if neighbor
        (progn
          (%set-client-focus conn neighbor)
          (%mark-dirty)
          t)
        (progn
          (%client-notify conn (format nil "no pane ~A" direction))
          t))))

(defun %client-start-worktree-create (conn)
  (if (%client-selected-repository conn)
      (%client-enter-command-mode conn "wt-create --branch ")
      (%client-notify conn "select a repository to create a worktree"))
  t)

(defun %client-start-worktree-delete (conn)
  (if (%client-operation-worktree conn)
      (%client-enter-command-mode conn "wt-delete --confirm")
      (%client-notify conn "select a worktree to delete"))
  t)

(defun %focus-selected-client-worktree (session conn)
  (unless (client-conn-selected-worktree conn)
    (%select-client-tree-worktree conn nil))
  (let* ((object (%client-tree-object conn))
         (worktree (client-conn-selected-worktree conn))
         (pane (%client-worktree-pane session worktree)))
    (cond
      (pane
       (%set-client-focus conn pane)
       (%mark-dirty)
       t)
      (worktree
       (or (%open-client-worktree-pane session conn worktree) t))
      ((typep object 'nerimux/model:repository)
       (%client-start-worktree-create conn))
      ((typep object 'nerimux/model:organization)
       (%client-start-worktree-create conn))
      (t
       (%client-notify conn "no worktree selected")
       t))))

(defun %handle-client-normal-key-payload (session conn payload)
  (let ((view (client-conn-view conn)))
    (cond
      ((or (%client-key-sequence-p payload #(27 91 65))
           (%client-key-p payload #\k))
       (case view
         (:overview (%select-client-tree-relative conn -1) t)
         (:detail (%client-select-pane-direction session conn :up))
         (:attention (%select-client-attention-relative conn -1))
         (otherwise nil)))
      ((or (%client-key-sequence-p payload #(27 91 66))
           (%client-key-p payload #\j))
       (case view
         (:overview (%select-client-tree-relative conn 1) t)
         (:detail (%client-select-pane-direction session conn :down))
         (:attention (%select-client-attention-relative conn 1))
         (otherwise nil)))
      ((or (%client-key-sequence-p payload #(27 91 67))
           (%client-key-p payload #\l))
       (if (eq view :detail)
           (%client-select-pane-direction session conn :right)
           nil))
      ((or (%client-key-sequence-p payload #(27 91 68))
           (%client-key-p payload #\h))
       (if (eq view :detail)
           (%client-select-pane-direction session conn :left)
           nil))
      ((or (%client-byte-p payload 13) (%client-byte-p payload 10))
       (cond
         ((eq view :overview)
          (%focus-selected-client-worktree session conn))
         ((eq view :attention)
          (%focus-client-attention session conn))
         (t t)))
      ((and (eq view :overview) (%client-key-p payload #\n))
       (%client-start-worktree-create conn))
      ((and (eq view :overview) (%client-key-p payload #\X))
       (%client-start-worktree-delete conn))
      ((%client-key-p payload #\d)
       (%set-client-view conn :detail)
       t)
      ((%client-key-p payload #\o)
       (%set-client-view conn :overview)
       t)
      ((%client-key-p payload #\a)
       (%set-client-view conn :attention)
       t)
      ((%client-key-p payload #\r)
       (%client-refresh-workspace conn)
       t)
      ((%client-key-p payload #\i)
       (%client-enter-input-mode conn))
      ((%client-key-p payload #\c)
       (%client-enter-copy-mode session conn)
       t)
      ((%client-key-p payload #\:)
       (%client-enter-command-mode conn))
      (t nil))))

(defun %handle-client-input-key-payload (session conn payload)
  (if (%client-byte-p payload 27)
      (progn
        (%transition-client-ui-mode conn :enter-normal)
        (%mark-dirty)
        t)
      (if (client-conn-read-only-p conn)
          t
          (let ((pane (or (client-conn-stdin-target conn)
                          (%resolve-client-focus-pane session nil conn))))
            (cond
              ((null pane)
               (%client-notify conn "no focused pane"))
              ((pane-live-p pane)
               (handler-case
                   (nerimux/pty:pty-write (pane-fd pane) payload)
                 (error (condition)
                   (%client-notify
                    conn
                    (format nil "input failed: ~A" condition)))))
              ((pane-screen pane)
               (pane-feed pane payload))
              (t
               (%client-notify conn "focused pane is unavailable")))
            (%mark-dirty)
            t))))

(defun %handle-client-copy-key-payload (session conn payload)
  (cond
    ((%client-byte-p payload 27)
     (%client-exit-copy-mode session conn))
    (t
     (let* ((pane (%resolve-client-focus-pane session nil conn))
            (screen (and pane (pane-screen pane))))
       (cond
         ((null screen)
          (%client-notify conn "no focused pane")
          (%transition-client-ui-mode conn :enter-normal))
         ((or (%client-key-sequence-p payload #(27 91 65))
              (%client-key-p payload #\k))
          (copy-mode-move-cursor screen :up))
         ((or (%client-key-sequence-p payload #(27 91 66))
              (%client-key-p payload #\j))
          (copy-mode-move-cursor screen :down))
         ((or (%client-key-sequence-p payload #(27 91 68))
              (%client-key-p payload #\h))
          (copy-mode-move-cursor screen :left))
         ((or (%client-key-sequence-p payload #(27 91 67))
              (%client-key-p payload #\l))
          (copy-mode-move-cursor screen :right))
         ((%client-key-p payload #\g)
          (copy-mode-scroll screen most-positive-fixnum))
         ((%client-key-p payload #\G)
          (copy-mode-scroll screen (- most-positive-fixnum)))
         ((%client-key-p payload #\Space)
          (copy-mode-begin-selection screen))
         ((%client-key-p payload #\y)
          (copy-mode-yank screen))
         ((%client-key-p payload #\n)
          (copy-mode-search-next screen))
         ((%client-key-p payload #\N)
          (copy-mode-search-prev screen))
         ((%client-key-p payload #\/)
          (%client-enter-command-mode conn "search-forward "))
         ((%client-key-p payload #\?)
          (%client-enter-command-mode conn "search-backward "))
         ((%client-key-p payload #\q)
          (%client-exit-copy-mode session conn)))
       (%mark-dirty)
       t))))

(defun %client-command-buffer-delete-character (conn)
  (let ((buffer (client-conn-command-buffer conn)))
    (when (plusp (length buffer))
      (setf (client-conn-command-buffer conn)
            (subseq buffer 0 (1- (length buffer))))
      (%mark-dirty)
      t)))

(defun %client-command-buffer-append (conn payload)
  (let ((text (%client-payload-text payload)))
    (when (and text
               (every (lambda (character)
                        (>= (char-code character) 32))
                      text))
      (setf (client-conn-command-buffer conn)
            (concatenate 'string (client-conn-command-buffer conn) text))
      (%mark-dirty)
      t)))

(defun %client-command-target-and-args (args)
  (if (and (stringp (first args))
           (member (first args) '("-t" "--target") :test #'string=))
      (values (second args) (cddr args))
      (values nil args)))

(defun %client-search-direction (name)
  (cond
    ((member name '("search-forward" "/") :test #'string-equal) :forward)
    ((member name '("search-backward" "?") :test #'string-equal) :backward)))

(defun %client-search-term (args)
  (string-trim '(#\Space #\Tab)
               (format nil "~{~A~^ ~}" args)))

(defun %submit-client-search (session conn direction args)
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (screen (and pane (pane-screen pane)))
         (term (%client-search-term args)))
    (cond
      ((null screen)
       (%client-notify conn "no focused pane"))
      ((zerop (length term))
       (%client-notify conn "search term is empty"))
      ((eq direction :forward)
       (copy-mode-search-forward screen term))
      ((eq direction :backward)
       (copy-mode-search-backward screen term)))
    (%client-restore-command-view conn)
    (%transition-client-ui-mode
     conn
     (if (and screen (screen-copy-mode-p screen))
         :enter-copy
         :enter-normal))
    (%mark-dirty)))

(defun %submit-client-command (session conn)
  (let ((input (string-trim '(#\Space #\Tab)
                            (client-conn-command-buffer conn))))
    (setf (client-conn-command-buffer conn) "")
    (if (zerop (length input))
        (progn
          (%client-restore-command-view conn)
          (%transition-client-ui-mode conn :enter-normal)
          (%mark-dirty))
        (handler-case
            (let* ((tokens (tokenize-command-string input))
                   (name (first tokens))
                   (cmd (and name (intern (string-upcase name) :keyword)))
                   (search-direction (%client-search-direction name)))
              (if search-direction
                  (multiple-value-bind (target args)
                      (%client-command-target-and-args (rest tokens))
                    (declare (ignore target))
                    (%submit-client-search session conn search-direction args))
                  (progn
                    (let ((handled-p nil))
                      (if cmd
                          (multiple-value-bind (target args)
                              (%client-command-target-and-args (rest tokens))
                            (setf handled-p
                                  (%handle-client-ui-command
                                   session conn cmd target args))
                            (unless handled-p
                              (%client-notify
                               conn
                               (format nil "unknown command: ~(~A~)" cmd))))
                          (%client-notify conn "empty command"))
                      (unless handled-p
                        (%client-restore-command-view conn)))
                    (%transition-client-ui-mode conn :enter-normal)
                    (%mark-dirty))))
          (error (condition)
            (%client-notify
             conn
             (format nil "command failed: ~A" condition))
            (%client-restore-command-view conn)
            (%transition-client-ui-mode conn :enter-normal)
            (%mark-dirty)))))
  t)

(defun %handle-client-command-key-payload (session conn payload)
  (cond
    ((%client-byte-p payload 27)
     (setf (client-conn-command-buffer conn) "")
     (%client-restore-command-view conn)
     (%transition-client-ui-mode conn :enter-normal)
     (%mark-dirty)
     t)
    ((or (%client-byte-p payload 13) (%client-byte-p payload 10))
     (%submit-client-command session conn))
    ((or (%client-byte-p payload 8) (%client-byte-p payload 127))
     (%client-command-buffer-delete-character conn)
     t)
    (t
     (%client-command-buffer-append conn payload)
     t)))

(defun %client-ui-mode-p (mode)
  (member mode +client-ui-modes+ :test #'eq))

(defun %client-ui-mode-value (value)
  (let ((name (cond ((stringp value) value)
                    ((symbolp value) (symbol-name value)))))
    (when name
      (let ((mode (intern (string-upcase name) :keyword)))
        (and (%client-ui-mode-p mode) mode)))))

(defun %set-client-ui-mode (conn mode)
  (when (%client-ui-mode-p mode)
    (setf (client-conn-mode conn) mode)
    (when (member mode '(:input :copy :command) :test #'eq)
      (setf (client-conn-view conn) :detail)))
  (client-conn-mode conn))

(defun %transition-client-ui-mode (conn event)
  (let* ((current (client-conn-mode conn))
         (next
          (cond
            ((%client-ui-mode-p event) event)
            ((eq event :enter-normal) :normal)
            ((eq event :enter-input) :input)
            ((eq event :enter-copy) :copy)
            ((eq event :enter-command) :command)
            ((eq event :enter-picker) :picker)
            ((member event '(:cancel :accept) :test #'eq) :normal)
            ((eq event :toggle-copy)
             (if (eq current :copy) :normal :copy))
            (t current))))
    (%set-client-ui-mode conn next)
    (when (and (eq next :command) (not (eq current :command)))
      (setf (client-conn-command-buffer conn) ""))
    (when (and (not (eq next :command)) (eq current :command))
      (setf (client-conn-command-buffer conn) "")
      (%client-restore-command-view conn))
    next))

(defun %set-client-focus (conn pane)
  (setf (client-conn-focus conn) pane
        (client-conn-viewport conn) 0
        (client-conn-view conn) :detail)
  (when pane
    (nerimux/model:pane-mark-focused pane))
  pane)

(defun %set-client-view (conn view)
  (when (member view '(:overview :detail :attention) :test #'eq)
    (setf (client-conn-view conn) view
          (client-conn-mode conn) :normal)
    (when (eq view :attention)
      (%refresh-client-attention conn))
    (%mark-dirty))
  (client-conn-view conn))

(defun %resolve-client-focus-pane (session token &optional conn)
  (let ((window (session-active-window session)))
    (if token
        (and window (find-pane-by-target window token))
        (or (and conn
                 (client-conn-focus conn)
                 (find (client-conn-focus conn)
                       (all-panes session)
                       :test #'eq))
            (and window (window-active-pane window))))))

(defun %client-enter-copy-mode (session conn)
  (let ((pane (%resolve-client-focus-pane session nil conn)))
    (if (and pane (pane-screen pane))
        (progn
          (copy-mode-enter (pane-screen pane))
          (%set-client-focus conn pane)
          (%transition-client-ui-mode conn :enter-copy)
          (%mark-dirty)
          t)
        (progn
          (%client-notify conn "no focused pane")
          nil))))

(defun %client-exit-copy-mode (session conn)
  (let ((pane (%resolve-client-focus-pane session nil conn)))
    (when (and pane (pane-screen pane)
               (screen-copy-mode-p (pane-screen pane)))
      (copy-mode-exit (pane-screen pane)))
    (%transition-client-ui-mode conn :enter-normal)
    (%mark-dirty)
    t))

(defun %parse-client-integer (value)
  (and (stringp value)
       (ignore-errors (parse-integer value))))

(defun %move-client-viewport (conn delta)
  (when (integerp delta)
    (setf (client-conn-viewport conn)
          (max 0 (+ (client-conn-viewport conn) delta))))
  (client-conn-viewport conn))

(defun %client-option-value (args names)
  (loop for tail on args
        for arg = (first tail)
        when (stringp arg)
          do (dolist (name names)
               (when (string-equal arg name)
                 (return-from %client-option-value (second tail)))
               (when (and (> (length arg) (length name))
                          (string-equal name arg :end2 (length name))
                          (char= (char arg (length name)) #\=))
                 (return-from %client-option-value
                   (subseq arg (1+ (length name))))))))

(defun %client-boolean-option-p (args names)
  (some (lambda (arg)
          (and (stringp arg)
               (some (lambda (name) (string-equal arg name)) names)))
        args))

(defun %parse-client-key-code (value)
  (cond
    ((integerp value) value)
    ((stringp value)
     (let ((text (string-downcase value)))
       (cond
         ((member text '("c-q" "control-q" "control q") :test #'string=)
          #x11)
         ((member text '("c-b" "control-b" "control b") :test #'string=)
          #x02)
         ((= (length text) 1) (char-code (char text 0)))
         ((ignore-errors (parse-integer text)))
         (t nil))))
    (t nil)))

(defun %client-live-p (conn)
  (member conn *clients* :test #'eq))

(defun %client-attach-target (conn args)
  (let ((target (first args))
        (cwd (second args)))
    (setf (client-conn-attach-target conn)
          (and (stringp target) (plusp (length target)) target)
          (client-conn-attach-cwd conn)
          (and (stringp cwd) (plusp (length cwd)) cwd))
    (%client-attach-selection conn (nerimux/vcs:workspace-organizations))
    (%mark-dirty)
    t))

(defun %client-notify (conn message)
  (let ((text (if (stringp message) message (princ-to-string message))))
    (when (%client-live-p conn)
      (let ((log (cons text (client-conn-message-log conn))))
        (setf (client-conn-message-log conn)
              (subseq log 0 (min 64 (length log))))
        (when (client-conn-focus conn)
          (pane-notify (client-conn-focus conn) text))
        (%mark-dirty)))
    text))

(defun %client-positional-branch (args)
  (let ((skip-next nil))
    (dolist (arg args)
      (cond
        (skip-next
         (setf skip-next nil))
        ((and (stringp arg)
              (member arg
                      '("--branch" "-b" "branch"
                        "--path" "path"
                        "--path-template" "path-template")
                      :test #'string-equal))
         (setf skip-next t))
        ((and (stringp arg)
              (plusp (length arg))
              (char/= (char arg 0) #\-)
              (not (member arg '("confirm" "existing" "force")
                             :test #'string-equal)))
         (return-from %client-positional-branch arg))))))

(defun %workspace-find-repository
    (token &optional (organizations (nerimux/vcs:workspace-organizations)))
  (when token
    (dolist (organization organizations)
      (dolist (repository
                (nerimux/model:organization-repositories organization))
        (when (or (eq repository token)
                  (and (stringp token)
                       (some (lambda (value)
                               (and value
                                    (string= token
                                             (princ-to-string value))))
                             (list (nerimux/model:repository-id repository)
                                   (nerimux/model:repository-specification repository)
                                   (nerimux/model:repository-local-path repository)
                                   (nerimux/model:repository-path repository)))))
          (return-from %workspace-find-repository repository))))))

(defun %workspace-find-organization
    (token &optional (organizations (nerimux/vcs:workspace-organizations)))
  (when token
    (find-if
     (lambda (organization)
       (or (eq organization token)
           (and (stringp token)
                (some (lambda (value)
                        (and value
                             (string= token (princ-to-string value))))
                      (list (nerimux/model:organization-id organization)
                            (nerimux/model:organization-host organization)
                            (nerimux/model:organization-name organization)
                            (%organization-selection-token organization))))))
     organizations)))

(defun %workspace-find-tree-object
    (token &optional (organizations (nerimux/vcs:workspace-organizations)))
  (cond
    ((typep token 'nerimux/model:organization) token)
    ((typep token 'nerimux/model:repository) token)
    ((typep token 'nerimux/model:worktree) token)
    ((and (consp token) (keywordp (first token)))
     (case (first token)
       (:organization
        (%workspace-find-organization (second token) organizations))
       (:repository
        (%workspace-find-repository (second token) organizations))
       (:worktree
        (%workspace-find-worktree (second token) organizations))))
    ((stringp token)
     (or (%workspace-find-worktree token organizations)
         (%workspace-find-repository token organizations)
         (%workspace-find-organization token organizations)))))

(defun %client-selected-repository (conn &optional target)
  (let ((object
          (or (%workspace-find-tree-object target)
              (%client-tree-object conn)
              (%workspace-find-tree-object (%client-selection-token conn))
              (and (client-conn-focus conn)
                   (nerimux/model:pane-worktree (client-conn-focus conn))))))
    (typecase object
      (nerimux/model:repository object)
      (nerimux/model:worktree
       (nerimux/model:worktree-repository object))
      (nerimux/model:organization
       (let ((repositories
               (nerimux/model:organization-repositories object)))
         (and (= (length repositories) 1)
              (first repositories)))))))

(defun %client-operation-worktree (conn &optional target)
  (or (%workspace-find-worktree target)
      (and (typep (%client-tree-object conn) 'nerimux/model:worktree)
           (%client-tree-object conn))
      (and (client-conn-focus conn)
           (nerimux/model:pane-worktree (client-conn-focus conn)))))

(defun %select-client-tree-relative (conn delta)
  (let* ((objects (%workspace-tree-objects))
         (count (length objects)))
    (when (plusp count)
      (let* ((current (%client-tree-object conn))
             (index (or (and current
                             (position current objects :test #'eq))
                        (if (minusp delta) 0 -1)))
             (next (max 0 (min (1- count) (+ index delta))))
             (visible (max 1 (- (client-conn-rows conn) 4))))
        (%set-client-selected-tree-object conn (nth next objects))
        (when (< next (client-conn-tree-scroll conn))
          (setf (client-conn-tree-scroll conn) next))
        (when (>= next (+ (client-conn-tree-scroll conn) visible))
          (setf (client-conn-tree-scroll conn)
                (max 0 (+ next 1 (- visible)))))
        (%mark-dirty)
        (nth next objects)))))

(defun %client-refresh-workspace (conn)
  (%client-notify conn "workspace refresh started")
  (%refresh-client-picker
   conn
   :on-complete (lambda (organizations)
                  (declare (ignore organizations))
                  (%client-notify conn "workspace refresh complete"))
   :on-error (lambda (condition)
               (%client-notify
                conn
                (format nil "workspace refresh failed: ~A" condition))))
  t)

(defun %client-rebind-prefix (conn value)
  (let ((code (%parse-client-key-code value)))
    (if (and (integerp code) (<= 1 code) (<= code 255))
        (progn
          (setf (client-conn-workspace-prefix-code conn) code
                (client-conn-ui-prefix-p conn) nil)
          (%client-notify
           conn
           (format nil "workspace prefix set to ~D" code))
          t)
        (progn
          (%client-notify conn "invalid workspace prefix key")
          t))))

(defun %client-create-worktree (conn target args)
  (if (not (%client-boolean-option-p args '("--confirm" "confirm")))
      (progn
        (%client-notify conn "worktree create requires --confirm")
        t)
      (let* ((repository (%client-selected-repository conn target))
             (branch (or (%client-option-value args
                                               '("--branch" "-b" "branch"))
                         (%client-positional-branch args)))
             (path (%client-option-value args '("--path" "path")))
             (path-template
               (%client-option-value
                args '("--path-template" "path-template")))
             (new-branch-p
               (not (%client-boolean-option-p
                     args '("--existing" "--no-new-branch" "existing"))))
             (force (%client-boolean-option-p args '("--force" "force"))))
        (cond
          ((not repository)
           (%client-notify conn "worktree create requires a repository")
           t)
          ((not (and (stringp branch) (plusp (length branch))))
           (%client-notify conn "worktree create requires a branch")
           t)
          ((not (nerimux/vcs:vcs-package-available-p))
           (%client-notify conn "VCS adapter unavailable")
           t)
          (t
           (%client-notify
            conn
            (format nil "creating worktree ~A" branch))
           (handler-case
               (nerimux/vcs:create-worktree-async
                repository
                :branch branch
                :path path
                :path-template path-template
                :new-branch-p new-branch-p
                :force force
                :on-complete
                (lambda (worktree)
                  (when (%client-live-p conn)
                    (%set-client-selected-worktree conn worktree))
                  (%refresh-client-picker conn)
                  (%client-notify conn "worktree created")
                  (%mark-dirty))
                :on-error
                (lambda (condition)
                  (%client-notify
                   conn
                   (format nil "worktree create failed: ~A" condition))))
             (error (condition)
               (%client-notify
                conn
                (format nil "worktree create failed: ~A" condition))))
           t)))))

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
          ((not (nerimux/vcs:vcs-package-available-p))
           (%client-notify conn "VCS adapter unavailable")
           t)
          (t
           (%client-notify
            conn
            (format nil "deleting worktree ~A"
                    (nerimux/model:worktree-path worktree)))
           (handler-case
               (nerimux/vcs:delete-worktree-async
                worktree
                :force force
                :on-complete
                (lambda (ignored)
                  (declare (ignore ignored))
                  (when (and (%client-live-p conn)
                             (eq (client-conn-selected-worktree conn)
                                 worktree))
                    (setf (client-conn-selected-tree-object conn) nil
                          (client-conn-selected-worktree conn) nil))
                  (%refresh-client-picker conn)
                  (%client-notify conn "worktree deleted")
                  (%mark-dirty))
                :on-error
                (lambda (condition)
                  (%client-notify
                   conn
                   (format nil "worktree delete failed: ~A" condition))))
             (error (condition)
               (%client-notify
                conn
                (format nil "worktree delete failed: ~A" condition))))
           t)))))

(defun %handle-client-ui-command (session conn cmd target args)
  "Apply a client-local UI command, returning true when CMD is recognized."
  (cond
    ((eq cmd :attach-target)
     (%client-attach-target conn args))
    ((member cmd '(:overview :workspace-overview :home) :test #'eq)
     (%set-client-view conn :overview)
     t)
    ((member cmd '(:attention :workspace-attention :attention-view) :test #'eq)
     (%set-client-view conn :attention)
     t)
    ((member cmd '(:attention-up :attention-prev) :test #'eq)
     (%select-client-attention-relative
      conn
      (- (or (%parse-client-integer (or target (first args))) 1)))
     t)
    ((member cmd '(:attention-down :attention-next) :test #'eq)
     (%select-client-attention-relative
      conn
      (or (%parse-client-integer (or target (first args))) 1))
     t)
    ((member cmd '(:attention-select :attention-open) :test #'eq)
     (%focus-client-attention session conn)
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
  "Run a forwarded command or detach other clients, returning the loop disposition."
  (multiple-value-bind (cmd target args) (decode-command-payload payload)
    (cond
      ;; The one built-in control command: drop all OTHER clients (attach -d).
      ((eq cmd :detach-other-clients) :detach-others)
      ((%handle-client-ui-command session conn cmd target args) nil)
      ;; Anything the workspace UI does not recognize is rejected.  This used to
      ;; fall through to %dispatch-forwarded-command, which ran the name against
      ;; the tmux command table server-side -- that fallthrough was the only
      ;; thing making the tmux command surface reachable from the `:` prompt.
      (cmd
       (%client-notify conn (format nil "unknown command: ~(~A~)" cmd))
       (%mark-dirty)
       nil)
      (t (%mark-dirty) nil))))

;;; ── Per-client message dispatch ─────────────────────────────────────────────

(defun %client-command-token-name (value)
  (cond ((stringp value) (string-downcase value))
        ((symbolp value) (string-downcase (symbol-name value)))))

(defun %client-direction-flag (value)
  (let ((name (%client-command-token-name value)))
    (and name
         (cdr (assoc name
                     '(("left" . "-L")
                       ("right" . "-R")
                       ("up" . "-U")
                       ("down" . "-D"))
                     :test #'string=)))))

(defun %client-directional-args (args)
  (let ((flag (%client-direction-flag (first args))))
    (if flag
        (cons flag (rest args))
        args)))

(defun %client-split-args (args)
  (let ((first (%client-command-token-name (first args))))
    (cond
      ((null first) (list "-v"))
      ((member first '("-h" "-v") :test #'string=) args)
      ((member first '("horizontal" "h") :test #'string=)
       (cons "-h" (rest args)))
      ((member first '("vertical" "v") :test #'string=)
       (cons "-v" (rest args)))
      (t (cons "-v" args)))))

(defun %client-restart-args (args)
  (if (some (lambda (arg)
              (and (stringp arg) (string= arg "-k")))
            args)
      args
      (cons "-k" args)))

(defun %canonical-client-command (cmd target args)
  "Translate the UI command vocabulary to the existing tmux dispatcher."
  (case cmd
    (:close (values :kill-pane target args))
    (:restart (values :respawn-pane target (%client-restart-args args)))
    (:split (values :split-window target (%client-split-args args)))
    (:resize (values :resize-pane target (%client-directional-args args)))
    (:rename (values :rename-window target args))
    (:move (values :select-pane target (%client-directional-args args)))
    (:swap (values :swap-pane target (%client-directional-args args)))
    (:layout (values :select-layout target args))
    (otherwise (values cmd target args))))

;;; define-multi-msg-dispatch builds %handle-multi-client-message from a
;;; declarative rule table, delegating to define-message-dispatch-fn (server.lisp)
;;; so both event loops share the same COND-expansion engine.  TYPE, PAYLOAD,
;;; SESSION, and CONN are bound in every rule body.

(defmacro define-multi-msg-dispatch (&rest rules)
  "Build %handle-multi-client-message from a declarative message-type rule table.
   Each RULE is (condition &rest body).  TYPE, PAYLOAD, SESSION, and CONN are
   bound in every rule body.  Delegates to define-message-dispatch-fn (defined in
   server.lisp) so the single-client and multi-client dispatch macros share the
   same COND-expansion engine and cannot structurally diverge."
  `(define-message-dispatch-fn
       %handle-multi-client-message
       (type payload session conn)
       "Dispatch one message of TYPE/PAYLOAD from client CONN.  Returns a disposition:
     :quit           — a command ended the session (loop must stop);
     :drop           — CONN should be removed (EOF / detach / unknown type);
     :detach-others  — drop every OTHER client (the `attach -d` request);
     NIL             — keep serving.
   Resize/attach updates CONN's geometry and re-applies the effective size; keys
   run through the shared prefix/copy-mode pipeline with CONN's private state."
     ,@rules))
