(in-package #:nerimux)

(defun %client-ui-mode-p (mode)
  (member mode +client-ui-modes+ :test #'eq))

(defun %client-ui-mode-value (value)
  (let ((name (cond ((stringp value) value)
                    ((symbolp value) (symbol-name value)))))
    (when name
      (let ((mode (find-symbol (string-upcase name) :keyword)))
        (and (%client-ui-mode-p mode) mode)))))

;; The magit-alignment change (FR-001/FR-007, see server-multi-dispatch.lisp)
;; retired the MODE slot for VIEW/MODAL, but the wire vocabulary above -- a
;; mode NAME decoded off a forwarded `:mode` command, or one of the
;; :ENTER-*/:CANCEL/:ACCEPT/:TOGGLE-COPY events -- is still how this file's
;; own forwarded-command rules (server-multi-dispatch-command.lisp) and the
;; call sites outside this change's file set (server-multi-dispatch-
;; command-input.lisp, server-multi-dispatch-prefix.lisp) name a transition.
;; This table is the one place that vocabulary is translated, so the bare
;; mode keyword and its :ENTER- event spelling of the same transition land
;; on the same slot write.
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
  "Legacy setter kept because server-dispatch-helper-tests.lisp calls it
   directly; applies MODE through the same table %TRANSITION-CLIENT-UI-MODE
   uses and returns MODE unchanged -- not the resulting MODAL, which can
   spell the same transition differently (:COPY here becomes MODAL
   :SCROLLBACK) -- so a caller checking 'did this take' still sees back the
   vocabulary it passed in."
  (when (%client-ui-mode-p mode)
    (%apply-client-ui-mode-target conn mode))
  mode)

(defun %transition-client-ui-mode (conn event)
  "Legacy transition entry point kept for the callers outside this change's
   file set that still speak the old EVENT vocabulary (server-multi-
   dispatch-command-input.lisp, server-multi-dispatch-prefix.lisp): the
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
      ;; Symmetric with :command above: leaving :filter via ESC (:cancel)
      ;; drops the in-progress query entirely, while Enter (:accept) keeps
      ;; it -- the user is happy with the filtered set and wants to keep
      ;; navigating it with MODAL back to NIL, not have it silently reset to
      ;; the full tree.
      (when (and (eq current-modal :filter) (not (eq next-modal :filter))
                 (eq event :cancel))
        (setf (client-conn-tree-filter conn) nil))
      next-modal)))

(defun %set-client-focus (conn pane)
  (setf (client-conn-focus conn) pane
        (client-conn-viewport conn) 0
        (client-conn-view conn) :pane)
  (when pane
    (nerimux/model:pane-mark-focused pane))
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
        (%focus-selected-client-worktree session conn))
      ;; No cwd match: the client lands on the repolist, per the startup-UX
      ;; decision that only a cwd match dives straight into a pane. But it must
      ;; still be able to REACH the session's shell, and since FR-007 removed
      ;; `i` -- which used to type into the focused pane from any view -- the
      ;; only remaining route is FR-006's `q` rung, whose condition is CONN's
      ;; own focus. A freshly attached client has none, so that rung was
      ;; vacuously false and the running shell was unreachable by any key
      ;; whenever the catalog had nothing to navigate to.
      ;;
      ;; Setting FOCUS without touching VIEW is the whole fix: the landing
      ;; screen is unchanged, and `q` now has somewhere to go. Deliberately not
      ;; %SET-CLIENT-FOCUS, which would also switch VIEW to :pane and turn
      ;; every attach into a pane jump.
      (when (and session (null (client-conn-focus conn)))
        (let* ((window (session-active-window session))
               (pane (and window (window-active-pane window))))
          (when pane
            (setf (client-conn-focus conn) pane)))))
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
        (%workspace-find-worktree (second token) organizations))
       (:section
        (second token))))
    ((stringp token)
     (or (%workspace-find-worktree token organizations)
         (%workspace-find-repository token organizations)
         (%workspace-find-organization token organizations)))))

(defun %client-context-object (conn target)
  (or (%workspace-find-tree-object target)
      (%client-tree-object conn)
      (%workspace-find-tree-object (%client-selection-token conn))
      (and (client-conn-focus conn)
           (nerimux/model:pane-worktree (client-conn-focus conn)))))

(defun %client-selected-repository (conn &optional target)
  (let ((object (%client-context-object conn target)))
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
  (let ((object (%client-context-object conn target)))
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
             ;; EQUAL, not EQ: a :FILE/:COMMIT row's OBJECT is a freshly
             ;; consed list rebuilt on every %WORKSPACE-TREE-OBJECTS call
             ;; (D3, inline worktree expansion) rather than a persistent
             ;; struct, so CURRENT -- captured on the PREVIOUS keystroke's
             ;; flatten -- is never EQ to this call's re-consed OBJECTS
             ;; entry even when it names the same row. EQUAL degrades to EQ
             ;; for every struct/keyword-backed kind (structures compare by
             ;; identity under EQUAL, same as EQL), so this changes nothing
             ;; for any row kind that existed before this wave.
             (index (or (and current
                             (position current objects :test #'equal))
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
             ;; With no current selection, K (direction -1) has to start the
             ;; search from past the LAST row (COUNT, not 0) so
             ;; START+DIRECTION lands on the last index and searches
             ;; backward -- starting at 0 would step to -1 on the very first
             ;; iteration and find nothing, unlike J, which correctly starts
             ;; one before the first row.
             ;; EQUAL, not EQ -- same D3 rationale as %SELECT-CLIENT-TREE-
             ;; RELATIVE above.
             (start (or (and current (position current objects :test #'equal))
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
