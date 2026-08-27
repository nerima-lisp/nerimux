(in-package #:nerimux)

(defun %client-ui-mode-p (mode)
  (member mode +client-ui-modes+ :test #'eq))

(defun %client-ui-mode-value (value)
  (let ((name (cond ((stringp value) value)
                    ((symbolp value) (symbol-name value)))))
    (when name
      (let ((mode (find-symbol (string-upcase name) :keyword)))
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
            ((eq event :enter-tree-filter) :tree-filter)
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
    ;; Symmetric with :command above: leaving :tree-filter via ESC (:cancel)
    ;; drops the in-progress query entirely, while Enter (:accept) keeps it --
    ;; the user is happy with the filtered set and wants to keep navigating
    ;; it in :normal mode, not have it silently reset to the full tree.
    (when (and (eq current :tree-filter) (not (eq next :tree-filter))
               (eq event :cancel))
      (setf (client-conn-tree-filter conn) nil))
    next))

(defun %set-client-focus (conn pane)
  (setf (client-conn-focus conn) pane
        (client-conn-viewport conn) 0
        (client-conn-view conn) :detail)
  (when pane
    (nerimux/model:pane-mark-focused pane))
  pane)

(defun %set-client-view (conn view)
  (when (member view '(:overview :detail) :test #'eq)
    (setf (client-conn-view conn) view
          (client-conn-mode conn) :normal)
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
       (handler-case (parse-integer value)
         (parse-error () nil))))

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
         ((handler-case (parse-integer text)
            (parse-error () nil)))
         (t nil))))
    (t nil)))

