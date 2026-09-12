(in-package #:nerimux)

(defun %runtime-safe-server-name (name)
  (let ((text (princ-to-string (or name "default"))))
    (let ((result
           (coerce
            (loop for character across text
                  collect (if (or (alphanumericp character)
                                  (member character
                                          +runtime-safe-server-name-punctuation+
                                          :test
                                          #'char=))
                              character
                              #\_))
            'string)))
      (if (string/= result "")
          result
          "default"))))

(defun %runtime-state-home ()
  "The state-home DIRECTORY used by %runtime-log-path: $NERIMUX_RUNTIME_STATE
   when set, else $XDG_STATE_HOME, else ~/.local/state/.

   NERIMUX_RUNTIME_STATE names a directory, not a literal file: the caller
   applies its own nerimux/<name>.log suffix on top of it."
  (let ((override (sb-ext:posix-getenv "NERIMUX_RUNTIME_STATE")))
    (if (and override (string/= override ""))
        override
        (let ((xdg (sb-ext:posix-getenv "XDG_STATE_HOME")))
          (if (and xdg (string/= xdg ""))
              xdg
              (namestring
               (merge-pathnames ".local/state/" (user-homedir-pathname))))))))

(defun %runtime-log-path (name)
  "Resolve the persistent log file path for the auto-started headless server
   running as NAME, following %runtime-state-home's override/XDG resolution
   shape but keyed off an explicit NAME argument instead of the
   *runtime-server-name* special (which is not guaranteed bound in the
   launching/parent process)."
  (merge-pathnames
   (make-pathname :directory (list :relative "nerimux")
                  :name (%runtime-safe-server-name name)
                  :type "log")
   (uiop:ensure-directory-pathname (%runtime-state-home))))

(defconstant +runtime-state-version+ 1)
(defconstant +runtime-state-max-bytes+ (* 1024 1024))

(defun %runtime-state-path (name)
  (merge-pathnames
   (make-pathname :directory (list :relative "nerimux")
                  :name (%runtime-safe-server-name name)
                  :type "state")
   (uiop:ensure-directory-pathname (%runtime-state-home))))

(defun %runtime-state-plist-p (value)
  (and (listp value)
       (evenp (length value))
       (loop for tail on value by #'cddr
             always (keywordp (car tail)))))

(defun %runtime-state-has-key-p (plist key)
  (member key plist :test #'eq))

(defun %runtime-state-role-p (role)
  (or (eq role :terminal)
      (and (listp role)
           (= 2 (length role))
           (eq (first role) :agent)
           (member (second role) '(nil :codex :claude) :test #'eq))))

(defun %runtime-state-pane-p (record)
  (and (%runtime-state-plist-p record)
       (%runtime-state-has-key-p record :id)
       (%runtime-state-has-key-p record :role)
       (typep (getf record :id) '(integer 1 *))
       (%runtime-state-role-p (getf record :role))))

(defun %runtime-state-window-p (record)
  (and (%runtime-state-plist-p record)
       (%runtime-state-has-key-p record :layout)
       (%runtime-state-has-key-p record :zoom)
       (%runtime-state-has-key-p record :panes)
       (stringp (getf record :layout))
       (typep (getf record :zoom) 'boolean)
       (listp (getf record :panes))
       (every #'%runtime-state-pane-p (getf record :panes))))

(defun %runtime-state-worktree-p (record)
  (and (%runtime-state-plist-p record)
       (%runtime-state-has-key-p record :path)
       (%runtime-state-has-key-p record :completed)
       (%runtime-state-has-key-p record :windows)
       (stringp (getf record :path))
       (plusp (length (getf record :path)))
       (typep (getf record :completed) 'boolean)
       (listp (getf record :windows))
       (every #'%runtime-state-window-p (getf record :windows))))

(defun %runtime-state-form-p (form)
  (and (consp form)
       (eq (first form) :nerimux-state)
       (%runtime-state-plist-p (rest form))
       (%runtime-state-has-key-p (rest form) :version)
       (%runtime-state-has-key-p (rest form) :worktrees)
       (%runtime-state-has-key-p (rest form) :expanded)
       (= (getf (rest form) :version) +runtime-state-version+)
       (listp (getf (rest form) :worktrees))
       (every #'%runtime-state-worktree-p (getf (rest form) :worktrees))
       (listp (getf (rest form) :expanded))
       (every #'stringp (getf (rest form) :expanded))))

(defun %quarantine-runtime-state (path condition)
  (let ((source (namestring path)))
    (loop for suffix from 1
          for target = (pathname (format nil "~A.invalid~D" source suffix))
          unless (probe-file target)
            do (handler-case
                   (progn
                     (rename-file path target)
                     (format *error-output*
                             "~&nerimux: ignoring invalid state file (~A): ~A~%"
                             (namestring target)
                             condition)
                     (return target))
                 (file-error ()
                   (format *error-output*
                           "~&nerimux: ignoring invalid state file: ~A~%"
                           condition)
                   (return nil))))))

(defun %read-runtime-state (name)
  (let ((path (%runtime-state-path name)))
    (when (probe-file path)
      (handler-case
          (progn
            (when (> (with-open-file (stream path :direction :input)
                       (file-length stream))
                     +runtime-state-max-bytes+)
              (error "state file exceeds ~D bytes" +runtime-state-max-bytes+))
            (let ((eof (gensym "EOF-"))
                  (form nil)
                  (extra nil))
              (with-open-file (stream path
                                      :direction :input
                                      :external-format :utf-8)
                (let ((*read-eval* nil)
                      (*read-circle* nil)
                      (*package* (find-package :cl-user)))
                  (setf form (read stream nil eof)
                        extra (read stream nil eof))))
              (unless (and (not (eq form eof)) (eq extra eof))
                (error "state file must contain exactly one form"))
              (unless (%runtime-state-form-p form)
                (error "unsupported or malformed runtime state"))
              (values form path)))
        (error (condition)
          (%quarantine-runtime-state path condition)
          (values nil path))))))

(defun %runtime-pane-state-record (pane)
  (list :id (pane-id pane)
        :role (if (or (eq (pane-role pane) :agent)
                      (pane-agent-kind pane))
                  (list :agent (pane-agent-kind pane))
                  :terminal)))

(defun %runtime-state-window-record (window worktree)
  (let ((panes (sort (copy-list
                     (if (and (window-zoom-p window)
                              (window-zoom-tree window))
                         (nerimux/layout:layout-leaves
                          (window-zoom-tree window))
                         (window-panes window)))
                     #'<
                     :key #'pane-id)))
    (when (and panes
               (every (lambda (pane)
                        (eq worktree (pane-worktree pane)))
                      panes))
      (list :layout (nerimux/layout:layout->string window)
            :zoom (window-zoom-p window)
            :panes (mapcar #'%runtime-pane-state-record panes)))))

(defun %runtime-state-worktree-record (worktree)
  (let* ((windows (sort
                   (remove-duplicates
                    (mapcar #'pane-window (worktree-panes worktree))
                    :test #'eq)
                   #'<
                   :key #'window-id))
         (records (remove nil
                          (mapcar (lambda (window)
                                    (%runtime-state-window-record window worktree))
                                  windows))))
    (when records
      (list :path (worktree-path worktree)
            :completed (worktree-completed-p worktree)
            :windows records))))

(defun %runtime-state-expanded-repository-ids ()
  (sort
   (loop for key being the hash-keys of *workspace-expanded-node-ids*
         when (and (consp key) (eq (first key) :repository))
           collect (second key))
   #'string<))

(defun %runtime-state-form (session)
  (let ((worktrees
          (sort
           (remove nil
                   (remove-duplicates
                    (mapcar #'pane-worktree (all-panes session))
                    :test #'eq))
           #'string<
           :key #'worktree-path)))
    (list :nerimux-state
          :version +runtime-state-version+
          :worktrees (remove nil (mapcar #'%runtime-state-worktree-record worktrees))
          :expanded (%runtime-state-expanded-repository-ids))))

(defun %runtime-state-string (session)
  (with-output-to-string (stream)
    (let ((*print-readably* t)
          (*print-pretty* nil)
          (*print-circle* nil))
      (write (%runtime-state-form session) :stream stream :readably t))))

(defun %write-runtime-state-atomically (path contents)
  (let ((temporary (pathname (format nil "~A.tmp" (namestring path)))))
    (unwind-protect
         (progn
           (ensure-directories-exist path)
           (with-open-file (stream temporary
                                   :direction :output
                                   :if-exists :supersede
                                   :if-does-not-exist :create
                                   :external-format :utf-8)
             (write-string contents stream)
             (finish-output stream))
           (with-open-file (stream temporary :direction :input)
             (when (> (file-length stream) +runtime-state-max-bytes+)
               (error "generated runtime state exceeds ~D bytes"
                      +runtime-state-max-bytes+)))
           (uiop:rename-file-overwriting-target temporary path)
           (setf temporary nil)
           path)
      (when temporary
        (ignore-errors (delete-file temporary))))))

(defun %persist-runtime-state (session &key force)
  (when *runtime-persistence-enabled-p*
    (let ((contents (%runtime-state-string session)))
      (when (or force (not (string= contents (or *runtime-state-signature* ""))))
        (handler-case
            (progn
              (%write-runtime-state-atomically
               (%runtime-state-path *runtime-server-name*)
               contents)
              (setf *runtime-state-signature* contents))
          (error (condition)
            (format *error-output*
                    "~&nerimux: runtime state write failed: ~A~%"
                    condition)))))))

(defun %runtime-restored-pane (session worktree record rows cols)
  (let* ((id (getf record :id))
         (pane
           (handler-case
               (nerimux/pane:%fork-pane session id 0 0 cols rows
                                        :start-dir (worktree-path worktree))
             (error ()
               (make-pane :id id
                          :fd -1
                          :pid -1
                          :width cols
                          :height rows
                          :screen (make-screen cols rows))))))
    (setf (pane-role pane) :terminal
          (pane-agent-kind pane) nil)
    (unless (pane-live-p pane)
      (pane-mark-startup-failure pane))
    (worktree-add-pane worktree pane)
    (pane-notify pane "restored")
    ;; PANE-NOTIFY always marks unread output, which is right for output the
    ;; client stepped away from -- a restored pane was never attached, so
    ;; nothing was missed. A genuine startup failure already set the flag
    ;; above and stays marked; only the synthetic "restored" notice is
    ;; cleared here.
    (when (pane-live-p pane)
      (setf (pane-unread-output-p pane) nil))
    (push pane *runtime-restored-panes*)
    pane))

(defun %runtime-restored-window (session worktree record rows cols window-id)
  ;; The name is read before the panes exist: %worktree-window-name counts the
  ;; worktree's windows through pane-window, and the panes below join the
  ;; worktree with that back-link still unset.
  (let* ((name (%worktree-window-name worktree))
         (pane-records (getf record :panes))
         (panes (mapcar (lambda (pane-record)
                          (%runtime-restored-pane session
                                                  worktree
                                                  pane-record
                                                  rows
                                                  cols))
                        pane-records))
         (tree (nerimux/layout:string->layout (getf record :layout) panes))
         (window (make-window :id window-id
                              :name name
                              :width cols
                              :height rows
                              :panes panes
                              :active (first panes)
                              :tree tree)))
    (dolist (pane panes)
      (setf (pane-window pane) window))
    (window-refresh-panes window)
    (window-relayout window rows cols)
    (when (getf record :zoom)
      (setf (window-zoom-tree window) tree
            (window-zoom-p window) t
            (window-tree window) (nerimux/layout:make-layout-leaf
                                  (first panes)))
      (window-refresh-panes window)
      (window-relayout window rows cols))
    window))

(defun %create-workspace-session ()
  "The session a server starts from: named, empty, no window and no pane.
   Every window belongs to a worktree the user opened, so bootstrapping a
   shell here would put a pane in the `kill` refusal and the C-q Q count that
   no tree row ever shows."
  (make-session :id (incf nerimux/session:*session-id-counter*)
                :name "0"
                :last-active (get-universal-time)))

(defun %restore-runtime-state (form)
  (let* ((rows (max 1 (- *term-rows* +status-line-rows+)))
         (cols (max 1 *term-cols*))
         (session (%create-workspace-session))
         (next-window-id 1)
         (missing-paths (make-hash-table :test #'equal)))
    (setf *runtime-restored-panes* nil
          *runtime-restored-worktrees* nil)
    (clrhash *workspace-expanded-node-ids*)
    (dolist (repository-id (getf (rest form) :expanded))
      (setf (gethash (list :repository repository-id)
                     *workspace-expanded-node-ids*)
            t))
    (dolist (worktree-record (getf (rest form) :worktrees))
      (let ((path (getf worktree-record :path)))
        (if (not (uiop:directory-exists-p path))
            (unless (gethash path missing-paths)
              (setf (gethash path missing-paths) t)
              (format *error-output*
                      "~&nerimux: skipping missing restored worktree ~A~%"
                      path))
            (let ((worktree (make-worktree :id path
                                           :path path
                                           :completed-p
                                           (getf worktree-record :completed))))
              (push worktree *runtime-restored-worktrees*)
              (dolist (window-record (getf worktree-record :windows))
                (let ((window (%runtime-restored-window
                               session
                               worktree
                               window-record
                               rows
                               cols
                               next-window-id)))
                  (incf next-window-id)
                  (session-insert-window session window)))))))
    (when (session-windows session)
      (session-select-window session (first (session-windows session)))
      session)))

(defun %runtime-session-from-state (name)
  (clrhash *workspace-expanded-node-ids*)
  (setf *runtime-restored-panes* nil
        *runtime-restored-worktrees* nil)
  (multiple-value-bind (form path) (%read-runtime-state name)
    (when form
      (handler-case
          (or (%restore-runtime-state form)
              (values nil path))
        (error (condition)
          (%quarantine-runtime-state path condition)
          (setf *runtime-restored-panes* nil
                *runtime-restored-worktrees* nil)
          (clrhash *workspace-expanded-node-ids*)
          nil)))))

(defun %rebind-runtime-worktrees (organizations)
  (dolist (restored (copy-list *runtime-restored-worktrees*))
    (let ((actual
            (find-if (lambda (candidate)
                       (string= (worktree-path restored)
                                (worktree-path candidate)))
                     (loop for organization in organizations append
                       (loop for repository in (organization-repositories organization)
                             append (repository-worktrees repository))))))
      (when actual
        (setf (worktree-completed-p actual)
              (worktree-completed-p restored))
        (dolist (pane (copy-list (worktree-panes restored)))
          (setf (worktree-panes restored)
                (remove pane (worktree-panes restored) :test #'eq))
          (worktree-add-pane actual pane)))))
  (setf *runtime-restored-worktrees*
        (remove-if (lambda (worktree)
                     (null (worktree-panes worktree)))
                   *runtime-restored-worktrees*)))
