(in-package #:nerimux)

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
  "The tree rows a client can currently select, in display order.

   Delegates to the renderer rather than walking the model itself. It used to
   flatten organization -> repository -> worktree unconditionally, which was
   correct only while the tree was always fully expanded: once R6.3 made rows
   collapse and added the window and pane levels, this enumeration and the drawn
   frame described different lists, and j/k walked the cursor onto rows the
   frame was not showing."
  (nerimux/renderer:workspace-tree-objects organizations
                                           (%workspace-expanded-nodes)))

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
       (plusp (length directory))
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
  "Resolve an EXPLICIT attach selector TOKEN to a worktree.
   The prefix fallback deliberately asks \"is TOKEN a directory prefix of the
   worktree's path\" -- TOKEN names a place to search UNDER, so an ancestor
   token matching the first worktree found is the intended behavior here
   (pinned by server-dispatch-helper-tests).  Do not reuse this for cwd-based
   auto-selection: a cwd is the LONGER string, and this direction silently
   matched an arbitrary worktree from any ancestor directory --
   %WORKSPACE-FIND-WORKTREE-FOR-CWD below is that path's correct inverse."
  (or (%workspace-find-worktree token organizations)
      (find-if (lambda (worktree)
                 (%workspace-directory-prefix-p
                  token
                  (nerimux/model:worktree-path worktree)))
               (%workspace-worktrees organizations))))

(defun %workspace-find-worktree-for-cwd (cwd organizations)
  "The worktree CWD sits inside, preferring the most specific (deepest) match.

   %workspace-find-worktree-for-attach is for an explicit selector: TOKEN names a
   directory to search under, so the worktree's path is the longer string and
   TOKEN the prefix. A cwd runs the other way -- it is the longer string, and the
   worktree's path must be its prefix. Reusing the attach direction here let any
   ancestor of every worktree (the ghq root, $HOME) match every worktree path as
   a 'prefix' of TOKEN and silently pre-select whichever worktree the scan
   reached first. Two worktrees can also nest (one's path a prefix of another's),
   so this keeps the longest-matching -- most specific -- worktree rather than
   the first one found."
  (or (%workspace-find-worktree cwd organizations)
      (let ((best nil))
        (dolist (worktree (%workspace-worktrees organizations))
          (let ((path (nerimux/model:worktree-path worktree)))
            (when (and (%workspace-directory-prefix-p path cwd)
                       (or (null best)
                           (> (length path)
                              (length (nerimux/model:worktree-path best)))))
              (setf best worktree))))
        best)))

(defun %workspace-find-repository-for-attach (token organizations)
  "The repository TOKEN names, by specification, local path, or id (R7.6).

   `nerimux attach github.com/org/repo` is a repository selector, and until this
   existed the attach path matched only against worktrees — so a repository
   spec resolved to nothing and reported \"attach target not found\" for
   something the workspace was holding."
  (when (and (stringp token) (plusp (length token)))
    (loop for organization in organizations
          thereis
          (find-if (lambda (repository)
                     (some (lambda (field)
                             (and (stringp field) (string= field token)))
                           (list (nerimux/model:repository-specification
                                  repository)
                                 (nerimux/model:repository-local-path repository)
                                 (nerimux/model:repository-id repository))))
                   (nerimux/model:organization-repositories organization)))))

