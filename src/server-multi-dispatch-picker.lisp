(in-package #:nerimux)

(declaim (special *workspace-catalog-loaded-p* *workspace-scan-progress*))

(defun %client-picker-items (conn)
  (if (eq :branch (client-conn-picker-mode conn))
      (client-conn-picker-items conn)
      (or (client-conn-picker-items conn)
          (setf (client-conn-picker-items conn)
                (nerimux/picker:build-global-picker-items
                 (nerimux/vcs:workspace-organizations))))))

(defun %picker-clamp-index (conn items)
  (setf (client-conn-picker-index conn) (if items
                                            (min (1- (length items))
                                                 (max 0
                                                      (client-conn-picker-index
                                                       conn)))
                                            0)))

(defun %client-picker-filtered-items (conn)
  "Return picker data after applying the client's query and uniqueness rule."
  (%deduplicate-client-picker-items
   (nerimux/picker:filter-global-picker-items
    (%client-picker-items conn)
    (client-conn-picker-query conn)
    :regex-p (client-conn-picker-regex-p conn))))

(defun %client-picker-visible-items (conn)
  (let ((items (%client-picker-filtered-items conn)))
    (%picker-clamp-index conn items)
    items))

(defun %open-client-picker-filtered (conn query)
  "Open the picker with QUERY already typed (R7.6).

   %OPEN-CLIENT-PICKER has already started the catalog scan this needs; a
   second scan here would cancel that one's callbacks and rebuild the item
   list under the query the user is typing into."
  (when (%open-client-picker conn)
    (%set-client-picker-query conn (or query ""))
    conn))

(defun %client-tree-object (conn)
  (or (client-conn-selected-tree-object conn)
      (client-conn-selected-worktree conn)
      (and (client-conn-focus conn)
           (nerimux/pane:pane-worktree (client-conn-focus conn)))))

(defun %client-tree-selection-token (conn)
  (%tree-object-selection-token (%client-tree-object conn)))

(defun %client-selection-token (conn)
  (let ((worktree
         (or (client-conn-selected-worktree conn)
             (and (client-conn-focus conn)
                  (nerimux/pane:pane-worktree (client-conn-focus conn))))))
    (%worktree-selection-token worktree)))

(defun %resolve-client-attach-selection (conn organizations)
  "Resolve what this client attached to, and say so when it is not one thing.

   A selector with a slash can name a repository (github.com/org/repo) or a
   local path, and both can be present at once. Picking one silently would send
   the user somewhere they did not ask for, so an ambiguous selector opens the
   picker with the selector already typed, filtered to what it matched (R7.6).
   Selection by cwd, and by whatever was selected last, is unchanged: neither is
   a selector the user typed, so neither can be ambiguous in this sense.

   An explicit selector does not fall back to cwd or previous selection. A
   relative path is resolved from the attach client CWD before matching. If that
   path equals the repository local path, nested worktrees do not make the
   repository selector ambiguous."
  (let* ((explicit (client-conn-attach-target conn))
         (explicitp (and (stringp explicit) (plusp (length explicit))))
         (cwd (client-conn-attach-cwd conn))
         (relative-selector-pathname
          (and explicitp
               (ignore-errors (sb-ext:parse-native-namestring explicit))))
         (relative-selector-p
          (and relative-selector-pathname
               (eq :relative
                   (first (pathname-directory relative-selector-pathname)))))
         (relative-path
          (and relative-selector-p
               (stringp cwd)
               (plusp (length cwd))
               (let ((cwd-pathname
                      (ignore-errors
                       (sb-ext:parse-native-namestring cwd))))
                 (when (and cwd-pathname
                            (eq :absolute
                                (first (pathname-directory cwd-pathname))))
                   (%workspace-canonical-path
                    (namestring
                     (merge-pathnames
                      relative-selector-pathname
                      (uiop:ensure-directory-pathname cwd-pathname))))))))
         (previous (and (not explicitp)
                        (or (%client-selection-token conn)
                            *last-selected-worktree-token*)))
         (explicit-repository
          (and explicitp
               (or (%workspace-find-repository-for-attach explicit organizations)
                   (and relative-path
                        (%workspace-find-repository-for-attach
                         relative-path organizations)))))
         (same-repository-path-p
          (and relative-path
               explicit-repository
               (equal relative-path
                      (%workspace-canonical-path
                       (nerimux/workspace-model:repository-local-path
                        explicit-repository)))))
         (explicit-worktree
          (and explicitp
               (not same-repository-path-p)
               (or (%workspace-find-worktree explicit organizations)
                   (if relative-selector-p
                       (and relative-path
                            (%workspace-find-worktree-for-attach
                             relative-path organizations))
                     (%workspace-find-worktree-for-attach
                      explicit organizations)))))
         (cwd-worktree
          (and (not explicitp)
               (stringp cwd)
               (plusp (length cwd))
               (%workspace-find-worktree-for-cwd cwd organizations)))
         (previous-worktree
          (and (not cwd-worktree)
               previous
               (%workspace-find-worktree previous organizations))))
    (list :explicit explicit
          :explicit-p explicitp
          :ambiguous-p (and explicitp
                            (not same-repository-path-p)
                            (or (and explicit-worktree explicit-repository)
                                (and relative-path explicit-repository)))
          :worktree (or explicit-worktree cwd-worktree previous-worktree)
          :source (cond (explicit-worktree :explicit)
                        (cwd-worktree :cwd)
                        (previous-worktree :previous))
          :repository explicit-repository
          :organizations-p organizations)))

(defun %client-consume-attach-target (conn)
  "Forget the selector this attach carried, now that it has been acted on.

   Every catalog refresh rebinds every client's selection, and a selector left
   on the connection is acted on again there -- an ambiguous one re-opening the
   picker from inside the refresh the picker itself started, forever."
  (setf (client-conn-attach-target conn) nil))

(defun %client-default-tree-selection (conn organizations)
  "Select the first actionable row for a client that has no selection (RL-01)."
  (when (and organizations (null (%client-tree-object conn)))
    (let ((object (%workspace-default-tree-selection
                   organizations
                   (client-conn-tree-filter conn))))
      (when object
        (%set-client-selected-tree-object conn object)))))

(defun %client-attach-selection (conn organizations)
  (let ((resolution (%resolve-client-attach-selection conn organizations)))
    (cond
      ((getf resolution :ambiguous-p)
       (%client-consume-attach-target conn)
       (%open-client-picker-filtered conn (getf resolution :explicit))
       (values nil nil))
      ((getf resolution :worktree)
       (%client-consume-attach-target conn)
       (progn
          (%set-client-selected-worktree conn (getf resolution :worktree))
          (%client-reveal-tree-selection conn))
       (values (getf resolution :worktree) (getf resolution :source)))
      ((getf resolution :repository)
       (%client-consume-attach-target conn)
       (%set-client-selected-tree-object conn (getf resolution :repository))
       (values nil nil))
      ((and (getf resolution :explicit-p)
            (getf resolution :organizations-p))
       (%client-consume-attach-target conn)
       (setf (client-conn-attach-cwd conn) nil)
       (%client-notify conn
                       (format nil "attach target not found: ~A"
                               (getf resolution :explicit)))
       (values nil nil))
      (t
       (%client-default-tree-selection conn organizations)
       (values nil nil)))))

(defun %rebind-client-status-selection (conn organizations)
  "Re-point the status view's own selection at the refreshed catalog.

   The whole view renders from SELECTED-WORKTREE, and a status row (a section
   header, a file, a commit) is not a worktree, so re-binding it through
   %SET-CLIENT-SELECTED-TREE-OBJECT cleared that slot and blanked the screen --
   the hazard %SELECT-CLIENT-STATUS-RELATIVE already avoids on the n/p path.
   A row the refresh removed (S staged every file under the selected header)
   falls back to the Head row, never to no selection."
  (let ((worktree (or (%workspace-find-worktree
                       (%worktree-selection-token
                        (client-conn-selected-worktree conn))
                       organizations)
                      (client-conn-selected-worktree conn))))
    (setf (client-conn-selected-worktree conn) worktree)
    (let ((objects (%client-status-view-objects conn))
          (current (client-conn-selected-tree-object conn)))
      (setf (client-conn-selected-tree-object conn)
            (cond
              ((typep current 'nerimux/workspace-model:worktree) worktree)
              ((member current objects :test #'equal) current)
              (t (first objects))))))
  (%mark-dirty)
  (client-conn-selected-tree-object conn))

(defun %rebind-client-selection (conn organizations)
  "Re-point CONN's selection at the refreshed catalog (WT-21).

   The attach selection answers only while this client has nothing selected:
   a plain `g` refresh re-running it dragged the cursor back to whatever the
   attach named, undoing wherever the user had since moved. A row the refresh
   no longer knows keeps the object it had rather than being cleared, so the
   status view it feeds does not go blank mid-refresh."
  (let ((explicit (client-conn-attach-target conn)))
    (cond
      ((or (and (stringp explicit) (plusp (length explicit)))
           (null (%client-tree-object conn)))
       (%client-attach-selection conn organizations))
      ((and (eq (client-conn-view conn) :status)
            (client-conn-selected-worktree conn))
       (%rebind-client-status-selection conn organizations))
      (t
       (let ((object (%workspace-find-tree-object
                      (%client-tree-selection-token conn)
                      organizations)))
         (when object
           (%set-client-selected-tree-object conn object)))))))

(defun %set-client-selected-tree-object (conn object)
  (let ((worktree (and (typep object 'nerimux/workspace-model:worktree) object)))
    (setf (client-conn-selected-tree-object conn) object
          (client-conn-selected-worktree conn) worktree)
    (when worktree
      (setf *last-selected-worktree-token* (%worktree-selection-token worktree)))
    (%mark-dirty)
    object))

(defun %set-client-selected-worktree (conn worktree)
  (%set-client-selected-tree-object conn worktree))

(defun %move-client-tree-scroll (conn delta)
  (let* ((objects
          (%workspace-tree-objects (nerimux/vcs:workspace-organizations)
                                   (client-conn-tree-filter conn)))
         (visible-rows
          (max 1
               (nerimux/renderer:workspace-tree-view-rows
                (client-conn-rows conn))))
         (maximum (max 0 (- (length objects) visible-rows))))
    (when (integerp delta)
      (setf (client-conn-tree-scroll conn) (max 0
                                                (min maximum
                                                     (+
                                                      (client-conn-tree-scroll
                                                       conn)
                                                      delta))))))
  (%mark-dirty)
  (client-conn-tree-scroll conn))

(defun %select-client-tree-worktree (conn token)
  (let* ((objects
          (%workspace-tree-objects (nerimux/vcs:workspace-organizations)
                                   (client-conn-tree-filter conn)))
         (object
          (or (%workspace-find-tree-object token)
              (%client-tree-object conn)
              (nth (client-conn-tree-scroll conn) objects))))
    (when object
      (%set-client-selected-tree-object conn object))))

(defun %refresh-client-picker (conn &key on-complete on-error)
  (if (nerimux/vcs:vcs-package-available-p)
      (let ((failed-repository-ids nil))
        (setf *workspace-scan-progress* nil)
        (%set-workspace-catalog-refresh-state
         (nerimux/vcs:workspace-organizations) :mark)
        (handler-case
              (%workspace-refresh-organizations-async
             :callback-dispatch #'%enqueue-main-thread-callback
             :on-catalog
             (lambda (organizations)
               (%set-workspace-catalog-refresh-state organizations :mark)
               (%mark-dirty))
             :on-repository-error
             (lambda (repository condition)
               (declare (ignore condition))
               (pushnew (repository-id repository) failed-repository-ids
                        :test #'equal)
               (%mark-repository-node-stale repository)
               (%mark-dirty))
             :on-complete
             (lambda (organizations)
               (setf *workspace-catalog-loaded-p* t
                     *workspace-scan-progress* nil)
               (%set-workspace-catalog-refresh-state
                organizations :settle :stale-p nil)
               (%reapply-stale-repository-marks organizations failed-repository-ids)
               (dolist (client
                         (remove-duplicates
                          (remove-if-not #'%client-live-p
                                         (cons conn (copy-list *clients*)))
                          :test #'eq))
                 (%rebind-client-selection client organizations)
                 (unless (eq :branch (client-conn-picker-mode client))
                   (setf (client-conn-picker-items client)
                         (nerimux/picker:build-global-picker-items
                          organizations)))
                 (%picker-clamp-index client
                                      (%client-picker-visible-items client)))
               (when (and on-complete (%client-live-p conn))
                 (funcall on-complete organizations))
               (%mark-dirty))
             :on-error
             (lambda (condition)
               (setf *workspace-catalog-loaded-p* t
                     *workspace-scan-progress* nil)
               (%set-workspace-catalog-refresh-state
                (nerimux/vcs:workspace-organizations) :settle :stale-p t)
               (when (and on-error (%client-live-p conn))
                 (funcall on-error condition))
               (%mark-dirty)))
          (error (condition)
            (setf *workspace-catalog-loaded-p* t
                  *workspace-scan-progress* nil)
            (%set-workspace-catalog-refresh-state
             (nerimux/vcs:workspace-organizations) :settle :stale-p t)
            (when (and on-error (%client-live-p conn))
              (funcall on-error condition))
            (%mark-dirty))))
      (let ((organizations (nerimux/vcs:workspace-organizations)))
        (setf (client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items organizations))
        (when on-complete
          (funcall on-complete organizations))))
  conn)

(defvar *client-picker-return-targets*
  (make-hash-table :test #'eq :weakness :key)
  "Each client's saved picker view and pane location, keyed by connection.")

(defun %open-client-picker (conn &key (mode :global) repository)
  (when (%reject-pending-worktree-attachment conn :pane nil)
    (return-from %open-client-picker nil))
  (setf (gethash conn *client-picker-return-targets*)
        (list :view (client-conn-view conn)
              :pane-key (%client-picker-return-pane-key
                         (client-conn-focus conn))))
  (%set-client-modal conn :picker)
  (%set-client-picker-query conn "")
  (setf (client-conn-picker-regex-p conn) nil
        (client-conn-picker-mode conn) mode
        (client-conn-picker-repository conn) repository
        (client-conn-picker-items conn)
        (if (eq mode :branch)
            nil
            (nerimux/picker:build-global-picker-items
             (nerimux/vcs:workspace-organizations))))
  (unless (eq mode :branch)
    (%refresh-client-picker conn))
  (%mark-dirty)
  conn)

(defun %close-client-picker (conn session &key keep-view)
  "Close the picker and restore its saved view and pane on cancellation."
  (when (and (client-conn-focus conn)
             (%reject-pending-worktree-attachment conn))
    (return-from %close-client-picker nil))
  (let ((target (gethash conn *client-picker-return-targets*)))
    (remhash conn *client-picker-return-targets*)
    (when (and target (not keep-view))
      (let* ((pane-key (getf target :pane-key))
             (pane (%resolve-client-picker-return-pane session pane-key)))
        (cond
          (pane (%set-client-focus conn pane session))
          ((and session pane-key)
           (let* ((panes (all-panes session))
                  (resolved (%resolve-client-focus-pane session nil conn))
                  (fallback (or (find resolved panes :test #'eq)
                                (first panes))))
             (if fallback
                 (%set-client-focus conn fallback session)
                 (setf (client-conn-focus conn) nil))
             (%client-notify conn "picker return pane is no longer available"))))
        (%set-client-view conn (getf target :view)))))
  (%set-client-modal conn nil)
  (%set-client-picker-query conn "")
  (setf (client-conn-picker-regex-p conn) nil
        (client-conn-picker-mode conn) :global
        (client-conn-picker-repository conn) nil)
  (%mark-dirty)
  conn)

(defun %client-picker-return-pane-key (pane)
  (let ((window (and pane (nerimux/pane:pane-window pane))))
    (when window
      (list (nerimux/window:window-id window)
            (nerimux/pane:pane-id pane)))))

(defun %resolve-client-picker-return-pane (session key)
  (when (and session key)
    (let ((window
            (find (first key)
                  (nerimux/session:session-windows session)
                  :key #'nerimux/window:window-id
                  :test #'eql)))
      (and window
           (find (second key)
                 (nerimux/window:window-panes window)
                 :key #'nerimux/pane:pane-id
                 :test #'eql)))))
