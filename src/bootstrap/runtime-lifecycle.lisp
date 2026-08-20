(in-package #:nerimux)

(defvar *runtime-restore-report* nil)

(defvar *runtime-save-report* nil)

(defconstant +runtime-scrollback-limit+ 256)

(defun %runtime-safe-server-name (name)
  (let ((text (princ-to-string (or name "default"))))
    (let ((result
            (coerce
             (loop for character across text
                   collect
                   (if (or (alphanumericp character)
                           (member character '(#\- #\_ #\.) :test #'char=))
                       character
                       #\_))
             'string)))
      (if (plusp (length result)) result "default"))))

(defun %runtime-state-home ()
  "The state-home DIRECTORY shared by %runtime-state-path and
   %runtime-log-path: $NERIMUX_RUNTIME_STATE when set, else $XDG_STATE_HOME,
   else ~/.local/state/.

   NERIMUX_RUNTIME_STATE names a directory, not a literal file.  It used to be
   returned verbatim as the complete path from both callers, which meant a
   user who set it got the session-state snapshot and the raw server
   stdout/stderr log resolving to the IDENTICAL path -- writing one would
   clobber/interleave with the other, corrupting whichever %runtime-restore-*
   read back as Lisp data.  Routing the override through this shared helper,
   the same role STATE-HOME plays in the XDG branch below, keeps both callers
   applying their own nerimux/<name>.runtime.lisp / nerimux/<name>.log suffix
   on top of it, so the two files stay distinct."
  (let ((override (sb-ext:posix-getenv "NERIMUX_RUNTIME_STATE")))
    (if (and override (plusp (length override)))
        override
        (let ((xdg (sb-ext:posix-getenv "XDG_STATE_HOME")))
          (if (and xdg (plusp (length xdg)))
              xdg
              (namestring
               (merge-pathnames
                ".local/state/"
                (user-homedir-pathname))))))))

(defun %runtime-state-path ()
  (merge-pathnames
   (format nil "nerimux/~A.runtime.lisp"
           (%runtime-safe-server-name *runtime-server-name*))
   (pathname (format nil "~A/"
                     (string-right-trim "/" (%runtime-state-home))))))

(defun %runtime-log-path (name)
  "Resolve the persistent log file path for the auto-started headless server
   running as NAME, following %runtime-state-path's override/XDG resolution
   shape but keyed off an explicit NAME argument instead of the
   *runtime-server-name* special (which is not guaranteed bound in the
   launching/parent process)."
  (merge-pathnames
   (format nil "nerimux/~A.log"
           (%runtime-safe-server-name name))
   (pathname (format nil "~A/"
                     (string-right-trim "/" (%runtime-state-home))))))

(defun %runtime-safe-value (value)
  (cond
    ((or (null value)
         (eq value t)
         (stringp value)
         (numberp value)
         (characterp value)
         (keywordp value))
     value)
    ((symbolp value)
     (intern (string-upcase (symbol-name value)) :keyword))
    ((pathnamep value)
     (namestring value))
    ((consp value)
     (mapcar #'%runtime-safe-value value))
    (t
     (princ-to-string value))))

(defun %runtime-safe-list (values)
  (mapcar #'%runtime-safe-value (or values nil)))

(defun %runtime-cell-string (cell)
  (let ((character (nerimux/terminal:cell-char cell)))
    (if (characterp character) character #\Space)))

(defun %runtime-row-string (row)
  (with-output-to-string (stream)
    (loop for index below (length row)
          do (write-char (%runtime-cell-string (elt row index)) stream))))

(defun %runtime-screen-lines (screen)
  (loop for y below (nerimux/terminal:screen-height screen)
        collect
        (with-output-to-string
          (stream)
          (loop for x below (nerimux/terminal:screen-width screen)
                do (write-char
                    (%runtime-cell-string
                     (nerimux/terminal:screen-cell screen x y))
                    stream)))))

(defun %runtime-screen-snapshot (screen)
  (when screen
    (with-lock-held
        ((nerimux/terminal:screen-lock screen))
      (let ((scrollback (nerimux/terminal:screen-scrollback screen)))
        (list :width (nerimux/terminal:screen-width screen)
              :height (nerimux/terminal:screen-height screen)
              :lines (%runtime-screen-lines screen)
              :scrollback-lines
              (loop for row in
                    (subseq scrollback
                            0
                            (min +runtime-scrollback-limit+
                                 (length scrollback)))
                    collect (%runtime-row-string row)))))))

(defun %runtime-pane-snapshot (pane)
  (list :id (pane-id pane)
        :x (pane-x pane)
        :y (pane-y pane)
        :width (pane-width pane)
        :height (pane-height pane)
        :title (pane-title pane)
        :tty (pane-tty pane)
        :start-command (pane-start-command pane)
        :start-path (pane-start-path pane)
        :dead-status (%runtime-safe-value (pane-dead-status pane))
        :dead-signal (%runtime-safe-value (pane-dead-signal pane))
        :dead-time (pane-dead-time pane)
        :tags (%runtime-safe-list (pane-tags pane))
        :note (pane-note pane)
        :unread-output-p (pane-unread-output-p pane)
        :bell-p (pane-bell-p pane)
        :process-exited-p (pane-process-exited-p pane)
        :non-zero-exit-p (pane-non-zero-exit-p pane)
        :startup-failed-p (pane-startup-failed-p pane)
        :last-output-time (pane-last-output-time pane)
        :last-focused-time (pane-last-focused-time pane)
        :last-output (pane-last-output pane)
        :notification (pane-notification pane)
        :screen (%runtime-screen-snapshot (pane-screen pane))))

(defun %runtime-window-snapshot (window)
  (list :id (window-id window)
        :name (window-name window)
        :width (window-width window)
        :height (window-height window)
        :active-pane-id
        (let ((pane (window-active-pane window)))
          (and pane (pane-id pane)))
        :panes (mapcar #'%runtime-pane-snapshot (window-panes window))))

(defun %runtime-session-snapshot (session)
  (list :id (session-id session)
        :name (session-name session)
        :active-window-id
        (let ((window (session-active-window session)))
          (and window (window-id window)))
        :windows (mapcar #'%runtime-window-snapshot (session-windows session))))

(defun %runtime-client-snapshot (client)
  (list :rows (client-conn-rows client)
        :cols (client-conn-cols client)
        :read-only-p (client-conn-read-only-p client)
        :focus-pane-id
        (let ((pane (client-conn-focus client)))
          (and pane (pane-id pane)))
        :viewport (client-conn-viewport client)
        :mode (%runtime-safe-value (client-conn-mode client))
        :view (%runtime-safe-value (client-conn-view client))
        :selected-worktree-id
        (let ((worktree (client-conn-selected-worktree client)))
          (and worktree (worktree-id worktree)))
        :selected-worktree-path
        (let ((worktree (client-conn-selected-worktree client)))
          (and worktree (worktree-path worktree)))
        :tree-scroll (client-conn-tree-scroll client)
        :picker-query (client-conn-picker-query client)
        :picker-index (client-conn-picker-index client)))

(defun %runtime-worktree-snapshots ()
  (loop for organization in (nerimux/vcs:workspace-organizations)
        append
        (loop for repository in (organization-repositories organization)
              append
              (loop for worktree in (repository-worktrees repository)
                    collect
                    (list :organization-id (organization-id organization)
                          :organization-host (organization-host organization)
                          :organization-name (organization-name organization)
                          :organization-tags (%runtime-safe-list
                                              (organization-tags organization))
                          :organization-notes (organization-notes organization)
                          :organization-recent-activity
                          (%runtime-safe-list
                           (organization-recent-activity organization))
                          :repository-id (repository-id repository)
                          :repository-specification
                          (%runtime-safe-value
                           (repository-specification repository))
                          :repository-local-path
                          (%runtime-safe-value
                           (repository-local-path repository))
                          :repository-tags (%runtime-safe-list
                                            (repository-tags repository))
                          :repository-notes (repository-notes repository)
                          :repository-recent-activity
                          (%runtime-safe-list
                           (repository-recent-activity repository))
                          :worktree-id (worktree-id worktree)
                          :worktree-path
                          (%runtime-safe-value (worktree-path worktree))
                          :worktree-branch (worktree-branch worktree)
                          :worktree-head (worktree-head worktree)
                          :worktree-status
                          (%runtime-safe-value (worktree-status worktree))
                          :dirty-p (worktree-dirty-p worktree)
                          :conflict-p (worktree-conflict-p worktree)
                          :ahead (worktree-ahead worktree)
                          :behind (worktree-behind worktree)
                          :bare-p (worktree-bare-p worktree)
                          :locked-p (worktree-locked-p worktree)
                          :prunable-p (worktree-prunable-p worktree)
                          :missing-p (worktree-missing-p worktree)
                          :worktree-tags (%runtime-safe-list
                                          (worktree-tags worktree))
                          :worktree-notes (worktree-notes worktree)
                          :worktree-recent-activity
                          (%runtime-safe-list
                           (worktree-recent-activity worktree))
                          :pane-ids
                          (mapcar #'pane-id (worktree-panes worktree)))))))

(defun %runtime-snapshot-for-session (session)
  (nerimux/persistence:make-runtime-snapshot
   :sessions (list (%runtime-session-snapshot session))
   :clients (mapcar #'%runtime-client-snapshot
                    (if (boundp '*clients*) *clients* nil))
   :worktrees (%runtime-worktree-snapshots)
   :tags nil
   :notes nil))

(defun %runtime-restore-screen (screen snapshot)
  (when (and screen (listp snapshot))
    (let ((lines (getf snapshot :lines)))
      (when (listp lines)
        (let ((escape (code-char 27)))
          (let ((text
                  (with-output-to-string
                    (stream)
                    (format stream "~C[2J~C[H" escape escape)
                    (loop for line in lines
                          for first = t then nil
                          do (unless first (write-char #\Newline stream))
                             (write-string (or line "") stream)))))
            (with-lock-held
                ((nerimux/terminal:screen-lock screen))
              (nerimux/terminal:screen-process-bytes
               screen
               (cl-codec-kit:string-to-octets text :encoding :utf-8)))))))))

(defun %runtime-restore-pane-state (pane state)
  (setf (pane-title pane) (or (getf state :title) "")
        (pane-tty pane) (or (getf state :tty) "")
        (pane-start-command pane) (or (getf state :start-command) "")
        (pane-start-path pane) (or (getf state :start-path) "")
        (pane-dead-status pane) (getf state :dead-status)
        (pane-dead-signal pane) (getf state :dead-signal)
        (pane-dead-time pane) (getf state :dead-time)
        (pane-tags pane) (copy-list (or (getf state :tags) nil))
        (pane-note pane) (or (getf state :note) "")
        (pane-unread-output-p pane) (not (null (getf state :unread-output-p)))
        (pane-bell-p pane) (not (null (getf state :bell-p)))
        (pane-process-exited-p pane)
        (not (null (getf state :process-exited-p)))
        (pane-non-zero-exit-p pane)
        (not (null (getf state :non-zero-exit-p)))
        (pane-startup-failed-p pane)
        (not (null (getf state :startup-failed-p)))
        (pane-last-output-time pane)
        (if (numberp (getf state :last-output-time))
            (getf state :last-output-time)
            (if (numberp (pane-last-output-time pane))
                (pane-last-output-time pane)
                0))
        (pane-last-focused-time pane)
        (if (numberp (getf state :last-focused-time))
            (getf state :last-focused-time)
            (if (numberp (pane-last-focused-time pane))
                (pane-last-focused-time pane)
                0))
        (pane-last-output pane) (or (getf state :last-output) "")
        (pane-notification pane) (or (getf state :notification) ""))
  (let ((screen (pane-screen pane))
        (width (getf state :width))
        (height (getf state :height)))
    (when (and screen
               (integerp width)
               (integerp height)
               (plusp width)
               (plusp height))
      (ignore-errors
        (pane-reposition pane
                         (or (getf state :x) 0)
                         (or (getf state :y) 0)
                         width
                         height))
      (%runtime-restore-screen screen (getf state :screen))))
  pane)

(defun %runtime-find-by-id (id objects key)
  (and id (find id objects :key key :test #'equal)))

(defun %runtime-recovery-item
    (kind window-id window-name pane-id &key pane-state pane)
  (let* ((title (or (and pane (pane-title pane))
                    (and pane-state (getf pane-state :title))
                    "shell"))
         (command (or (and pane (pane-start-command pane))
                      (and pane-state (getf pane-state :start-command))
                      ""))
         (path (or (and pane
                        (pane-worktree pane)
                        (worktree-path (pane-worktree pane)))
                   (and pane (pane-start-path pane))
                   (and pane-state (getf pane-state :start-path))))
         (kind-label (string-downcase (symbol-name kind))))
    (list :runtime-recovery-p t
          :kind kind
          :window-id window-id
          :window-name window-name
          :pane-id pane-id
          :pane-state pane-state
          :pane pane
          :worktree-path path
          :start-command command
          :label (format nil "runtime ~A pane/~A ~A"
                         kind-label
                         (or pane-id "?")
                         title)
          :reasons (list :runtime-recovery kind))))

(defun %runtime-restore-window-state (window state)
  (setf (window-name window) (or (getf state :name) (window-name window))
        (window-width window) (or (getf state :width) (window-width window) 80)
        (window-height window) (or (getf state :height) (window-height window) 24))
  (let ((orphan-panes nil)
        (lost-panes nil)
        (recovery-items nil)
        (matched-pane-count 0)
        (saved-panes (or (getf state :panes) nil))
        (current-panes (window-panes window)))
    (dolist (saved-pane saved-panes)
      (let ((pane (%runtime-find-by-id
                   (getf saved-pane :id)
                   current-panes
                   #'pane-id)))
        (if pane
            (progn
              (incf matched-pane-count)
              (%runtime-restore-pane-state pane saved-pane))
            (let ((pane-id (getf saved-pane :id)))
              (push pane-id orphan-panes)
              (push (%runtime-recovery-item
                     :orphan-pane
                     (window-id window)
                     (window-name window)
                     pane-id
                     :pane-state saved-pane)
                    recovery-items)))))
    (dolist (pane current-panes)
      (unless (%runtime-find-by-id
               (pane-id pane)
               saved-panes
               (lambda (state) (getf state :id)))
        (let ((pane-id (pane-id pane)))
          (push pane-id lost-panes)
          (push (%runtime-recovery-item
                 :lost-pane
                 (window-id window)
                 (window-name window)
                 pane-id
                 :pane pane)
                recovery-items))))
    (let ((active-pane
            (%runtime-find-by-id
             (getf state :active-pane-id)
             current-panes
             #'pane-id)))
      (when active-pane
        (window-select-pane window active-pane)))
    (list :matched-pane-count matched-pane-count
          :orphan-panes (nreverse orphan-panes)
          :lost-panes (nreverse lost-panes)
          :recovery-items (nreverse recovery-items))))

(defun %runtime-restore-session-state (session state)
  (setf (session-name session) (or (getf state :name) (session-name session)))
  (let ((orphan-windows nil)
        (lost-windows nil)
        (orphan-panes nil)
        (lost-panes nil)
        (recovery-items nil)
        (matched-window-count 0)
        (matched-pane-count 0)
        (saved-windows (or (getf state :windows) nil))
        (current-windows (session-windows session)))
    (dolist (saved-window saved-windows)
      (let ((window (%runtime-find-by-id
                     (getf saved-window :id)
                     current-windows
                     #'window-id)))
        (if window
            (let ((report (%runtime-restore-window-state window saved-window)))
              (incf matched-window-count)
              (incf matched-pane-count
                    (getf report :matched-pane-count))
              (setf orphan-panes
                    (nconc orphan-panes (getf report :orphan-panes))
                    lost-panes
                    (nconc lost-panes (getf report :lost-panes)))
              (dolist (recovery-item (getf report :recovery-items))
                (push recovery-item recovery-items)))
            (progn
              (let ((window-id (getf saved-window :id))
                    (window-name (getf saved-window :name)))
                (push window-id orphan-windows)
                (dolist (saved-pane (getf saved-window :panes))
                  (let ((pane-id (getf saved-pane :id)))
                    (push pane-id orphan-panes)
                    (push (%runtime-recovery-item
                           :orphan-pane
                           window-id
                           window-name
                           pane-id
                           :pane-state saved-pane)
                          recovery-items))))))))
    (dolist (window current-windows)
      (unless (%runtime-find-by-id
               (window-id window)
               saved-windows
               (lambda (state) (getf state :id)))
        (push (window-id window) lost-windows)
        (dolist (pane (window-panes window))
          (push (pane-id pane) lost-panes)
          (push (%runtime-recovery-item
                 :lost-pane
                 (window-id window)
                 (window-name window)
                 (pane-id pane)
                 :pane pane)
                recovery-items))))
    (let ((active-window
            (%runtime-find-by-id
             (getf state :active-window-id)
             current-windows
             #'window-id)))
      (when active-window
        (session-select-window session active-window)))
    (list :session-matched-p t
          :matched-window-count matched-window-count
          :matched-pane-count matched-pane-count
          :orphan-windows (nreverse orphan-windows)
          :lost-windows (nreverse lost-windows)
          :orphan-panes (nreverse orphan-panes)
          :lost-panes (nreverse lost-panes)
          :recovery-items (nreverse recovery-items))))

(defun %runtime-session-panes (session)
  (loop for window in (session-windows session)
        append (copy-list (window-panes window))))

(defun %runtime-catalog-worktrees (organizations)
  (loop for organization in organizations
        append
        (loop for repository in (organization-repositories organization)
              append (copy-list (repository-worktrees repository)))))

(defun %runtime-worktree-state-match-p (state worktree)
  (or (and (stringp (getf state :worktree-id))
           (plusp (length (getf state :worktree-id)))
           (string= (getf state :worktree-id)
                    (worktree-id worktree)))
      (and (stringp (getf state :worktree-path))
           (plusp (length (getf state :worktree-path)))
           (string= (getf state :worktree-path)
                    (worktree-path worktree)))))

(defun %runtime-worktree-state-label (state)
  (or (getf state :worktree-id)
      (getf state :worktree-path)
      :unknown-worktree))

(defun %runtime-find-current-worktree (state worktrees)
  (find-if (lambda (worktree)
             (%runtime-worktree-state-match-p state worktree))
           worktrees))

(defun %runtime-attach-worktree-panes (worktree state panes)
  (let (orphan-pane-ids)
    (dolist (pane-id (getf state :pane-ids))
      (let ((pane (%runtime-find-by-id pane-id panes #'pane-id)))
        (if pane
            (worktree-add-pane worktree pane)
            (push pane-id orphan-pane-ids))))
    (nreverse orphan-pane-ids)))

(defun %runtime-restore-worktree-metadata
    (organization repository worktree state)
  (when (member :organization-tags state)
    (setf (organization-tags organization)
          (copy-list (getf state :organization-tags))))
  (when (member :organization-notes state)
    (setf (organization-notes organization)
          (or (getf state :organization-notes) "")))
  (when (member :organization-recent-activity state)
    (setf (organization-recent-activity organization)
          (copy-list (getf state :organization-recent-activity))))
  (when (member :repository-tags state)
    (setf (repository-tags repository)
          (copy-list (getf state :repository-tags))))
  (when (member :repository-notes state)
    (setf (repository-notes repository)
          (or (getf state :repository-notes) "")))
  (when (member :repository-recent-activity state)
    (setf (repository-recent-activity repository)
          (copy-list (getf state :repository-recent-activity))))
  (when (member :worktree-tags state)
    (setf (worktree-tags worktree)
          (copy-list (getf state :worktree-tags))))
  (when (member :worktree-notes state)
    (setf (worktree-notes worktree)
          (or (getf state :worktree-notes) "")))
  (when (member :worktree-recent-activity state)
    (setf (worktree-recent-activity worktree)
          (copy-list (getf state :worktree-recent-activity))))
  worktree)

(defun %runtime-build-worktree-catalog (session saved-worktrees)
  (let ((organizations nil)
        (panes (%runtime-session-panes session))
        (orphan-pane-ids nil)
        (matched-worktree-count 0))
    (dolist (state saved-worktrees)
      (let* ((organization-id
               (or (getf state :organization-id)
                   (organization-key (getf state :organization-host)
                                     (getf state :organization-name))))
             (organization
               (or (find organization-id organizations
                         :key #'organization-id
                         :test #'equal)
                   (make-organization
                    :id organization-id
                    :host (getf state :organization-host)
                    :name (getf state :organization-name))))
             (repository-id
               (or (getf state :repository-id)
                   (repository-key (getf state :repository-specification)
                                   (getf state :repository-local-path))))
             (repository
               (or (find repository-id
                         (organization-repositories organization)
                         :key #'repository-id
                         :test #'equal)
                   (make-repository
                    :id repository-id
                    :specification (getf state :repository-specification)
                    :local-path (getf state :repository-local-path))))
             (worktree
               (or (find-if (lambda (candidate)
                              (%runtime-worktree-state-match-p state candidate))
                            (repository-worktrees repository))
                   (make-worktree
                    :id (getf state :worktree-id)
                    :path (getf state :worktree-path)
                    :branch (getf state :worktree-branch)
                    :head (getf state :worktree-head)
                    :status (getf state :worktree-status)
                    :dirty-p (getf state :dirty-p)
                    :conflict-p (getf state :conflict-p)
                    :ahead (getf state :ahead)
                    :behind (getf state :behind)
                    :bare-p (getf state :bare-p)
                    :locked-p (getf state :locked-p)
                    :prunable-p (getf state :prunable-p)
                    :missing-p (getf state :missing-p)
                    :tags (getf state :worktree-tags)
                    :notes (getf state :worktree-notes)
                    :recent-activity (getf state :worktree-recent-activity)))))
        (%runtime-restore-worktree-metadata
         organization repository worktree state)
        (unless (member organization organizations :test #'eq)
          (push organization organizations))
        (unless (find repository-id
                      (organization-repositories organization)
                      :key #'repository-id
                      :test #'equal)
          (organization-add-repository organization repository))
        (unless (member worktree (repository-worktrees repository) :test #'eq)
          (repository-add-worktree repository worktree))
        (incf matched-worktree-count)
        (setf orphan-pane-ids
              (nconc (%runtime-attach-worktree-panes
                      worktree state panes)
                     orphan-pane-ids))))
    (nerimux/vcs:set-workspace-organizations (nreverse organizations))
    (list :catalog-restored-p t
          :catalog-source :snapshot
          :matched-worktree-count matched-worktree-count
          :orphan-worktrees nil
          :lost-worktrees nil
          :orphan-pane-ids (nreverse orphan-pane-ids)
          :lost-pane-ids nil)))

(defun %runtime-restore-existing-worktree-catalog (session saved-worktrees)
  (let ((worktrees (%runtime-catalog-worktrees
                    (nerimux/vcs:workspace-organizations)))
        (panes (%runtime-session-panes session))
        (orphan-worktrees nil)
        (orphan-pane-ids nil)
        (matched-worktree-count 0))
    (dolist (state saved-worktrees)
      (let ((worktree (%runtime-find-current-worktree state worktrees)))
        (if worktree
            (progn
              (incf matched-worktree-count)
              (%runtime-restore-worktree-metadata
               (repository-organization (worktree-repository worktree))
               (worktree-repository worktree)
               worktree
               state)
              (setf orphan-pane-ids
                    (nconc (%runtime-attach-worktree-panes
                            worktree state panes)
                           orphan-pane-ids)))
            (push (%runtime-worktree-state-label state)
                  orphan-worktrees))))
    (let ((lost-worktrees
            (loop for worktree in worktrees
                  unless (find-if (lambda (state)
                                    (%runtime-worktree-state-match-p
                                     state worktree))
                                  saved-worktrees)
                    collect (worktree-id worktree))))
      (list :catalog-restored-p (plusp matched-worktree-count)
            :catalog-source :existing
            :matched-worktree-count matched-worktree-count
            :orphan-worktrees (nreverse orphan-worktrees)
            :lost-worktrees lost-worktrees
            :orphan-pane-ids (nreverse orphan-pane-ids)
            :lost-pane-ids nil))))

(defun %runtime-restore-worktree-catalog (session saved-worktrees)
  (cond
    ((null saved-worktrees)
     (list :catalog-restored-p nil
           :catalog-source :none
           :matched-worktree-count 0
           :orphan-worktrees nil
           :lost-worktrees nil
           :orphan-pane-ids nil
           :lost-pane-ids nil))
    ((nerimux/vcs:workspace-organizations)
     (%runtime-restore-existing-worktree-catalog session saved-worktrees))
    (t
     (%runtime-build-worktree-catalog session saved-worktrees))))

(defun %restore-runtime-state (session)
  (setf *runtime-recovery-items* nil)
  (let* ((path (%runtime-state-path))
         (base (list :path (namestring path))))
    (handler-case
        (let ((snapshot (nerimux/persistence:load-runtime-snapshot path)))
          (if snapshot
              (let ((saved-session
                      (first (nerimux/persistence:runtime-snapshot-sessions
                              snapshot))))
                (setf *runtime-restore-report*
                      (append base
                              (list :loaded-p t)
                              (if saved-session
                                  (%runtime-restore-session-state
                                   session
                                   saved-session)
                                  (list :session-matched-p nil
                                        :reason :no-session))
                              (%runtime-restore-worktree-catalog
                               session
                               (nerimux/persistence:runtime-snapshot-worktrees
                                snapshot))))
                *runtime-restore-report*)
              (setf *runtime-restore-report*
                    (append base
                            (list :loaded-p nil
                                  :session-matched-p nil
                                  :reason :not-found)))))
      (condition (condition)
       (setf *runtime-restore-report*
             (append base
                     (list :loaded-p nil
                           :session-matched-p nil
                           :reason :error
                           :error (princ-to-string condition))))))
    (setf *runtime-recovery-items*
          (copy-list (getf *runtime-restore-report* :recovery-items)))
    *runtime-restore-report*))

(defun %save-runtime-state (session)
  (let ((path (%runtime-state-path)))
    (handler-case
        (let ((snapshot (%runtime-snapshot-for-session session)))
          (nerimux/persistence:save-runtime-snapshot snapshot path)
          (setf *runtime-save-report*
                (list :saved-p t
                      :path (namestring path)
                      :session-count
                      (length (nerimux/persistence:runtime-snapshot-sessions
                               snapshot))
                      :client-count
                      (length (nerimux/persistence:runtime-snapshot-clients
                               snapshot))
                      :worktree-count
                      (length (nerimux/persistence:runtime-snapshot-worktrees
                               snapshot)))))
      (condition (condition)
       (setf *runtime-save-report*
             (list :saved-p nil
                   :path (namestring path)
                   :reason :error
                   :error (princ-to-string condition)))))
    *runtime-save-report*))

(defun %runtime-restore-messages ()
  "Return short client-facing messages for the latest restore report."
  (when (and (boundp '*runtime-restore-report*)
             *runtime-restore-report*)
    (let ((loaded-p (getf *runtime-restore-report* :loaded-p))
          (reason (getf *runtime-restore-report* :reason))
          (orphan-worktrees (getf *runtime-restore-report* :orphan-worktrees))
          (lost-worktrees (getf *runtime-restore-report* :lost-worktrees))
          (orphan-panes (append (getf *runtime-restore-report* :orphan-pane-ids)
                                (getf *runtime-restore-report* :orphan-panes)))
          (lost-panes (append (getf *runtime-restore-report* :lost-pane-ids)
                              (getf *runtime-restore-report* :lost-panes)))
          (recovery-items (getf *runtime-restore-report* :recovery-items))
          (orphan-windows (getf *runtime-restore-report* :orphan-windows))
          (lost-windows (getf *runtime-restore-report* :lost-windows)))
      (remove nil
              (list
               (cond
                 ((eq reason :error) "runtime restore failed; inspect runtime state")
                 ((eq reason :not-found) "runtime restore: no saved state")
                 ((eq reason :no-session) "runtime restore: saved state has no session")
                 ((not loaded-p) "runtime restore: saved state was not loaded")
                 (t nil))
               (when (or orphan-worktrees lost-worktrees)
                 (format nil "runtime restore: worktrees orphaned ~D, lost ~D"
                         (length orphan-worktrees)
                         (length lost-worktrees)))
               (when (or orphan-panes lost-panes)
                 (format nil "runtime restore: panes orphaned ~D, lost ~D"
                         (length orphan-panes)
                         (length lost-panes)))
               (when (or orphan-windows lost-windows)
                 (format nil "runtime restore: windows orphaned ~D, lost ~D"
                         (length orphan-windows)
                         (length lost-windows)))
               (when recovery-items
                 (format nil "runtime restore: select ~D pane recovery item~:P in attention view"
                         (length recovery-items))))))))

(setf *runtime-state-restore-function* #'%restore-runtime-state
      *runtime-state-save-function* #'%save-runtime-state)
