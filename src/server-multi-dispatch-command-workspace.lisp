(in-package #:nerimux)

(defun %client-ui-mode-p (mode)
  (member mode +client-ui-modes+ :test #'eq))

(defun %client-ui-mode-value (value)
  (let ((name
         (cond
           ((stringp value) value)
           ((symbolp value) (symbol-name value)))))
    (when name
      (let ((mode (find-symbol (string-upcase name) :keyword)))
        (and (%client-ui-mode-p mode) mode)))))

(defun %client-ui-mode-target-modal (target)
  "The MODAL TARGET maps onto, :VIEW-PANE for the one transition that moves
   VIEW instead of MODAL, or :UNCHANGED when TARGET names neither.

   :CANCEL/:ACCEPT must land here as explicit entries, not fall through to
   :UNCHANGED (contract SS5: both drop MODAL to NIL) -- %TRANSITION-CLIENT-
   UI-MODE's own :COMMAND-buffer-clear and :FILTER-query-drop branches below
   fire only when NEXT-MODAL differs from CURRENT-MODAL, so an :UNCHANGED
   mapping for :CANCEL/:ACCEPT would silently keep MODAL wherever it was and
   never trip either branch -- the wire's `:` accept/cancel commands
   (server-multi-dispatch-command.lisp) would leave :COMMAND or :FILTER
   modal stuck open forever."
  (case target
    ((:normal :enter-normal :cancel :accept) nil)
    ((:input :enter-input) :view-pane)
    ((:copy :enter-copy) :scrollback)
    ((:command :enter-command) :command)
    ((:picker :enter-picker) :picker)
    ((:tree-filter :enter-tree-filter) :filter)
    (t :unchanged)))

(defun %apply-client-ui-mode-target (conn target)
  "Apply TARGET (see %CLIENT-UI-MODE-TARGET-MODAL) to CONN, returning the
   resulting MODAL."
  (let ((mapped (%client-ui-mode-target-modal target)))
    (cond
      ((eq mapped :view-pane) (%set-client-view conn :pane))
      ((eq mapped :unchanged) nil)
      (t (%set-client-modal conn mapped))))
  (client-conn-modal conn))

(defun %set-client-ui-mode (conn mode)
  "Apply MODE through the same table %TRANSITION-CLIENT-UI-MODE
   uses and returns MODE unchanged -- not the resulting MODAL, which can
   spell the same transition differently (:COPY here becomes MODAL
   :SCROLLBACK) -- so a caller checking 'did this take' still sees back the
   vocabulary it passed in."
  (when (%client-ui-mode-p mode)
    (%apply-client-ui-mode-target conn mode))
  mode)

(defun %transition-client-ui-mode (conn event)
  "Transition CONN for the EVENT vocabulary used by command dispatch:
   the
   state it transitions is VIEW/MODAL now, via %APPLY-CLIENT-UI-MODE-TARGET,
   but the two real behaviours beyond a bare slot write are preserved here
   as before -- the :COMMAND buffer clears on both entering and leaving it,
   and the tree-filter query survives an :ACCEPT (Enter) but is dropped by
   a :CANCEL (ESC)."
  (let* ((current-modal (client-conn-modal conn))
         (target (if (eq event :toggle-copy)
                     (if (eq current-modal :scrollback) :enter-normal :copy)
                     event)))
    (%apply-client-ui-mode-target conn target)
    (let ((next-modal (client-conn-modal conn)))
      (when (and (eq next-modal :command) (not (eq current-modal :command)))
        (setf (client-conn-command-buffer conn) ""))
      (when (and (not (eq next-modal :command)) (eq current-modal :command))
        (setf (client-conn-command-buffer conn) "")
        (%client-restore-command-view conn))
      (when (and (eq current-modal :filter) (not (eq next-modal :filter))
                 (eq event :cancel))
        (setf (client-conn-tree-filter conn) nil))
      next-modal)))

(defun %set-client-focus (conn pane)
  (setf (client-conn-focus conn) pane
        (client-conn-viewport conn) 0
        (client-conn-view conn) :pane)
  (when pane
    (nerimux/pane:pane-mark-focused pane))
  pane)

(defun %set-client-view (conn view)
  (when (member view '(:repolist :status :pane) :test #'eq)
    (setf (client-conn-view conn) view)
    (%mark-dirty))
  (client-conn-view conn))

(defun %resolve-client-focus-pane (session token &optional conn)
  (let ((window (session-active-window session)))
    (if token
        (and window (find-pane-by-target window token))
        (or
         (and conn
              (client-conn-focus conn)
              (find (client-conn-focus conn) (all-panes session) :test #'eq))
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
    (when (and pane (pane-screen pane) (screen-copy-mode-p (pane-screen pane)))
      (copy-mode-exit (pane-screen pane)))
    (%transition-client-ui-mode conn :enter-normal)
    (%mark-dirty)
    t))

(defun %move-client-viewport (conn delta)
  (when (integerp delta)
    (setf (client-conn-viewport conn) (max 0
                                           (+ (client-conn-viewport conn) delta))))
  (client-conn-viewport conn))

(defun %client-live-p (conn)
  (member conn *clients* :test #'eq))

(defun %attach-target-session ()
  "Return the session registered by the running server, if any."
  (cdr (first *server-sessions*)))

(defun %client-attach-refresh-catalog (conn session cwd)
  (multiple-value-bind (worktree source)
      (%client-attach-selection conn (nerimux/vcs:workspace-organizations))
    (when (and session
               (null worktree)
               (stringp cwd)
               (plusp (length cwd)))
      (let ((organizations (nerimux/vcs:resolve-directory-organizations cwd)))
        (when organizations
          (nerimux/vcs:merge-workspace-organizations organizations)
          (multiple-value-setq (worktree source)
            (%client-attach-selection
             conn (nerimux/vcs:workspace-organizations))))))
    (values worktree source)))

(defun %client-attach-target (conn args)
  (let ((target (first args))
        (cwd (second args))
        (session (%attach-target-session)))
    (setf (client-conn-attach-target conn)
          (and (stringp target) (plusp (length target)) target)
          (client-conn-attach-cwd conn)
          (and (stringp cwd) (plusp (length cwd)) cwd))
    (multiple-value-bind (worktree source)
        (%client-attach-refresh-catalog conn session cwd)
      (when (and session (eq source :cwd))
        (%focus-selected-client-worktree session conn))
      (when (and session (null (client-conn-focus conn)))
        (let* ((window (session-active-window session))
               (pane (and window (window-active-pane window))))
          (when pane
            (setf (client-conn-focus conn) pane)))))
    (%mark-dirty)
    t))

(defun %client-notify (conn message)
  (let ((text
         (if (stringp message)
             message
             (princ-to-string message))))
    (when (%client-live-p conn)
      (let ((log (cons text (client-conn-message-log conn))))
        (setf (client-conn-message-log conn) (subseq log
                                                     0
                                                     (min 64 (length log))))
        (when (client-conn-focus conn)
          (pane-notify (client-conn-focus conn) text))
        (%mark-dirty)))
    text))

(defun %select-client-tree-section-relative (conn direction)
  "J/K (section-based overview redesign, replacing the old repository-row
   jump): move the selection to the next/previous :SECTION header row --
   Attention, Active, or Repositories, identified by its OBJECT being a
   section keyword rather than a model object -- skipping every worktree/
   repository row in between. Walks the same filtered row set %SELECT-
   CLIENT-TREE-RELATIVE (j/k) uses, so a section hidden by an active
   tree-filter (an empty section is omitted entirely, see %WORKSPACE-
   SECTION-ENTRIES) is skipped exactly as j/k already skips any filtered-out
   row."
  (let* ((objects (%workspace-tree-objects
                   (nerimux/vcs:workspace-organizations)
                   (client-conn-tree-filter conn)))
         (count (length objects)))
    (when (plusp count)
      (let* ((current (%client-tree-object conn))
             (start (or (and current (position current objects :test #'equal))
                        (if (minusp direction) count -1)))
             (visible (max 1 (nerimux/renderer:workspace-tree-view-rows
                              (client-conn-rows conn)))))
        (loop for step from 1
              for index = (+ start (* direction step))
              while (<= 0 index (1- count))
              for candidate = (nth index objects)
              when (keywordp candidate)
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
  (%refresh-client-picker conn
                          :on-complete
                          (lambda (organizations)
                            (declare (ignore organizations))
                            (%client-notify conn "workspace refresh complete"))
                          :on-error
                          (lambda (condition)
                            (%client-notify conn
                                            (format nil
                                                    "workspace refresh failed: ~A"
                                                    condition))))
  t)

(defun %client-rebind-prefix (conn value)
  (let ((code (%parse-client-key-code value)))
    (if (and (integerp code) (<= 1 code) (<= code 255))
        (progn
          (setf (client-conn-workspace-prefix-code conn) code
                (client-conn-ui-prefix-p conn) nil)
          (%client-notify conn (format nil "workspace prefix set to ~D" code))
          t)
        (progn
          (%client-notify conn "invalid workspace prefix key")
          t))))
