(in-package #:nerimux/vcs)

(defun vcs-package-available-p ()
  (not (null (find-package :vcs-kit))))

(defun %string-value (value)
  (cond
    ((null value) "")
    ((stringp value) value)
    ((pathnamep value) (namestring value))
    (t (princ-to-string value))))

(defun %specification-parts (specification)
  (let ((parts nil)
        (start 0)
        (string (%string-value specification)))
    (loop for end = (position #\/ string :start start)
          do (push (subseq string start end) parts)
          if end
            do (setf start (1+ end))
          else
            do (return))
    (remove "" (nreverse parts) :test #'string=)))

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
           (%string-value
            (vcs-kit:ghq-repository-entry-specification entry)))
         (path (%string-value (vcs-kit:ghq-repository-entry-path entry)))
         (backend (vcs-kit:ghq-repository-entry-backend entry))
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
;; %APPLY-REPOSITORY-WORKTREES is defined later in this file (near
;; LIST-REPOSITORY-WORKTREES, which it backs); RESOLVE-DIRECTORY-ORGANIZATIONS
;; above that point calls it directly to populate a repository from worktrees
;; already fetched, rather than through LIST-REPOSITORY-WORKTREES, which would
;; re-run `git worktree list` (F1). Same forward-reference shape as the
;; declaim above -- harmless for a function, resolved by load time.
(declaim (ftype function %apply-repository-worktrees))

(defvar *ghq-root-cache* :unresolved
  "Cached result of VCS-KIT:GHQ-ROOT (FR-002/FR-004b's GHQ-ROOT-DIRECTORY).
   The ghq root does not change once nerimux has started, but
   %RENDER-CLIENT-FRAME calls GHQ-ROOT-DIRECTORY on every dirty frame for the
   empty-catalog hint -- caching here is what keeps that from shelling out to
   `ghq root` on every frame instead of only on the first one.")

(defun ghq-root-directory ()
  "The configured ghq root as a string, or NIL when ghq is unavailable or the
   lookup fails. Bootstrap code uses this domain-facing query rather than
   duplicating ghq-root lookup and failure handling."
  (when (eq *ghq-root-cache* :unresolved)
    (setf *ghq-root-cache*
          (and (vcs-package-available-p)
               (handler-case (%string-value (vcs-kit:ghq-root))
                 (error () nil)))))
  *ghq-root-cache*)

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

(defun %worktree-recency (worktree)
  "The most recent activity timestamp among WORKTREE's panes (item 6): the
   later of each pane's last-output and last-focused time. Both are NIL
   until a pane has ever produced output or been focused, so they are
   excluded from the MAX rather than coerced to 0 -- coercing would make
   \"never happened\" sort as an actual instant (epoch 0), only not the most
   recent one, which is a fact about REDUCE's argument order rather than
   about the pane. A worktree with no panes, or only ever-idle ones, has no
   real timestamp to offer and sorts as least-recent (0)."
  (let ((times
          (loop for pane in (nerimux/model:worktree-panes worktree)
                for output = (nerimux/model:pane-last-output-time pane)
                for focused = (nerimux/model:pane-last-focused-time pane)
                when output collect output
                when focused collect focused)))
    (if times (reduce #'max times) 0)))

(defun %repository-recency (repository)
  (let ((times (mapcar #'%worktree-recency
                       (nerimux/model:repository-worktrees repository))))
    (if times (reduce #'max times) 0)))

(defun %organization-recency (organization)
  (let ((times (mapcar #'%repository-recency
                       (nerimux/model:organization-repositories organization))))
    (if times (reduce #'max times) 0)))

(defun %sort-workspace-organizations-by-activity (organizations)
  "Reorder ORGANIZATIONS -- and, in place within each, its repositories, and
   within each of those, its worktrees -- most-recently-active first (item
   6, activity order).

   Runs only from SET-WORKSPACE-ORGANIZATIONS, i.e. only when the catalog is
   published (a scan landing, a merge, a worktree create/delete refresh),
   never per-frame or mid-navigation: the requirement is that a row must not
   move under the cursor while a client is looking at it, and a per-frame
   re-sort would do exactly that on every keystroke that touches pane
   activity (a reader thread's output alone would reorder the tree the
   client is currently scrolling).

   STABLE-SORT keeps ties (equal recency, including the common case where
   every worktree in view is at the default 0) in their existing order,
   which for a freshly scanned catalog is ghq's own enumeration order --
   so an all-idle catalog looks exactly as before this feature.  Sorts
   copies of the WORKTREES/REPOSITORIES lists rather than the lists in
   place: those lists are shared with whatever built them (e.g.
   ORGANIZATION-ADD-REPOSITORY's PUSHNEW), and SORT/STABLE-SORT are
   destructive, so sorting the original list risks corrupting a structure
   another holder of the same list object still expects to see unmodified."
  (dolist (organization organizations)
    (dolist (repository (nerimux/model:organization-repositories organization))
      (setf (nerimux/model:repository-worktrees repository)
            (stable-sort (copy-list (nerimux/model:repository-worktrees
                                     repository))
                        #'>
                        :key #'%worktree-recency)))
    (setf (nerimux/model:organization-repositories organization)
          (stable-sort (copy-list (nerimux/model:organization-repositories
                                   organization))
                      #'>
                      :key #'%repository-recency)))
  (stable-sort (copy-list organizations) #'> :key #'%organization-recency))

(defun set-workspace-organizations (organizations)
  "Replace the workspace catalog with ORGANIZATIONS.

As a side effect, reorders the published catalog -- organizations,
repositories within each, and worktrees within each of those -- most-
recently-active first (%SORT-WORKSPACE-ORGANIZATIONS-BY-ACTIVITY, item 6).
That sort runs only here, i.e. only when the catalog is (re-)published, and
never per-frame or mid-navigation, because a row must not move under a
client's cursor while it is being looked at."
  (check-type organizations list)
  (let ((previous *workspace-organizations*)
        (current (copy-list organizations)))
    (setf *workspace-organizations* current)
    (%preserve-pane-associations previous current)
    ;; Activity order (item 6) is applied here, after pane associations are
    ;; re-established above -- not before -- because a worktree's recency
    ;; comes from its panes' last-output/last-focused times, and those panes
    ;; are only attached to CURRENT's worktree structs once
    ;; %PRESERVE-PANE-ASSOCIATIONS has run.  Sorting first would sort every
    ;; worktree as equally-idle (0), pane associations notwithstanding.
    (setf *workspace-organizations*
          (%sort-workspace-organizations-by-activity *workspace-organizations*))))

(defun %repository-already-present-p (repository organizations)
  (let ((local-path (nerimux/model:repository-local-path repository))
        (specification (nerimux/model:repository-specification repository)))
    (some (lambda (organization)
            (find-if
             (lambda (candidate)
               (or (and local-path
                        (equal local-path
                               (nerimux/model:repository-local-path candidate)))
                   (and specification
                        (equal specification
                               (nerimux/model:repository-specification candidate)))))
             (nerimux/model:organization-repositories organization)))
          organizations)))

(defun merge-workspace-organizations (organizations)
  "Merge ORGANIZATIONS into *WORKSPACE-ORGANIZATIONS* (FR-002): a wholly new
   organization (by id) is added outright; for one already present, only the
   repositories it does not already hold (matched by local-path or
   specification) are added to it. Existing repositories are left untouched
   -- this exists to make a repository RESOLVE-DIRECTORY-ORGANIZATIONS just
   found visible before the next full scan reaches it, not to refresh
   anything already in the catalog. Goes through SET-WORKSPACE-ORGANIZATIONS
   so pane associations survive the merge the same way every other catalog
   mutation preserves them (%PRESERVE-PANE-ASSOCIATIONS)."
  (when organizations
    (let ((merged (copy-list (workspace-organizations)))
          (additions nil))
      (dolist (organization organizations)
        (let ((existing
                (find (nerimux/model:organization-id organization) merged
                      :key #'nerimux/model:organization-id :test #'equal)))
          (if existing
              (dolist (repository
                        (nerimux/model:organization-repositories organization))
                (unless (%repository-already-present-p repository merged)
                  (nerimux/model:organization-add-repository
                   existing repository)))
              (push organization additions))))
      (setf merged (nconc merged (nreverse additions)))
      (set-workspace-organizations merged)))
  (workspace-organizations))

(defun %dispatch-callback (callback-dispatch callback &rest arguments)
  (when callback
    (if callback-dispatch
        (funcall callback-dispatch
                 (lambda () (apply callback arguments)))
        (apply callback arguments))))

(defun refresh-workspace-organizations-async
    (&key query on-catalog on-complete on-error on-progress callback-dispatch)
  "Refresh and store the workspace catalog on a worker thread.
   ON-CATALOG, when given, is called with the organizations as soon as the
   scan itself completes — before the per-repository status refresh, which
   runs `git status` across every repository and can take seconds on a large
   root.  ON-COMPLETE still fires only after the statuses; a UI caller uses
   ON-CATALOG to paint the freshly scanned tree instead of holding the
   \"scanning...\" placeholder until every status has arrived. ON-PROGRESS
   (FR-004b), when given, is called with the running repository count as the
   scan discovers each ghq entry -- before ON-CATALOG, and well before
   ON-COMPLETE's status pass."
  (scan-repositories-async
   :query query
   :callback-dispatch callback-dispatch
   :on-progress on-progress
   :on-complete (lambda (organizations)
                  (set-workspace-organizations organizations)
                  (when on-catalog
                    (funcall on-catalog organizations))
                  (refresh-workspace-status-async
                   :organizations organizations
                   :callback-dispatch callback-dispatch
                   :on-complete on-complete
                   :on-error (lambda (repository condition)
                               (declare (ignore repository))
                               (when on-error
                                 (funcall on-error condition)))))
   :on-error on-error))

(defun scan-repositories (&key query on-complete on-error on-progress)
  "Build the organization/repository hierarchy from ghq-list-repositories.
   ON-PROGRESS (FR-004b), when given, is called once per ghq entry with the
   running count of entries processed so far -- so a caller on a worker
   thread's other end can show \"N found\" while a large ghq root is still
   being walked, instead of only a bare scanning indicator."
  (handler-case
      (let ((organizations (make-hash-table :test #'equal))
            (processed 0))
        (dolist (entry (vcs-kit:ghq-list-repositories :query query))
          (multiple-value-bind (candidate repository)
              (%repository-from-entry entry)
            (let* ((key (nerimux/model:organization-id candidate))
                   (organization
                     (or (gethash key organizations)
                         (setf (gethash key organizations) candidate))))
              (nerimux/model:organization-add-repository
               organization repository)
              ;; One unreadable repository (a broken or half-deleted clone in
              ;; the ghq root) must not abort the scan: the enclosing
              ;; handler-case would blank the entire catalog with no message.
              ;; Keep the entry, mark it missing, move on.
              (handler-case
                  (list-repository-worktrees repository)
                (error ()
                  (setf (nerimux/model:repository-missing-p repository) t)))))
          (incf processed)
          (when on-progress (funcall on-progress processed)))
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
  (vcs-kit:make-vcs-repository directory))

(defun %read-repository-worktrees (repository)
  (let ((backend-repository
          (%make-vcs-repository (nerimux/model:repository-path repository))))
    (values (vcs-kit:vcs-list-worktrees backend-repository)
            (%path-missing-p (nerimux/model:repository-path repository)))))

(defun %apply-repository-worktrees
    (repository raw-worktrees missing-p &optional status-updates)
  (let ((previous (copy-list (nerimux/model:repository-worktrees repository))))
    (setf (nerimux/model:repository-missing-p repository) missing-p)
    (dolist (old-worktree previous)
      (dolist (pane (nerimux/model:worktree-panes old-worktree))
        (setf (nerimux/model:pane-worktree pane) nil)))
    (setf (nerimux/model:repository-worktrees repository) nil
          (nerimux/model:repository-main-worktree repository) nil)
    (dolist (raw raw-worktrees)
      (let* ((path (vcs-kit:vcs-worktree-path raw))
             (status-update
               (find path status-updates
                     :key #'%worktree-status-update-path
                     :test #'string=))
             (old-worktree (find path previous
                                  :key #'nerimux/model:worktree-path
                                  :test #'string=))
             (worktree
               (nerimux/model:make-worktree
                :id (and old-worktree
                         (nerimux/model:worktree-id old-worktree))
                :repository repository
                :path path
                :branch (vcs-kit:vcs-worktree-branch raw)
                :head (vcs-kit:vcs-worktree-head raw)
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
                :bare-p (vcs-kit:vcs-worktree-bare-p raw)
                :locked-p (vcs-kit:vcs-worktree-locked-p raw)
                :prunable-p (vcs-kit:vcs-worktree-prunable-p raw)
                :missing-p (if status-update
                               (%worktree-status-update-missing-p status-update)
                               (%path-missing-p path)))))
        (dolist (pane (nerimux/model:worktree-panes worktree))
          (setf (nerimux/model:pane-worktree pane) worktree))
        (nerimux/model:repository-add-worktree repository worktree)))
    repository))

(defun list-repository-worktrees (repository)
  "Refresh REPOSITORY's worktree list from vcs-list-worktrees."
  (multiple-value-call #'%apply-repository-worktrees
    repository
    (%read-repository-worktrees repository)))

(defun %read-worktree-status-at (path fallback-head repository-path)
  (let* ((directory (if (plusp (length path)) path repository-path))
         (missing-p (and (stringp directory)
                         (plusp (length directory))
                         (null (probe-file directory)))))
    (if missing-p
        (%make-worktree-status-update
         :path path :missing-p t :head fallback-head :ahead 0 :behind 0)
        (let* ((snapshot
                 ;; This reads local remote-tracking refs. Only an explicit
                 ;; fetch advances them, so refresh never performs network I/O.
                 (vcs-kit:vcs-status-structured
                  (%make-vcs-repository directory)))
               (entries (vcs-kit:vcs-status-snapshot-entries snapshot))
               (branch-head
                 (vcs-kit:vcs-status-snapshot-branch-head snapshot)))
          (%make-worktree-status-update
           :path path :snapshot snapshot
           :head (or branch-head fallback-head)
           :dirty-p (not (null entries))
           :conflict-p (not (null (some #'%status-entry-conflict-p entries)))
           :ahead (or (vcs-kit:vcs-status-snapshot-ahead snapshot) 0)
           :behind (or (vcs-kit:vcs-status-snapshot-behind snapshot) 0))))))

(defun %read-worktree-status (worktree)
  (let ((repository (nerimux/model:worktree-repository worktree)))
    (%read-worktree-status-at
     (nerimux/model:worktree-path worktree)
     (nerimux/model:worktree-head worktree)
     (and repository (nerimux/model:repository-path repository)))))

(defun %apply-worktree-status (repository update)
  (let ((worktree
          (nerimux/model:repository-worktree-by-path
           repository (%worktree-status-update-path update))))
    (unless worktree
      (error "Status update refers to an unknown worktree: ~A"
             (%worktree-status-update-path update)))
    (setf (nerimux/model:worktree-missing-p worktree)
          (%worktree-status-update-missing-p update)
          (nerimux/model:worktree-status worktree)
          (%worktree-status-update-snapshot update)
          (nerimux/model:worktree-head worktree)
          (%worktree-status-update-head update)
          (nerimux/model:worktree-dirty-p worktree)
          (%worktree-status-update-dirty-p update)
          (nerimux/model:worktree-conflict-p worktree)
          (%worktree-status-update-conflict-p update)
          (nerimux/model:worktree-ahead worktree)
          (%worktree-status-update-ahead update)
          (nerimux/model:worktree-behind worktree)
          (%worktree-status-update-behind update))
    worktree))

(defun %read-repository-status (repository)
  (loop for worktree in (nerimux/model:repository-worktrees repository)
        ;; A bare root (ghq's `<repo>.git` layout) has no working tree of
        ;; its own, so running `git status` against it always fails; that
        ;; used to turn every successful worktree op into a false "failed"
        ;; notify once this ran during the async catalog status refresh.
        unless (nerimux/model:worktree-bare-p worktree)
          collect (%read-worktree-status worktree)))

(defun %apply-repository-status
    (repository updates &optional (missing-p nil missing-p-p))
  (mapc (lambda (update) (%apply-worktree-status repository update)) updates)
  (setf (nerimux/model:repository-missing-p repository)
        (if missing-p-p
            missing-p
            (%path-missing-p (nerimux/model:repository-path repository))))
  (nerimux/model:repository-recompute-status repository)
  repository)

(defun worktree-status (worktree)
  "Refresh WORKTREE status from vcs-status-structured."
  (let ((repository (nerimux/model:worktree-repository worktree)))
    (%apply-worktree-status repository (%read-worktree-status worktree))
    (when repository
      (setf (nerimux/model:repository-missing-p repository)
            (%path-missing-p (nerimux/model:repository-path repository)))
      (nerimux/model:repository-recompute-status repository))
    worktree))
