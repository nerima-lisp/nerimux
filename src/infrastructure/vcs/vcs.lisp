(in-package #:nerimux/vcs)

(defun vcs-package-available-p ()
  (not (null (find-package :vcs-kit))))

(defun %vcs-symbol (name)
  (let ((package (find-package :vcs-kit)))
    (when package
      (multiple-value-bind (symbol status)
          (find-symbol (string-upcase name) package)
        (declare (ignore status))
        (when (and symbol (fboundp symbol))
          symbol)))))

(defun %vcs-function (name)
  (or (%vcs-symbol name)
      (error "cl-vcs-kit function ~A is unavailable. Load cl-vcs-kit before scanning the workspace."
             name)))

(defun %vcs-call (name &rest arguments)
  (apply (%vcs-function name) arguments))

(defun %optional-vcs-value (object names)
  (dolist (name names)
    (let ((function (%vcs-symbol name)))
      (when function
        (return-from %optional-vcs-value (funcall function object)))))
  nil)

(defun %adapter-string (value)
  (cond
    ((null value) "")
    ((stringp value) value)
    ((pathnamep value) (namestring value))
    (t (princ-to-string value))))

(defun %adapter-boolean (value)
  (not (member value '(nil :false :no "false" "no")
               :test #'equal)))

(defun %adapter-integer (value)
  (cond
    ((integerp value) value)
    ((stringp value)
     (or (ignore-errors (parse-integer value :junk-allowed t)) 0))
    (t 0)))

(defun %specification-parts (specification)
  (let ((parts nil)
        (start 0)
        (string (%adapter-string specification)))
    (loop for end = (position #\/ string :start start)
          do (push (subseq string start end) parts)
          if end
            do (setf start (1+ end))
          else
            do (return))
    (remove-if (lambda (part) (zerop (length part))) (nreverse parts))))

(defun %organization-and-name (specification)
  (let ((parts (%specification-parts specification)))
    (cond
      ((>= (length parts) 3)
       (values (first parts) (second parts)))
      ((= (length parts) 2)
       (values "local" (first parts)))
      ((= (length parts) 1)
       (values "local" "default"))
      (t
       (values "local" "default")))))

(defun %repository-from-entry (entry)
  (let* ((specification
           (%adapter-string
            (%optional-vcs-value
             entry '("GHQ-REPOSITORY-ENTRY-SPECIFICATION"
                    "GHQ-ENTRY-SPECIFICATION"))))
         (path (%adapter-string
                (%optional-vcs-value
                 entry '("GHQ-REPOSITORY-ENTRY-PATH"
                        "GHQ-ENTRY-PATH"))))
         (backend (%optional-vcs-value
                   entry '("GHQ-REPOSITORY-ENTRY-BACKEND"
                          "GHQ-ENTRY-BACKEND")))
         (host nil)
         (name nil))
    (multiple-value-setq (host name)
      (%organization-and-name specification))
    (values
     (nerimux/model:make-organization
      :id (nerimux/model:organization-key host name)
      :host host
      :name name)
     (nerimux/model:make-repository
      :specification specification
      :local-path path
      :backend (or backend :git)))))

(declaim (ftype function list-repository-worktrees))

(defvar *workspace-organizations* nil)

(defun workspace-organizations ()
  "Return the latest workspace catalog used by the global picker."
  (copy-list *workspace-organizations*))

(defun %catalog-worktrees (organizations)
  (loop for organization in organizations
        append (loop for repository in
                         (nerimux/model:organization-repositories organization)
                     append (copy-list
                             (nerimux/model:repository-worktrees repository)))))

(defun %worktree-association-match-p (id path worktree)
  (or (and (stringp id)
           (plusp (length id))
           (string= id (nerimux/model:worktree-id worktree)))
      (and (stringp path)
           (plusp (length path))
           (string= path (nerimux/model:worktree-path worktree)))))

(defun %remember-pane-associations (organizations)
  (loop for worktree in (%catalog-worktrees organizations)
        append (loop for pane in (nerimux/model:worktree-panes worktree)
                     collect (list (nerimux/model:worktree-id worktree)
                                   (nerimux/model:worktree-path worktree)
                                   pane))))

(defun %preserve-pane-associations (previous current)
  (let ((worktrees (%catalog-worktrees current)))
    (dolist (record (%remember-pane-associations previous))
      (destructuring-bind (id path pane) record
        (let ((worktree
                (find-if (lambda (candidate)
                           (%worktree-association-match-p id path candidate))
                         worktrees)))
          (if worktree
              (nerimux/model:worktree-add-pane worktree pane)
              (setf (nerimux/model:pane-worktree pane) nil))))))
  current)

(defun set-workspace-organizations (organizations)
  "Replace the workspace catalog with ORGANIZATIONS."
  (check-type organizations list)
  (let ((previous *workspace-organizations*)
        (current (copy-list organizations)))
    (setf *workspace-organizations* current)
    (%preserve-pane-associations previous current)))

(defun refresh-workspace-organizations (&key query on-complete on-error)
  "Refresh and store the workspace catalog synchronously."
  (handler-case
      (let ((organizations (scan-repositories :query query)))
        (set-workspace-organizations organizations)
        (dolist (repository
                  (loop for organization in organizations
                        append (nerimux/model:organization-repositories
                                organization)))
          (refresh-repository-status repository))
        (when on-complete
          (funcall on-complete organizations))
        organizations)
    (error (condition)
      (if on-error
          (progn
            (funcall on-error condition)
            nil)
          (error condition)))))

(defun refresh-workspace-organizations-async (&key query on-complete on-error)
  "Refresh and store the workspace catalog on a worker thread."
  (scan-repositories-async
   :query query
   :on-complete (lambda (organizations)
                  (set-workspace-organizations organizations)
                  (refresh-workspace-status-async
                   :organizations organizations
                   :on-complete on-complete
                   :on-error (lambda (repository condition)
                               (declare (ignore repository))
                               (when on-error
                                 (funcall on-error condition)))))
   :on-error on-error))

(defun scan-repositories (&key query on-complete on-error)
  "Build the organization/repository hierarchy from ghq-list-repositories."
  (handler-case
      (let ((organizations (make-hash-table :test #'equal)))
        (dolist (entry (if query
                           (%vcs-call "GHQ-LIST-REPOSITORIES" :query query)
                           (%vcs-call "GHQ-LIST-REPOSITORIES")))
          (multiple-value-bind (candidate repository)
              (%repository-from-entry entry)
            (let* ((key (nerimux/model:organization-id candidate))
                   (organization
                     (or (gethash key organizations)
                         (setf (gethash key organizations) candidate))))
              (nerimux/model:organization-add-repository
               organization repository)
              (list-repository-worktrees repository))))
        (let ((result
                (sort (loop for organization being the hash-values of organizations
                            collect organization)
                      #'string<
                      :key #'nerimux/model:organization-id)))
          (when on-complete
            (funcall on-complete result))
          result))
    (error (condition)
      (if on-error
          (progn
            (funcall on-error condition)
            nil)
          (error condition)))))

(defun %make-vcs-repository (directory)
  (%vcs-call "MAKE-VCS-REPOSITORY" directory))

(defun %raw-worktree-value (raw names)
  (%optional-vcs-value raw names))

(defun %path-missing-p (path)
  (and (stringp path)
       (plusp (length path))
       (null (ignore-errors (probe-file path)))))

(defun list-repository-worktrees (repository)
  "Refresh REPOSITORY's worktree list from vcs-list-worktrees."
  (let* ((previous (copy-list (nerimux/model:repository-worktrees repository)))
         (backend-repository
           (%make-vcs-repository (nerimux/model:repository-path repository)))
         (raw-worktrees
           (%vcs-call "VCS-LIST-WORKTREES" backend-repository)))
    (setf (nerimux/model:repository-missing-p repository)
          (%path-missing-p (nerimux/model:repository-path repository)))
    (dolist (old-worktree previous)
      (dolist (pane (nerimux/model:worktree-panes old-worktree))
        (setf (nerimux/model:pane-worktree pane) nil)))
    (setf (nerimux/model:repository-worktrees repository) nil
          (nerimux/model:repository-main-worktree repository) nil)
    (dolist (raw raw-worktrees)
      (let* ((path (%adapter-string
                    (%raw-worktree-value
                     raw '("VCS-WORKTREE-PATH" "WORKTREE-PATH"))))
             (old-worktree (find path previous
                                  :key #'nerimux/model:worktree-path
                                  :test #'string=))
             (worktree
               (nerimux/model:make-worktree
                :id (and old-worktree
                         (nerimux/model:worktree-id old-worktree))
                :repository repository
                :path path
                :branch (%raw-worktree-value
                         raw '("VCS-WORKTREE-BRANCH" "WORKTREE-BRANCH"))
                :head (%raw-worktree-value
                       raw '("VCS-WORKTREE-HEAD" "WORKTREE-HEAD"))
                :status (and old-worktree
                             (nerimux/model:worktree-status old-worktree))
                :panes (and old-worktree
                            (nerimux/model:worktree-panes old-worktree))
                :dirty-p (and old-worktree
                              (nerimux/model:worktree-dirty-p old-worktree))
                :conflict-p (and old-worktree
                                 (nerimux/model:worktree-conflict-p old-worktree))
                :ahead (if old-worktree
                           (nerimux/model:worktree-ahead old-worktree)
                           0)
                :behind (if old-worktree
                            (nerimux/model:worktree-behind old-worktree)
                            0)
                :bare-p (%adapter-boolean
                         (%raw-worktree-value
                          raw '("VCS-WORKTREE-BARE-P" "VCS-WORKTREE-BARE")))
                :locked-p (%adapter-boolean
                           (%raw-worktree-value
                            raw '("VCS-WORKTREE-LOCKED-P"
                                  "VCS-WORKTREE-LOCKED")))
                :prunable-p (%adapter-boolean
                             (%raw-worktree-value
                              raw '("VCS-WORKTREE-PRUNABLE-P"
                                    "VCS-WORKTREE-PRUNABLE")))
                :missing-p
                (or (%adapter-boolean
                     (%raw-worktree-value
                      raw '("VCS-WORKTREE-MISSING-P"
                            "WORKTREE-MISSING-P"
                            "VCS-WORKTREE-MISSING")))
                    (%path-missing-p path))
                :tags (and old-worktree
                           (nerimux/model:worktree-tags old-worktree))
                :notes (and old-worktree
                            (nerimux/model:worktree-notes old-worktree))
                :recent-activity (and old-worktree
                                      (nerimux/model:worktree-recent-activity
                                       old-worktree)))))
        (dolist (pane (nerimux/model:worktree-panes worktree))
          (setf (nerimux/model:pane-worktree pane) worktree))
        (nerimux/model:repository-add-worktree repository worktree)))
    repository))

(defun %status-entry-conflict-p (entry)
  (or (%adapter-boolean
       (%optional-vcs-value
        entry '("VCS-STATUS-ENTRY-CONFLICT-P"
               "VCS-STATUS-ENTRY-CONFLICT")))
      (member (%optional-vcs-value
               entry '("VCS-STATUS-ENTRY-KIND" "VCS-STATUS-ENTRY-INDEX-STATUS"))
              '(:unmerged :conflict :conflicted "unmerged" "conflict" "conflicted")
              :test #'equal)))

(defun worktree-status (worktree)
  "Refresh WORKTREE status from vcs-status-structured."
  (let* ((repository (nerimux/model:worktree-repository worktree))
         (worktree-path (nerimux/model:worktree-path worktree))
         (directory (if (plusp (length worktree-path))
                        worktree-path
                        (and repository
                             (nerimux/model:repository-path repository))))
         (missing-p (and (stringp directory)
                         (plusp (length directory))
                         (null (ignore-errors (probe-file directory))))))
    (if missing-p
        (progn
          (setf (nerimux/model:worktree-missing-p worktree) t
                (nerimux/model:worktree-status worktree) nil
                (nerimux/model:worktree-dirty-p worktree) nil
                (nerimux/model:worktree-conflict-p worktree) nil
                (nerimux/model:worktree-ahead worktree) 0
                (nerimux/model:worktree-behind worktree) 0)
         (when repository
            (setf (nerimux/model:repository-missing-p repository)
                  (%path-missing-p (nerimux/model:repository-path repository)))
            (nerimux/model:repository-recompute-status repository))
          worktree)
        (let* ((backend-repository (%make-vcs-repository directory))
               (snapshot (%vcs-call "VCS-STATUS-STRUCTURED" backend-repository))
               (entries (%optional-vcs-value
                         snapshot '("VCS-STATUS-SNAPSHOT-ENTRIES"
                                    "VCS-STATUS-ENTRIES")))
               (branch-head (%optional-vcs-value
                             snapshot '("VCS-STATUS-SNAPSHOT-BRANCH-HEAD"
                                        "VCS-STATUS-BRANCH-HEAD")))
               (ahead (%optional-vcs-value
                       snapshot '("VCS-STATUS-SNAPSHOT-AHEAD"
                                  "VCS-STATUS-AHEAD")))
               (behind (%optional-vcs-value
                        snapshot '("VCS-STATUS-SNAPSHOT-BEHIND"
                                   "VCS-STATUS-BEHIND"))))
          (setf (nerimux/model:worktree-missing-p worktree) nil
                (nerimux/model:worktree-status worktree) snapshot
                (nerimux/model:worktree-head worktree)
                (if branch-head
                    branch-head
                    (nerimux/model:worktree-head worktree))
                (nerimux/model:worktree-dirty-p worktree) (not (null entries))
                (nerimux/model:worktree-conflict-p worktree)
                (not (null (some #'%status-entry-conflict-p entries)))
                (nerimux/model:worktree-ahead worktree) (%adapter-integer ahead)
                (nerimux/model:worktree-behind worktree) (%adapter-integer behind))
          (when repository
            (setf (nerimux/model:repository-missing-p repository)
                  (%path-missing-p (nerimux/model:repository-path repository)))
            (nerimux/model:repository-recompute-status repository))
          worktree))))

(defun refresh-repository-status (repository)
  "Refresh all statuses for REPOSITORY synchronously."
  (dolist (worktree (nerimux/model:repository-worktrees repository))
    (worktree-status worktree))
  (nerimux/model:repository-recompute-status repository)
  repository)

(defun scan-repositories-async (&key query on-complete on-error)
  "Run SCAN-REPOSITORIES on a worker thread and return its thread handle."
  (cl-concurrent-kit:make-thread
   (lambda ()
     (scan-repositories :query query
                        :on-complete on-complete
                        :on-error on-error))
   :name "nerimux-vcs-scan"))

(defun refresh-repositories-async
    (repositories &key on-repository on-complete on-error
                            (refresh-function #'refresh-repository-status))
  "Refresh each repository on its own worker and return all thread handles."
  (let* ((repositories (copy-list repositories))
         (remaining (cl-concurrent-kit:make-atomic-counter
                     (length repositories)))
         (threads nil))
    (labels ((complete-one ()
               (cl-concurrent-kit:atomic-counter-decf remaining)
               (when (zerop (cl-concurrent-kit:atomic-counter-value remaining))
                 (when on-complete
                   (funcall on-complete repositories)))))
      (if (null repositories)
          (progn
            (when on-complete
              (funcall on-complete repositories))
            nil)
          (progn
            (dolist (repository repositories (nreverse threads))
              (let ((current repository))
                (push
                 (cl-concurrent-kit:make-thread
                  (lambda ()
                    (unwind-protect
                         (handler-case
                             (progn
                               (funcall refresh-function current)
                               (when on-repository
                                 (funcall on-repository current))
                               current)
                           (error (condition)
                             (if on-error
                                 (progn
                                   (funcall on-error current condition)
                                   nil)
                                 (error condition))))
                      (complete-one)))
                  :name (format nil "nerimux-vcs-status-~A"
                                (nerimux/model:repository-id current)))
                 threads))))))))

(defun refresh-workspace-status-async
    (&key (organizations *workspace-organizations*) on-repository on-complete
          on-error (refresh-function #'refresh-repository-status))
  "Refresh all catalog repositories concurrently without blocking the UI."
  (refresh-repositories-async
   (loop for organization in organizations
         append (nerimux/model:organization-repositories organization))
   :on-repository on-repository
   :on-complete on-complete
   :on-error on-error
   :refresh-function refresh-function))

(defun %replace-all (string old new)
  (let ((start 0))
    (with-output-to-string (stream)
      (loop for position = (search old string :start2 start)
            do (if position
                   (progn
                     (write-string string stream :start start :end position)
                     (write-string new stream)
                     (setf start (+ position (length old))))
                   (progn
                     (write-string string stream :start start)
                     (return)))))))

(defun %resolve-worktree-path (repository branch path path-template)
  (or (and path (%adapter-string path))
      (let* ((repository-path
               (pathname (nerimux/model:repository-path repository)))
             (directory (pathname-directory repository-path))
             (parent
               (make-pathname :directory (and directory (butlast directory))
                              :name nil
                              :type nil
                              :defaults repository-path))
             (repository-name
               (or (pathname-name repository-path) "repository"))
             (branch-name (%adapter-string branch))
             (template (or path-template "{repository}-{branch}"))
             (rendered (%replace-all
                        (%replace-all
                         (%replace-all (%adapter-string template)
                                       "{repository}" repository-name)
                         "{branch}" branch-name)
                        "{name}" branch-name)))
        (namestring (merge-pathnames rendered parent)))))

(defun create-worktree
    (repository &key branch path path-template (new-branch-p t) force)
  "Create a worktree and refresh its repository model.

When NEW-BRANCH-P is true, BRANCH is created with git worktree add -b.
Otherwise BRANCH is treated as an existing commit or branch."
  (unless (and repository branch (plusp (length (%adapter-string branch))))
    (error "A repository and non-empty branch are required to create a worktree."))
  (let* ((branch-name (%adapter-string branch))
         (worktree-path
           (%resolve-worktree-path repository branch-name path path-template))
         (backend-repository
           (%make-vcs-repository (nerimux/model:repository-path repository)))
         (arguments
           (if new-branch-p
               (append (list "add")
                       (when force (list "--force"))
                       (list "-b" branch-name worktree-path))
               (append (list "add")
                       (when force (list "--force"))
                       (list worktree-path branch-name)))))
    (apply #'%vcs-call "VCS-WORKTREE" backend-repository arguments)
    (list-repository-worktrees repository)
    (refresh-repository-status repository)
    (or (nerimux/model:repository-worktree-by-path repository worktree-path)
        (error "VCS created a worktree but it was not returned by list-worktrees: ~A"
               worktree-path))))

(defun delete-worktree (worktree &key force)
  "Remove WORKTREE after protecting the repository's primary checkout."
  (let* ((repository (and worktree (nerimux/model:worktree-repository worktree)))
         (main-worktree
           (and repository (nerimux/model:repository-main-worktree repository))))
    (unless (and worktree repository)
      (error "A repository worktree is required to delete a worktree."))
    (when (or (eq worktree main-worktree)
              (and main-worktree
                   (string= (nerimux/model:worktree-path worktree)
                            (nerimux/model:worktree-path main-worktree))))
      (error "The repository's primary worktree cannot be deleted."))
    (let ((backend-repository
            (%make-vcs-repository (nerimux/model:repository-path repository)))
          (arguments
            (append (list "remove")
                    (when force (list "--force"))
                    (list (nerimux/model:worktree-path worktree)))))
      (apply #'%vcs-call "VCS-WORKTREE" backend-repository arguments)
      (list-repository-worktrees repository)
      (refresh-repository-status repository)
      t)))

(defun %run-vcs-operation-async (name thunk on-complete on-error)
  (cl-concurrent-kit:make-thread
   (lambda ()
     (handler-case
         (let ((result (funcall thunk)))
           (when on-complete
             (funcall on-complete result))
           result)
       (error (condition)
         (when on-error
           (funcall on-error condition))
         nil)))
   :name name))

(defun create-worktree-async
    (repository &key branch path path-template (new-branch-p t) force
                  on-complete on-error)
  "Create a worktree on a worker thread and invoke one callback."
  (%run-vcs-operation-async
   "nerimux-vcs-worktree-create"
   (lambda ()
     (create-worktree repository
                      :branch branch
                      :path path
                      :path-template path-template
                      :new-branch-p new-branch-p
                      :force force))
   on-complete
   on-error))

(defun delete-worktree-async (worktree &key force on-complete on-error)
  "Delete a worktree on a worker thread and invoke one callback."
  (%run-vcs-operation-async
   "nerimux-vcs-worktree-delete"
   (lambda () (delete-worktree worktree :force force))
   on-complete
   on-error))

