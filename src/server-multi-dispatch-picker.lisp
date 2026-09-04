(in-package #:nerimux)

(defun %client-picker-items (conn)
  (or (client-conn-picker-items conn)
      (setf (client-conn-picker-items conn) (nerimux/picker:build-global-picker-items
                                             (nerimux/vcs:workspace-organizations)))))

(defun %picker-clamp-index (conn items)
  (setf (client-conn-picker-index conn) (if items
                                            (min (1- (length items))
                                                 (max 0
                                                      (client-conn-picker-index
                                                       conn)))
                                            0)))

(defun %deduplicate-client-picker-items (items)
  (let ((worktrees (make-hash-table :test #'eq)))
    (loop for item in items
          for worktree = (nerimux/picker:picker-item-worktree item)
          unless (and worktree (gethash worktree worktrees))
            collect (progn
                      (when worktree
                        (setf (gethash worktree worktrees) t))
                      item))))

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
  "Open the picker with QUERY already typed (R7.6)."
  (%open-client-picker conn)
  (setf (client-conn-picker-query conn) (or query ""))
  (%refresh-client-picker conn)
  (%mark-dirty)
  conn)

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

   Returns a property list consumed by %CLIENT-ATTACH-SELECTION."
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
                (%workspace-find-repository-for-attach explicit organizations)))
         (cwd-worktree
           (and (not explicit-worktree)
                (stringp cwd)
                (plusp (length cwd))
                (%workspace-find-worktree-for-cwd cwd organizations)))
         (previous-worktree
           (and (not explicit-worktree)
                (not cwd-worktree)
                previous
                (%workspace-find-worktree previous organizations))))
    (list :explicit explicit
          :explicit-p explicitp
          :ambiguous-p (and explicit-worktree explicit-repository)
          :worktree (or explicit-worktree cwd-worktree previous-worktree)
          :source (cond (explicit-worktree :explicit)
                        (cwd-worktree :cwd)
                        (previous-worktree :previous))
          :repository explicit-repository
          :organizations-p organizations)))

(defun %client-attach-selection (conn organizations)
  (let ((resolution (%resolve-client-attach-selection conn organizations)))
    (cond
      ((getf resolution :ambiguous-p)
       (%open-client-picker-filtered conn (getf resolution :explicit))
       (values nil nil))
      ((getf resolution :worktree)
       (%set-client-selected-worktree conn (getf resolution :worktree))
       (values (getf resolution :worktree) (getf resolution :source)))
      ((getf resolution :repository)
       (%set-client-selected-tree-object conn (getf resolution :repository))
       (values nil nil))
      ((and (getf resolution :explicit-p)
            (getf resolution :organizations-p))
       (%client-notify conn
                       (format nil "attach target not found: ~A"
                               (getf resolution :explicit)))
       (values nil nil))
      (t
       (values nil nil)))))

(defun %rebind-client-selection (conn organizations)
  (or (%client-attach-selection conn organizations)
      (let* ((token (%client-tree-selection-token conn))
             (object (%workspace-find-tree-object token organizations)))
        (%set-client-selected-tree-object conn object))))

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
        (%set-workspace-catalog-refresh-state
         (nerimux/vcs:workspace-organizations) :mark)
        (handler-case
            (nerimux/vcs:refresh-workspace-organizations-async
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
               (%set-workspace-catalog-refresh-state
                organizations :settle :stale-p nil)
               (%reapply-stale-repository-marks organizations failed-repository-ids)
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
               (%set-workspace-catalog-refresh-state
                (nerimux/vcs:workspace-organizations) :settle :stale-p t)
               (when (and on-error (%client-live-p conn))
                 (funcall on-error condition))
               (%mark-dirty)))
          (error (condition)
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

(defun %open-client-picker (conn)
  (%set-client-modal conn :picker)
  (setf (client-conn-picker-query conn) ""
        (client-conn-picker-regex-p conn) nil
        (client-conn-picker-index conn) 0
        (client-conn-picker-items conn) (nerimux/picker:build-global-picker-items
                                         (nerimux/vcs:workspace-organizations)))
  (%refresh-client-picker conn)
  (%mark-dirty)
  conn)

(defun %close-client-picker (conn)
  (%set-client-modal conn nil)
  (%set-client-view conn
                    (if (client-conn-focus conn)
                        :pane
                        :repolist))
  (setf (client-conn-picker-query conn) ""
        (client-conn-picker-regex-p conn) nil
        (client-conn-picker-index conn) 0)
  (%mark-dirty)
  conn)

(defun %picker-selected-item (conn)
  (let ((items (%client-picker-visible-items conn)))
    (and items (nth (client-conn-picker-index conn) items))))

(defun %set-client-picker-query (conn value)
  (when (stringp value)
    (setf (client-conn-picker-query conn) value
          (client-conn-picker-index conn) 0)
    (%mark-dirty)
    t))

(defun %set-client-picker-regex (conn value supplied-p)
  (setf (client-conn-picker-regex-p conn) (if supplied-p
                                              (cond
                                                ((member value
                                                         '(:on "on"
                                                               "true"
                                                               "1"
                                                               t)
                                                         :test
                                                         #'equal) t)
                                                ((member value
                                                         '(:off "off"
                                                                "false"
                                                                "0"
                                                                nil)
                                                         :test
                                                         #'equal) nil)
                                                (t
                                                 (client-conn-picker-regex-p
                                                  conn)))
                                              (not
                                               (client-conn-picker-regex-p conn)))
        (client-conn-picker-index conn) 0)
  (%mark-dirty)
  (client-conn-picker-regex-p conn))

(defun %delete-client-picker-query-character (conn)
  (let ((query (client-conn-picker-query conn)))
    (when (plusp (length query))
      (setf (client-conn-picker-query conn) (subseq query 0 (1- (length query)))
            (client-conn-picker-index conn) 0)
      (%mark-dirty)
      t)))

(defun %append-client-picker-query-octets (conn payload)
  (let ((text
         (cond
           ((stringp payload) payload)
           ((vectorp payload)
            (handler-case (cl-codec-kit:octets-to-string payload
                                                         :encoding
                                                         :utf-8)
              (cl-codec-kit:decode-error ()
                nil))))))
    (when 
        (and text
             (every
              (lambda (character)
                (>= (char-code character) 32))
              text))
      (setf (client-conn-picker-query conn) (concatenate 'string
                                                         (client-conn-picker-query
                                                          conn)
                                                         text)
            (client-conn-picker-index conn) 0)
      (%mark-dirty)
      t)))

(defun %move-client-picker-index (conn delta)
  (let ((items (%client-picker-visible-items conn)))
    (when items
      (setf (client-conn-picker-index conn) (mod
                                             (+ (client-conn-picker-index conn)
                                                delta)
                                             (length items)))
      (%mark-dirty)
      t)))

(defun %handle-client-picker-key-payload (session conn payload)
  (cond
    ((or (equalp payload #(13)) (equalp payload #(10)))
     (%select-client-picker-item session conn))
    ((equalp payload #(27))
      (%client-esc-swallow-start conn)
      (%close-client-picker conn)
      t)
    ((equalp payload #(18)) (%set-client-picker-regex conn nil nil))
    ((equalp payload #(16)) (%move-client-picker-index conn -1))
    ((equalp payload #(14)) (%move-client-picker-index conn 1))
    ((or (equalp payload #(8)) (equalp payload #(127)))
     (%delete-client-picker-query-character conn))
    (t (%append-client-picker-query-octets conn payload))))