(defun %open-client-picker-filtered (conn query)
  "Open the picker with QUERY already typed (R7.6)."
  (%open-client-picker conn)
  (setf (client-conn-picker-query conn) (or query ""))
  (%refresh-client-picker conn)
  (%mark-dirty)
  conn)

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
  "Resolve what this client attached to, and say so when it is not one thing.

   A selector with a slash can name a repository (github.com/org/repo) or a
   local path, and both can be present at once. Picking one silently would send
   the user somewhere they did not ask for, so an ambiguous selector opens the
   picker with the selector already typed, filtered to what it matched (R7.6).
   Selection by cwd, and by whatever was selected last, is unchanged: neither is
   a selector the user typed, so neither can be ambiguous in this sense."
  (let* ((explicit (client-conn-attach-target conn))
         (explicitp (and (stringp explicit) (plusp (length explicit))))
         (cwd (client-conn-attach-cwd conn))
         (previous (or (%client-selection-token conn)
                       *last-selected-worktree-token*))
         (explicit-worktree
           (and explicitp
                (%workspace-find-worktree-for-attach explicit organizations)))
         (explicit-repository
           (and explicitp
                (%workspace-find-repository-for-attach explicit organizations))))
    (cond
      ;; Both readings hit: let the user say which, rather than guessing.
      ((and explicit-worktree explicit-repository)
       (%open-client-picker-filtered conn explicit)
       nil)
      (t
       (let ((worktree
               (or explicit-worktree
                   (and (stringp cwd)
                        (plusp (length cwd))
                        (%workspace-find-worktree-for-cwd cwd organizations))
                   (and previous
                        (%workspace-find-worktree previous organizations)))))
         (cond
           (worktree
            (%set-client-selected-worktree conn worktree))
           ;; A repository and no worktree in it: select the repository so the
           ;; overview opens there, rather than reporting it as not found.
           (explicit-repository
            (%set-client-selected-tree-object conn explicit-repository))
           ((and explicitp organizations)
            (%client-notify conn
                            (format nil "attach target not found: ~A" explicit))))
         worktree)))))

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
      (let ((refresh-failed-p nil))
        (%set-workspace-catalog-refresh-state
         (nerimux/vcs:workspace-organizations))
        (handler-case
            (nerimux/vcs:refresh-workspace-organizations-async
             :callback-dispatch #'%enqueue-main-thread-callback
             :on-catalog
             (lambda (organizations)
               (%set-workspace-catalog-refresh-state organizations)
               (%mark-dirty))
             :on-complete
             (lambda (organizations)
               (%set-workspace-catalog-refresh-state
                organizations :stale-p refresh-failed-p)
               (dolist (client
                         (remove-duplicates
                          (remove-if-not #'%client-live-p
                                         (cons conn (copy-list *clients*)))
                          :test #'eq))
                 (%rebind-client-selection client organizations)
                 (setf (client-conn-picker-items client)
                       (nerimux/picker:build-global-picker-items organizations))
                 (%picker-clamp-index client
                                      (%client-picker-visible-items client)))
               (when (and on-complete (%client-live-p conn))
                 (funcall on-complete organizations))
               (%mark-dirty))
             :on-error
             (lambda (condition)
               (setf refresh-failed-p t)
               (%set-workspace-catalog-refresh-state
                (nerimux/vcs:workspace-organizations) :stale-p t)
               (when (and on-error (%client-live-p conn))
                 (funcall on-error condition))
               (%mark-dirty)))
          (error (condition)
            (setf refresh-failed-p t)
            (%set-workspace-catalog-refresh-state
             (nerimux/vcs:workspace-organizations) :stale-p t)
            (when (and on-error (%client-live-p conn))
              (funcall on-error condition))
            (%mark-dirty))))
      (let ((organizations (nerimux/vcs:workspace-organizations)))
        (setf (client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items organizations))
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

;;; %worktree-window-name and %worktree-windows live in workspace-window.lisp
;;; (which loads before this file), next to the other worktree-window
;;; creation logic they serve.

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
       (%client-notify conn "worktree is missing")
       nil)
      (t
       (handler-case
           (let ((*term-rows* (client-conn-rows conn))
                 (*term-cols* (client-conn-cols conn)))
             (let* ((window (%workspace-new-window
                             session
                             :name (%worktree-window-name worktree)
                             :start-dir path
                             :start-reader-p nil))
                    (pane (window-active-pane window)))
               (cond
                 ((null pane)
                  (%client-notify conn "worktree pane unavailable")
                  nil)
                 ((not (pane-live-p pane))
                  ;; R5.7: a pane that came back without a live PTY is a
                  ;; startup failure — record it as durable pane state
                  ;; (pane-mark-startup-failure) instead of only a
                  ;; one-shot notification, so it survives as the `!`
                  ;; overview mark (3.4) rather than vanishing once the
                  ;; message log scrolls. No reader thread: start-reader-thread
                  ;; would call select-fds on a dead pane's fd (-1 or worse,
                  ;; unvalidated), which process-kit rejects outright.
                  (pane-mark-startup-failure pane)
                  (worktree-add-pane worktree pane)
                  (%set-client-selected-worktree conn worktree)
                  (%set-client-focus conn pane)
                  (%client-notify conn "worktree pane failed to start")
                  (%mark-dirty)
                  t)
                 (t
                  (start-reader-thread pane)
                  (worktree-add-pane worktree pane)
                  (%set-client-selected-worktree conn worktree)
                  (%set-client-focus conn pane)
                  (%mark-dirty)
                  t))))
         (error (condition)
           (%client-notify
            conn
            (format nil "worktree open failed: ~A" condition))
           nil))))))

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
               (cl-codec-kit:decode-error () nil))))))
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
     ;; R4.3: the client forwards one byte at a time, so an arrow key still
     ;; arrives as ESC [ A/B/C/D across 3 separate key messages. Swallow the
     ;; 2 bytes that would otherwise follow so they cannot land in whatever
     ;; mode this ESC leaves the connection in.
     (%client-esc-swallow-start conn)
     (%close-client-picker conn)
     t)
    ((equalp payload #(18))
     (%set-client-picker-regex conn nil nil))
    ;; C-p / C-n move the selection. Not j and k: every other key here is a
    ;; character of the search query, so a letter cannot also be a movement.
    ;; This replaces four ESC [ A/B/C/D branches that were unreachable — the
    ;; client sends one byte at a time, so the ESC closed the picker and R4.3
    ;; swallowed the two bytes that would have identified the arrow. That left
    ;; the picker with no way to move the selection at all.
    ((equalp payload #(16))
     (%move-client-picker-index conn -1))
    ((equalp payload #(14))
     (%move-client-picker-index conn 1))
    ((or (equalp payload #(8))
         (equalp payload #(127)))
     (%delete-client-picker-query-character conn))
    (t
     (%append-client-picker-query-octets conn payload))))
