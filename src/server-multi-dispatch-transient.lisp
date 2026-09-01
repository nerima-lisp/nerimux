(in-package #:nerimux)

;;;; The magit transient menus (FR-010): +TRANSIENT-DEFINITIONS+ is the data
;;;; table every `?`/c/P/F/b/m/r/z/l/d/f/t/X/!/w key opens, and the functions
;;;; below build the renderer's TRANSIENT-VIEW from it, run its answer, and
;;;; persist argument toggles across the client's session.
;;;;
;;;; ── Action handler shapes ────────────────────────────────────────────────
;;;;
;;;; Each action in +TRANSIENT-DEFINITIONS+ carries a HANDLER. Git actions use
;;;; nerimux/vcs:git-write-operation-async with the active flags for their
;;;; transient. Confirmation is handled by %OPEN-CONFIRM-VIEW when required.
;;;;   (:call FUNCTION)   Call (FUNCALL FUNCTION SESSION CONN) -- reuses an
;;;;     action that already exists elsewhere. SESSION is passed because
;;;;     worktree creation opens a pane and needs it; actions that do not want
;;;;     it take a LAMBDA that ignores it. Sharp-quoting a one-argument
;;;;     function here is a wrong-argument-count error raised only when the key
;;;;     is struck, and no static gate can see it: the arity meets the callee
;;;;     through a FUNCALL out of a data table.
;;;;   (:open-transient KEY)   Replace the open transient with KEY's (the `?`
;;;;     dispatch transient's own actions, magit-dispatch's shape).
;;;;   (:help)   Open the full-screen help view (%CLIENT-OPEN-HELP-VIEW).
;;;;   (:stub MESSAGE)   Notify MESSAGE and close.  Used for every action this
;;;;     pass could not wire for a reason worth being honest about on screen
;;;;     rather than silently dropping the key: free-text entry (a branch,
;;;;     tag, remote, or commit message) has no prompt widget in this build,
;;;;     and `!` deliberately never runs an arbitrary user-typed shell command
;;;;     -- that is its own trust-boundary decision, not something to default
;;;;     into existence as a side effect of wiring a keymap.
(defconstant +max-process-log-entries+
  20
  "Cap on CLIENT-CONN-PROCESS-LOG entry COUNT (contract §1's comment on that
   slot already caps each entry's OUTPUT via nerimux/vcs's own
   *write-operation-output-max-length*, so this bounds how many commands are
   remembered, not how large one of them can be).")

;;; ── Argument-toggle persistence (FR-010) ─────────────────────────────────
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

;;; ── Process log (FR-011) ─────────────────────────────────────────────────
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

;;; ── Running a git action ─────────────────────────────────────────────────
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
       (%client-notify conn "VCS adapter unavailable"))
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

;;; Transient menu data is defined in server-multi-transient-data.lisp.
;;; ── Building the renderer's TRANSIENT-VIEW ───────────────────────────────
(defun %transient-branch (conn)
  (let ((worktree (%client-operation-worktree conn)))
    (and worktree (nerimux/workspace-model:worktree-head worktree))))

(defun %transient-subtitle (key conn)
  (let ((branch (%transient-branch conn)))
    (when branch
      (if (member key '(#\P #\F #\f))
          (format nil "~A -> origin/~A" branch branch)
          (format nil "on ~A" branch)))))

(defun %transient-action-display-description (conn description)
  (if (search "~A" description)
      (format nil description (or (%transient-branch conn) "?"))
      description))

(defun %transient-render-arguments (transient-key conn arguments)
  "Enrich each static (ARG-KEY . FLAG) into the render struct's (KEY FLAG
   DESCRIPTION ACTIVE-P TRANSIENT-KEY) shape -- see TRANSIENT-VIEW's
   docstring (renderer-tui-kit-transient.lisp) for why the fifth element
   (TRANSIENT-KEY, needed only to persist the toggle) rides along."
  (let ((active (%client-transient-active-flags conn transient-key)))
    (mapcar
     (lambda (spec)
       (let ((flag (cdr spec)))
         (list (car spec)
               flag
               flag
               (and (member flag active :test #'string=) t)
               transient-key)))
     arguments)))

(defun %transient-render-actions (conn actions)
  "Project each static (ACTION-KEY DESCRIPTION HANDLER) into the render
   struct's (KEY DESCRIPTION HANDLER) shape, interpolating the branch
   template where DESCRIPTION uses one. HANDLER rides along past the
   renderer's documented (KEY DESCRIPTION) shape -- same rationale as
   %TRANSIENT-RENDER-ARGUMENTS above -- so %RUN-TRANSIENT-ACTION never has to
   re-look-up +TRANSIENT-DEFINITIONS+ by key to find it again."
  (mapcar
   (lambda (entry)
     (list (first entry)
           (%transient-action-display-description conn (second entry))
           (third entry)))
   actions))

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

;;; ── Running an action ─────────────────────────────────────────────────────
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