(defun %client-live-p (conn)
  (member conn *clients* :test #'eq))

(defun %attach-target-session ()
  "The one live session a running server holds, or NIL outside one.

   %CLIENT-ATTACH-TARGET below needs a session to jump a cwd-matched client
   straight to its detail pane (FR-002's %FOCUS-SELECTED-CLIENT-WORKTREE
   call), but its one call site -- the :ATTACH-TARGET rule in
   server-multi-dispatch-command.lisp, which is outside this change's scope
   -- invokes it as (%client-attach-target conn args), with no session
   argument, and server-dispatch-helper-tests.lisp calls it the same way
   directly. Adding a session parameter would have to default to something
   in both of those callers anyway, so this reads the one session
   RUN-SERVER (server.lisp) registers instead of threading one through:
   *SERVER-SESSIONS* is empty in the unit test (no session ever registered
   there), which is exactly what keeps this whole feature a no-op there
   rather than a broken multiple-value-setq target."
  (cdr (first *server-sessions*)))

(defun %client-attach-target (conn args)
  (let ((target (first args))
        (cwd (second args))
        (session (%attach-target-session)))
    (setf (client-conn-attach-target conn)
          (and (stringp target) (plusp (length target)) target)
          (client-conn-attach-cwd conn)
          (and (stringp cwd) (plusp (length cwd)) cwd))
    (multiple-value-bind (worktree source)
        (%client-attach-selection conn (nerimux/vcs:workspace-organizations))
      ;; FR-002: a cwd with nothing in the catalog under it yet -- neither an
      ;; explicit nor a previous match either, or %CLIENT-ATTACH-SELECTION
      ;; would already have used one of those -- gets one chance to resolve
      ;; and register its repository synchronously before falling back to
      ;; the ordinary overview with nothing selected.
      (when (and session
                 (null worktree)
                 (stringp cwd)
                 (plusp (length cwd)))
        ;; Synchronous, on this single-threaded dispatch loop, is a user
        ;; decision (FR-002): the cwd match has to resolve before the
        ;; client's first frame, and an "overview first, then jump" fallback
        ;; was considered and explicitly rejected during requirements review.
        ;; The accepted stop-radius: RESOLVE-DIRECTORY-ORGANIZATIONS makes
        ;; exactly one git invocation, bounded by its own short (2s) explicit
        ;; timeout (see vcs.lisp), and CWD only ever names a directory this
        ;; same OS user's `nerimux attach` sent over the attach socket -- a
        ;; same-UID boundary, not arbitrary input.
        (let ((organizations (nerimux/vcs:resolve-directory-organizations cwd)))
          (when organizations
            (nerimux/vcs:merge-workspace-organizations organizations)
            (multiple-value-setq (worktree source)
              (%client-attach-selection
               conn (nerimux/vcs:workspace-organizations))))))
      ;; Only a CWD match (freshly resolved above, or already in the catalog)
      ;; jumps straight to the detail pane -- an :EXPLICIT selector or a
      ;; :PREVIOUS selection lands on the overview as before, per spec.
      ;;
      ;; %FOCUS-SELECTED-CLIENT-WORKTREE is defined in
      ;; server-multi-dispatch-command-input.lisp, which nerimux.asd loads
      ;; AFTER this file -- a forward reference, same rationale as
      ;; %WORKSPACE-EXPANDED-NODES in server-multi.lisp: harmless for a
      ;; function (unlike a special variable), since by the time this ever
      ;; RUNS both files have loaded.
      (when (and session (eq source :cwd))
        (%focus-selected-client-worktree session conn)))
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
                        "--path" "path")
                      :test #'string-equal))
         (setf skip-next t))
        ((and (stringp arg)
              (plusp (length arg))
              (char/= (char arg 0) #\-)
              (not (member arg '("confirm" "force")
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

(defun %client-selected-organization (conn &optional target)
  "Resolve the organization C-q C-f should fetch: the selected organization
itself, or the organization owning the selected repository or worktree.
Mirrors %CLIENT-SELECTED-REPOSITORY's object-resolution chain, one level up
the tree (R7.1)."
  (let ((object
          (or (%workspace-find-tree-object target)
              (%client-tree-object conn)
              (%workspace-find-tree-object (%client-selection-token conn))
              (and (client-conn-focus conn)
                   (nerimux/model:pane-worktree (client-conn-focus conn))))))
    (typecase object
      (nerimux/model:organization object)
      (nerimux/model:repository (nerimux/model:repository-organization object))
      (nerimux/model:worktree
       (let ((repository (nerimux/model:worktree-repository object)))
         (and repository (nerimux/model:repository-organization repository)))))))

(defun %client-operation-worktree (conn &optional target)
  (or (%workspace-find-worktree target)
      (and (typep (%client-tree-object conn) 'nerimux/model:worktree)
           (%client-tree-object conn))
      (and (client-conn-focus conn)
           (nerimux/model:pane-worktree (client-conn-focus conn)))))

(defun %select-client-tree-relative (conn delta)
  (let* ((objects (%workspace-tree-objects
                   (nerimux/vcs:workspace-organizations)
                   (client-conn-tree-filter conn)))
         (count (length objects)))
    (when (plusp count)
      (let* ((current (%client-tree-object conn))
             (index (or (and current
                             (position current objects :test #'eq))
                        (if (minusp delta) 0 -1)))
             (next (max 0 (min (1- count) (+ index delta))))
             (visible (max 1 (nerimux/renderer:workspace-tree-view-rows
                              (client-conn-rows conn)))))
        (%set-client-selected-tree-object conn (nth next objects))
        (when (< next (client-conn-tree-scroll conn))
          (setf (client-conn-tree-scroll conn) next))
        (when (>= next (+ (client-conn-tree-scroll conn) visible))
          (setf (client-conn-tree-scroll conn)
                (max 0 (+ next 1 (- visible)))))
        (%mark-dirty)
        (nth next objects)))))

(defun %select-client-tree-repository-relative (conn direction)
  "J/K (item 3): move the selection to the next/previous REPOSITORY row,
   skipping organization/worktree/window/pane rows in between. Walks the same
   filtered row set %SELECT-CLIENT-TREE-RELATIVE (j/k) uses, so a repository
   hidden by an active tree-filter is skipped exactly as j/k already skips
   any filtered-out row."
  (let* ((objects (%workspace-tree-objects
                   (nerimux/vcs:workspace-organizations)
                   (client-conn-tree-filter conn)))
         (count (length objects)))
    (when (plusp count)
      (let* ((current (%client-tree-object conn))
             ;; With no current selection, K (direction -1) has to start the
             ;; search from past the LAST row (COUNT, not 0) so
             ;; START+DIRECTION lands on the last index and searches
             ;; backward -- starting at 0 would step to -1 on the very first
             ;; iteration and find nothing, unlike J, which correctly starts
             ;; one before the first row.
             (start (or (and current (position current objects :test #'eq))
                        (if (minusp direction) count -1)))
             (visible (max 1 (nerimux/renderer:workspace-tree-view-rows
                              (client-conn-rows conn)))))
        ;; LOOP's BY step must be positive (SIMPLE-TYPE-ERROR on SBCL 2.6.6
        ;; when DIRECTION is -1, i.e. K) -- STEP here is always a positive
        ;; count of iterations, and INDEX is computed by multiplying it by
        ;; DIRECTION instead of letting LOOP step negatively itself.
        (loop for step from 1
              for index = (+ start (* direction step))
              while (<= 0 index (1- count))
              for candidate = (nth index objects)
              when (typep candidate 'nerimux/model:repository)
                do (%set-client-selected-tree-object conn candidate)
                   (when (< index (client-conn-tree-scroll conn))
                     (setf (client-conn-tree-scroll conn) index))
                   (when (>= index (+ (client-conn-tree-scroll conn) visible))
                     (setf (client-conn-tree-scroll conn)
                           (max 0 (+ index 1 (- visible)))))
                   (%mark-dirty)
                   (return candidate))))))

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
