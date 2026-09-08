(in-package #:nerimux)

(defun %client-transient-active-flags (conn transient-key)
  (cdr (assoc transient-key (client-conn-transient-arguments conn))))

(defun %client-transient-toggle-flag (conn transient-key flag)
  "Flip FLAG's membership in TRANSIENT-KEY's active-flag list, kept on CONN
   for the rest of the session (FR-010) -- reopening the same transient later
   must see the same toggle state, not a fresh one."
  (let* ((alist (client-conn-transient-arguments conn))
         (current (cdr (assoc transient-key alist)))
         (updated
          (if (member flag current :test #'string=)
              (remove flag current :test #'string=)
              (cons flag current))))
    (setf (client-conn-transient-arguments conn) (cons
                                                  (cons transient-key updated)
                                                  (remove transient-key
                                                          alist
                                                          :key
                                                          #'car)))))

(defun %client-log-process (conn command success-p output)
  "Record one finished git write as a (COMMAND EXIT-STATUS OUTPUT) entry,
   most recent first -- EXIT-STATUS is \"0\"/\"1\" rather than a real process
   exit code, because GIT-WRITE-OPERATION-ASYNC only ever hands back
   SUCCESS-P, never the underlying number."
  (push
   (list command
         (if success-p
             "0"
             "1")
         (or output ""))
   (client-conn-process-log conn))
  (when (> (length (client-conn-process-log conn)) +max-process-log-entries+)
    (setf (client-conn-process-log conn) (subseq (client-conn-process-log conn)
                                                 0
                                                 +max-process-log-entries+)))
  (%mark-dirty))

(defun %transient-command-text (operation args)
  (format nil "git ~(~A~)~{ ~A~}" operation args))

(defun %run-transient-git-write (conn repository operation args)
  (let ((command (%transient-command-text operation args)))
    (%client-notify conn (format nil "running ~A" command))
    (nerimux/vcs:git-write-operation-async repository
                                           operation
                                           args
                                           :callback-dispatch
                                           #'%enqueue-main-thread-callback
                                           :on-complete
                                           (lambda (success-p output)
                                             (%client-log-process conn
                                                                  command
                                                                  success-p
                                                                  output)
                                             (if success-p
                                                 (progn
                                                   (%refresh-client-picker conn)
                                                   (%client-notify conn
                                                                   (format nil
                                                                           "~A: done"
                                                                           command)))
                                                 (%client-notify conn
                                                                 (format nil
                                                                         "~A: failed"
                                                                         command))))
                                           :on-error
                                           (lambda (condition)
                                             (%client-log-process conn
                                                                  command
                                                                  nil
                                                                  (princ-to-string
                                                                   condition))
                                             (%client-notify conn
                                             (format nil
                                                     "~A: failed: ~A"
                                                     command
                                                     condition))))))

(defun %client-read-view-worktree (conn)
  (or (client-conn-selected-worktree conn)
      (%client-operation-worktree conn)))

(defun %client-read-view-title (kind)
  (case kind
    (:log "GIT LOG")
    (:diff "GIT DIFF")
    (otherwise "READ VIEW")))

(defun %close-client-read-view (conn &optional swallow-escape-p)
  (when swallow-escape-p
    (%client-esc-swallow-start conn))
  (setf (client-conn-read-view conn) nil
        (client-conn-read-view-worktree conn) nil
        (client-conn-read-search-widget conn) nil)
  (%set-client-modal conn nil))

(defun %open-client-read-view (conn kind)
  (let ((worktree (%client-read-view-worktree conn)))
    (cond
      ((null worktree) (%client-notify conn "no worktree selected"))
      ((not (nerimux/vcs:vcs-package-available-p))
       (%client-notify conn "VCS unavailable"))
      (t
       (let ((view (nerimux/renderer:make-read-view
                    (%client-read-view-title kind)
                    "Loading...\n")))
         (setf (client-conn-read-view conn) view
               (client-conn-read-view-worktree conn) worktree
               (client-conn-read-search-widget conn) nil)
         (%set-client-modal conn :read-view)
         (flet ((complete (content)
                  (when (eq (client-conn-read-view conn) view)
                    (setf (nerimux/renderer:read-view-content view)
                          (or content "")
                          (nerimux/renderer:read-view-query view) nil)
                    (%mark-dirty)))
                (failed (condition)
                  (when (eq (client-conn-read-view conn) view)
                    (setf (nerimux/renderer:read-view-content view)
                          (format nil "Unable to read ~A: ~A~%"
                                  (string-downcase
                                   (%client-read-view-title kind))
                                  condition))
                    (%mark-dirty))))
           (case kind
             (:log
              (nerimux/vcs:read-worktree-log-async
               worktree
               :callback-dispatch #'%enqueue-main-thread-callback
               :on-complete #'complete
               :on-error #'failed))
             (:diff
              (nerimux/vcs:read-worktree-diff-async
               worktree
               :callback-dispatch #'%enqueue-main-thread-callback
               :on-complete #'complete
               :on-error #'failed)))
           t))))))

(defun %client-text-prompt-spec (kind conn)
  (case kind
    (:commit-message
     (list "Commit message"
           (cl-tui-kit/widgets:make-textarea-widget
            :placeholder "commit message"
            :preferred-rows 6
            :soft-wrap-p t
            :submit-on-enter-p nil
            :focusable-p t
            :semantic-role :textbox)
           :commit
           nil))
    (:branch-create
     (list "Create branch"
           (cl-tui-kit/widgets:make-input-widget
            :placeholder "branch name"
            :focusable-p t
            :semantic-role :textbox)
           :branch
           nil))
    (:tag-create
     (list "Create tag"
           (cl-tui-kit/widgets:make-input-widget
            :placeholder "tag name"
            :focusable-p t
            :semantic-role :textbox)
           :tag
           nil))
    (:remote-push
     (list "Push to remote"
           (cl-tui-kit/widgets:make-input-widget
            :placeholder "remote name"
            :focusable-p t
            :semantic-role :textbox)
           :push
           (copy-list (%client-transient-active-flags conn #\P))))))

(defun %open-client-text-prompt (conn kind)
  (let ((repository (%client-selected-repository conn)))
    (cond
      ((null repository) (%client-notify conn "no repository selected"))
      ((not (nerimux/vcs:vcs-package-available-p))
       (%client-notify conn "VCS unavailable"))
      (t
       (destructuring-bind (title widget operation static-args)
           (%client-text-prompt-spec kind conn)
         (setf (client-conn-text-prompt-kind conn) kind
               (client-conn-text-prompt-title conn) title
               (client-conn-text-prompt-widget conn) widget
               (client-conn-text-prompt-repository conn) repository
               (client-conn-text-prompt-operation conn) operation
               (client-conn-text-prompt-static-args conn) static-args)
         (%set-client-modal conn :text-prompt)
         t)))))

(defun %clear-client-text-prompt (conn &optional swallow-escape-p)
  (when swallow-escape-p
    (%client-esc-swallow-start conn))
  (setf (client-conn-text-prompt-kind conn) nil
        (client-conn-text-prompt-title conn) nil
        (client-conn-text-prompt-widget conn) nil
        (client-conn-text-prompt-repository conn) nil
        (client-conn-text-prompt-operation conn) nil
        (client-conn-text-prompt-static-args conn) nil)
  (%set-client-modal conn nil))

(defun %client-widget-handle-event (widget event)
  (when widget
    (let ((action (cl-tui-kit/widgets:handle-widget-event widget event)))
      (%mark-dirty)
      action)))

(defun %client-text-prompt-handle-event (conn event)
  (%client-widget-handle-event (client-conn-text-prompt-widget conn) event))

(defun %client-text-prompt-handle-text (conn text)
  (%client-text-prompt-handle-event
   conn
   (cl-tui-kit/core:make-text-input-event text)))

(defun %submit-client-text-prompt (conn)
  (let* ((widget (client-conn-text-prompt-widget conn))
         (value (and widget (cl-tui-kit/widgets:input-widget-value widget)))
         (repository (client-conn-text-prompt-repository conn))
         (operation (client-conn-text-prompt-operation conn))
         (static-args (client-conn-text-prompt-static-args conn))
         (args (case (client-conn-text-prompt-kind conn)
                 (:commit-message (list "--message" value))
                 ((:branch-create :tag-create) (list value))
                 (:remote-push (append static-args (list value))))))
    (if (or (null value) (zerop (length value)))
        (%client-notify conn "value required")
        (progn
          (%clear-client-text-prompt conn)
          (%run-transient-git-write conn repository operation args)))))

(defun %client-prompt-key-event (payload)
  (cond
    ((%client-byte-p payload 27)
     (cl-tui-kit/core:make-key-event :escape))
    ((%client-byte-p payload 13)
     (cl-tui-kit/core:make-key-event :enter))
    ((%client-byte-p payload 10)
     (cl-tui-kit/core:make-key-event :enter))
    ((or (%client-byte-p payload 8) (%client-byte-p payload 127))
     (cl-tui-kit/core:make-key-event :backspace))
    (t
     (let ((text (%client-payload-text payload)))
       (and text (cl-tui-kit/core:make-text-input-event text))))))

(defun %handle-client-text-prompt-key (session conn payload)
  (declare (ignore session))
  (cond
    ((%client-byte-p payload 27)
     (%clear-client-text-prompt conn t)
     t)
    ((and (typep (client-conn-text-prompt-widget conn)
                 'cl-tui-kit/widgets:textarea-widget)
          (%client-byte-p payload 19))
     (%submit-client-text-prompt conn)
     t)
    (t
     (let ((action (%client-text-prompt-handle-event
                    conn
                    (%client-prompt-key-event payload))))
       (when action
         (case (cl-tui-kit/core:action-name action)
           (:submit (%submit-client-text-prompt conn))
           (:cancel (%clear-client-text-prompt conn))))
       t))))

(defun %client-read-half-page (conn)
  (max 1 (floor (max 1 (- (client-conn-rows conn) 3)) 2)))

(defun %open-client-read-search (conn)
  (setf (client-conn-read-search-widget conn)
        (cl-tui-kit/widgets:make-input-widget
         :placeholder "search"
         :focusable-p t
         :semantic-role :searchbox))
  (%set-client-modal conn :read-search))

(defun %handle-client-read-search-key (session conn payload)
  (declare (ignore session))
  (cond
    ((%client-byte-p payload 27)
     (%client-esc-swallow-start conn)
     (setf (client-conn-read-search-widget conn) nil)
     (%set-client-modal conn :read-view)
     t)
    (t
     (let ((action
             (%client-widget-handle-event
              (client-conn-read-search-widget conn)
              (%client-prompt-key-event payload))))
       (when (and action
                  (eq (cl-tui-kit/core:action-name action) :submit))
         (let ((query (cl-tui-kit/widgets:input-widget-value
                       (client-conn-read-search-widget conn))))
           (nerimux/renderer:read-view-find
            (client-conn-read-view conn)
            (client-conn-rows conn)
            (client-conn-cols conn)
            query)
           (setf (client-conn-read-search-widget conn) nil)
           (%set-client-modal conn :read-view)))
       t))))

(defun %handle-client-read-view-key (session conn payload)
  (declare (ignore session))
  (cond
    ((or (%client-byte-p payload 27) (%client-key-p payload #\q))
     (%close-client-read-view conn (%client-byte-p payload 27))
     t)
    ((or (%client-key-p payload #\/) (%client-key-p payload #\?))
     (%open-client-read-search conn)
     t)
    ((%client-key-p payload #\j)
     (nerimux/renderer:read-view-scroll-by
      (client-conn-read-view conn)
      (client-conn-rows conn)
      (client-conn-cols conn)
      1)
     (%mark-dirty)
     t)
    ((%client-key-p payload #\k)
     (nerimux/renderer:read-view-scroll-by
      (client-conn-read-view conn)
      (client-conn-rows conn)
      (client-conn-cols conn)
      -1)
     (%mark-dirty)
     t)
    ((%client-byte-p payload 21)
     (nerimux/renderer:read-view-scroll-by
      (client-conn-read-view conn)
      (client-conn-rows conn)
      (client-conn-cols conn)
      (- (%client-read-half-page conn)))
     (%mark-dirty)
     t)
    ((%client-byte-p payload 4)
     (nerimux/renderer:read-view-scroll-by
      (client-conn-read-view conn)
      (client-conn-rows conn)
      (client-conn-cols conn)
      (%client-read-half-page conn))
     (%mark-dirty)
     t)
    (t t)))

(defun %run-transient-git-action (conn transient-key
                                       operation
                                       static-args
                                       confirm-p
                                       confirm-if-args)
  "Assemble STATIC-ARGS plus TRANSIENT-KEY's active toggles and run OPERATION
   against CONN's selected repository, confirming first when CONFIRM-P or any
   of CONFIRM-IF-ARGS is currently toggled on (Push's force flags -- contract
   §3's confirmation list: force push, rebase, reset --hard, branch delete,
   and clean all set CONFIRM-P directly instead, since none of them gate on
   an argument toggle)."
  (let* ((repository (%client-selected-repository conn))
         (active (%client-transient-active-flags conn transient-key))
         (args (append static-args active))
         (force-p
          (some
           (lambda (flag)
             (member flag active :test #'string=))
           confirm-if-args)))
    (cond
      ((null repository) (%client-notify conn "no repository selected"))
      ((not (nerimux/vcs:vcs-package-available-p))
       (%client-notify conn "VCS unavailable"))
      ((or confirm-p force-p)
       (%open-confirm-view conn
                           (%transient-command-text operation args)
                           (list
                            (cons "repository"
                                  (princ-to-string
                                   (nerimux/workspace-model:repository-id
                                    repository))))
                           (lambda ()
                             (%run-transient-git-write conn
                                                       repository
                                                       operation
                                                       args))))
      (t (%run-transient-git-write conn repository operation args)))))

(defun %open-client-transient (conn key)
  "Open the transient KEY names (contract §3). A KEY with no entry in
   +TRANSIENT-DEFINITIONS+ is a no-op: the keymap only ever calls this with a
   bound transient key, so reaching here with an unknown one is a caller bug
   rather than a user mistake worth reporting."
  (let ((definition (cdr (assoc key +transient-definitions+))))
    (when definition
      (destructuring-bind (title arguments actions) definition
        (setf (client-conn-transient-view conn) (nerimux/renderer:make-transient-view
                                                 :title
                                                 title
                                                 :subtitle
                                                 (%transient-subtitle key conn)
                                                 :arguments
                                                 (%transient-render-arguments
                                                  key
                                                  conn
                                                  arguments)
                                                 :actions
                                                 (%transient-render-actions conn
                                                                            actions)))
        (%set-client-modal conn :transient)
        t))))

(defun %close-client-transient (conn)
  "Take the transient down.  Clears TRANSIENT-VIEW, not just MODAL:
   server-multi-render.lisp reads CLIENT-CONN-TRANSIENT-VIEW unconditionally
   when drawing the :status view (it is what makes the panel expand at all),
   so a stale non-NIL value here would keep drawing a closed transient the
   moment MODAL next returns to NIL."
  (setf (client-conn-transient-view conn) nil)
  (%set-client-modal conn nil))

(defun %run-transient-action (session conn handler)
  "Run one action's HANDLER -- see the section comment above for the shapes.
   :OPEN-TRANSIENT replaces the open transient with a fresh one; every other
   handler closes the current one first via %CLOSE-CLIENT-TRANSIENT, exactly
   once, before doing anything else -- a :GIT action that opens a confirm
   view must not leave a stale transient underneath it either.

   SESSION is threaded through for :CALL alone. Worktree creation needs it (it
   opens a pane), and it is the reason this is not a one-argument closure: the
   worktree actions predate the transient and already work, so the transient
   adapts to their signature rather than the reverse."
  (case (first handler)
    (:open-transient (%open-client-transient conn (second handler)))
    (t
      (%close-client-transient conn)
      (case (first handler)
        (:git
         (destructuring-bind (transient-key operation
                                            args
                                            confirm-p
                                            confirm-if-args) (rest handler)
           (%run-transient-git-action conn
                                      transient-key
                                      operation
                                      args
                                      confirm-p
                                      confirm-if-args)))
        (:call (funcall (second handler) session conn))
        (:prompt (%open-client-text-prompt conn (second handler)))
        (:read-view (%open-client-read-view conn (second handler)))
        (:help (%client-open-help-view conn))
        (:stub (%client-notify conn (second handler)))))))

(defun %handle-client-transient-key-payload (session conn payload)
  "Answer the transient CONN is looking at (contract §3): ESC/q close it, an
   argument key toggles and redraws in place, an action key runs its
   HANDLER, anything else is swallowed -- the same 'the modal owns every
   key' shape as %HANDLE-CONFIRM-KEY and %HANDLE-HELP-VIEW-KEY. ESC goes
   through %CLIENT-ESC-SWALLOW-START first (R4.3): a lone ESC byte here could
   be the first byte of a 3-byte arrow-key sequence, and closing immediately
   would hand its trailing 2 bytes to whatever is underneath as literal `[`
   and a letter."
  (let ((view (client-conn-transient-view conn)))
    (cond
      ((let ((state (client-conn-workspace-assignment conn)))
         (and state (eq (workspace-assignment-phase state) :assigning)
              (eq view (workspace-assignment-view state))
              (%handle-worktree-assignment-key session conn state payload))))
      ((%client-byte-p payload 27)
        (%client-esc-swallow-start conn)
        (%close-client-transient conn)
        t)
      ((%client-key-p payload #\q)
        (%close-client-transient conn)
        t)
      ((null view)
        (%close-client-transient conn)
        t)
      (t
       (let ((argument
              (find-if
               (lambda (entry)
                 (%client-key-p payload (first entry)))
               (nerimux/renderer:transient-view-arguments view))))
         (if argument
             (progn
               (%client-transient-toggle-flag conn
                                              (fifth argument)
                                              (second argument))
               (%open-client-transient conn (fifth argument))
               t)
             (let ((action
                    (find-if
                     (lambda (entry)
                       (%client-key-p payload (first entry)))
                     (nerimux/renderer:transient-view-actions view))))
               (if action
                   (progn
                     (%run-transient-action session conn (third action))
                     t)
                   t))))))))
