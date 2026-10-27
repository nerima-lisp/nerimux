(in-package #:nerimux/vcs)

(defparameter *worktree-operation-timeout-seconds*
  vcs-kit::+default-vcs-timeout+
  "Maximum time allowed for a Git worktree write operation.")

(defparameter *worktree-operation-environment-update*
  '(("GIT_TERMINAL_PROMPT" . "0")
    ("GIT_ASKPASS" . "true")
    ("SSH_ASKPASS" . "true")
    ("GIT_SSH_COMMAND" . "ssh -oBatchMode=yes"))
  "Environment updates that keep Git worktree writes non-interactive.")

(defvar *worktree-test-environment-update* nil)

(defun %worktree-operation-environment-update-for-child ()
  (append
   (remove-if
    (lambda (entry)
      (assoc (car entry) *worktree-test-environment-update* :test (function string=)))
    *worktree-operation-environment-update*)
   *worktree-test-environment-update*))

(defun %worktree-operation-execution-options ()
  (list :timeout *worktree-operation-timeout-seconds*
        :environment-update
        (%worktree-operation-environment-update-for-child)))

(defstruct worktree-prune-snapshot identity content changed-files)

(defun %prune-file-identity (path directory-p &optional allow-missing)
  (let* ((stat (handler-case (uiop:symbol-call :sb-posix :lstat path)
                 (error (condition)
                   (if (and allow-missing
                            (typep condition (find-symbol "SYSCALL-ERROR" :sb-posix))
                            (= (uiop:symbol-call :sb-posix :syscall-errno condition)
                               (symbol-value (find-symbol "ENOENT" :sb-posix))))
                       (return-from %prune-file-identity nil)
                       (error condition)))))
         (mode (uiop:symbol-call :sb-posix :stat-mode stat)))
    (unless (uiop:symbol-call :sb-posix (if directory-p :s-isdir :s-isreg) mode)
      (error "workspace prune refuses symlinks, submodules and special files: ~A" path))
    (list (uiop:symbol-call :sb-posix :stat-dev stat)
          (uiop:symbol-call :sb-posix :stat-ino stat) mode)))

(defun %read-worktree-prune-snapshot (worktree)
  (let* ((path (nerimux/workspace-model:worktree-path worktree))
         (root (uiop:ensure-directory-pathname path))
         (identity (%prune-file-identity (string-right-trim "/" path) t))
         (repository (vcs-kit:make-repository path))
         (status (vcs-kit:vcs-status-structured (%make-vcs-repository path)
                                               :untracked-files :all :ignored t))
         (entries (vcs-kit:vcs-status-snapshot-entries status))
         (index (vcs-kit:process-result-stdout
                 (vcs-kit:git-ls-files repository "--stage" "-z")))
         (names (vcs-kit:process-result-stdout
                 (vcs-kit:git-ls-files repository "--cached" "--others"
                                         "--exclude-standard" "-z")))
         (content nil))
    (unless (string=
             (vcs-kit:git-rev-parse-value repository "--path-format=absolute" "--git-common-dir")
             (vcs-kit:git-rev-parse-value
              (%repository-checked-handle (nerimux/workspace-model:worktree-repository worktree))
              "--path-format=absolute" "--git-common-dir"))
      (error "workspace prune repository identity mismatch"))
    (when (find :ignored entries :key #'vcs-kit:vcs-status-entry-kind)
      (error "workspace prune excluded: ignored files require manual review"))
    (dolist (name (remove-duplicates
                  (remove "" (uiop:split-string names :separator '(#\Null)) :test #'string=)
                  :test #'string=))
      (let* ((file (uiop:parse-native-namestring
                    (concatenate 'string (namestring root) name)))
             (file-identity (%prune-file-identity (uiop:native-namestring file) nil t)))
        (when file-identity
          (unless (string= (namestring file) (namestring (truename file)))
            (error "workspace prune refuses indirect file paths: ~A" name))
          (push (list name file-identity
                      (vcs-kit:process-result-stdout
                       (vcs-kit:git-hash-object repository "--no-filters" "--" name)))
                content))))
    (make-worktree-prune-snapshot
     :identity (list identity
                     (vcs-kit:git-rev-parse-value repository "--absolute-git-dir")
                     (vcs-kit:git-rev-parse-value repository "HEAD")
                     (vcs-kit:git-rev-parse-value repository "--symbolic-full-name" "HEAD")
                     (%prune-file-identity (namestring (merge-pathnames ".git" root)) nil)
                     (vcs-kit:process-result-stdout
                      (vcs-kit:git-hash-object repository "--no-filters" "--" ".git")))
     :content (list index names (nreverse content))
     :changed-files (%worktree-status-changed-files entries))))

(defun validate-worktree-prune-snapshot (worktree snapshot)
  (let ((current (%read-worktree-prune-snapshot worktree)))
    (unless (and (equal (worktree-prune-snapshot-identity snapshot)
                        (worktree-prune-snapshot-identity current))
                 (equal (worktree-prune-snapshot-content snapshot)
                        (worktree-prune-snapshot-content current))
                 (equal (worktree-prune-snapshot-changed-files snapshot)
                        (worktree-prune-snapshot-changed-files current)))
      (error "workspace changed after prune preflight; retry required"))
    t))

(defun read-worktree-prune-snapshot-async (worktree &key on-complete on-error callback-dispatch on-start)
  (%run-vcs-operation-async "workspace-prune-preflight"
                            (lambda () (%read-worktree-prune-snapshot worktree))
                            #'identity on-complete on-error callback-dispatch on-start))
(defstruct (%worktree-status-update
             (:constructor %make-worktree-status-update))
  (path nil :read-only t)
  (missing-p nil :read-only t)
  (status-state :ready :read-only t)
  (status-error-message nil :read-only t)
  (snapshot nil :read-only t)
  (head nil :read-only t)
  (dirty-p nil :read-only t)
  (conflict-p nil :read-only t)
  (ahead nil :read-only t)
  (behind nil :read-only t)
  (numstat-state :unloaded :read-only t)
  (numstat-error-message nil :read-only t)
  (additions nil :read-only t)
  (deletions nil :read-only t)
  (changed-files nil :read-only t)
  ;; The reading travels with the status capture so generation checks discard it
  ;; with the snapshot it was read beside.
  (stashes nil :read-only t))

(defstruct (%stash-reading
             (:constructor %make-stash-reading
                 (state entries &optional error-message)))
  state
  entries
  error-message)

(defun %status-entry-conflict-p (entry)
  (eq (vcs-kit:vcs-status-entry-kind entry) :unmerged))

(defun %timestamp-token ()
  "Return the current local time as YYYYMMDDTHHMMSS, matching the
`date +%Y%m%dT%H%M%S` convention used for worktree directory names (R7.2)."
  (multiple-value-bind (second minute hour date month year) 
      (decode-universal-time (get-universal-time))
    (format nil
            "~4,'0D~2,'0D~2,'0DT~2,'0D~2,'0D~2,'0D"
            year
            month
            date
            hour
            minute
            second)))

(defun %ensure-trailing-slash (string)
  (if (and (plusp (length string))
           (char= (char string (1- (length string))) #\/))
      string
      (concatenate 'string string "/")))

(defun %worktree-path-candidate (directory base-name suffix)
  (concatenate 'string
               directory
               base-name
               (if suffix
                   (format nil "-~D" suffix)
                   "")))

(defun %unique-worktree-path (directory base-name)
  "Return the first free path under DIRECTORY, starting with BASE-NAME and
then trying -2, -3, and higher suffixes."
  (let ((candidate (%worktree-path-candidate directory base-name nil)))
    (if (null (probe-file candidate))
        candidate
        (loop for suffix from 2
              for numbered = (%worktree-path-candidate directory
                                                       base-name
                                                       suffix)
              when (null (probe-file numbered))
                return numbered))))

(defun %resolve-worktree-path (repository start-point-short-sha path)
  "Resolve the filesystem path for a new worktree.

Return PATH when given. Otherwise generate a timestamped name under
WORKTREE-PARENT-DIRECTORY using START-POINT-SHORT-SHA, adding -2, -3, ... if
the base name already exists."
  (or (and path (%string-value path))
      (%unique-worktree-path
       (worktree-parent-directory repository)
       (format nil "~A-~A" (%timestamp-token) start-point-short-sha))))

(defun %repository-backend (repository)
  (%make-vcs-repository (nerimux/workspace-model:repository-local-path repository)))

(defun %repository-checked-handle (repository)
  (vcs-kit:make-repository
   (%string-value (nerimux/workspace-model:repository-local-path repository))))

(defun %rev-parse (repository &rest arguments)
  (apply (function vcs-kit:git-rev-parse-value)
         (%repository-checked-handle repository)
         (append arguments
                 (when *worktree-test-environment-update*
                   (list :execution-options
                         (list :environment-update
                               *worktree-test-environment-update*))))))

(defun %bare-repository-layout-p (repository)
  "True when REPOSITORY holds no checkout of its own.

The ghq bare clone is named <repo>.git, which settles the question without
running git at all; anything else is asked directly."
  (let* ((path (string-right-trim
                "/"
                (%string-value
                 (nerimux/workspace-model:repository-local-path repository))))
         (length (length path)))
    (or (and (> length 4) (string= ".git" path :start2 (- length 4)))
        (handler-case (string= "true" (%rev-parse repository "--is-bare-repository"))
          (error () nil)))))

(defun %worktrees-directory-ignored-p (repository)
  "True when git ignores the REPOSITORY .worktrees directory.

The query uses a path inside .worktrees so the rule works before it exists."
  (handler-case
      (progn
        ;; VCS-KIT:git-check-ignore does not accept the fixture environment update.
        (if *worktree-test-environment-update*
            (%run-git-read
             (%string-value
              (nerimux/workspace-model:repository-local-path repository))
             "check-ignore" "-q" "--" ".worktrees/name")
            (vcs-kit:git-check-ignore (%repository-checked-handle repository)
                                      "-q" "--" ".worktrees/name"))
        t)
    (error () nil)))

(defvar *worktrees-exclude-written-repository-ids* (make-hash-table :test #'equal)
  "Repository ids this server run has already appended the .worktrees/ rule to.")

(defun %worktrees-exclude-rule-present-p (exclude)
  "True when EXCLUDE already carries a line saying .worktrees/."
  (with-open-file (stream exclude :direction :input :if-does-not-exist nil)
    (when stream
      (loop for line = (read-line stream nil nil)
            while line
            thereis (string= ".worktrees/"
                             (string-trim '(#\Space #\Tab #\Return) line))))))

(defun %ensure-worktrees-directory-ignored (repository)
  "Make git ignore REPOSITORY's .worktrees directory, reporting whether it does.

A worktree created under a checkout that does not ignore .worktrees leaves the
repository untracked-dirty, so the rule is written to .git/info/exclude, which
belongs to this clone alone and is not itself tracked. A repository whose git
directory cannot be written keeps its worktrees outside instead.

The write happens at most once per repository: a .gitignore negation can
outrank info/exclude, leaving the re-check answering NIL however many times
the rule is appended, and every create then added another identical line to a
file nothing ever prunes."
  (or (%worktrees-directory-ignored-p repository)
      (handler-case
          (let ((exclude (merge-pathnames
                          "info/exclude"
                          (%ensure-trailing-slash
                           (%rev-parse repository "--path-format=absolute"
                                       "--git-common-dir"))))
                (id (nerimux/workspace-model:repository-id repository)))
            (ensure-directories-exist exclude)
            (unless (or (gethash id *worktrees-exclude-written-repository-ids*)
                        (%worktrees-exclude-rule-present-p exclude))
              (with-open-file (stream exclude :direction :output
                                              :if-exists :append
                                              :if-does-not-exist :create)
                (write-line ".worktrees/" stream)))
            (setf (gethash id *worktrees-exclude-written-repository-ids*) t)
            (%worktrees-directory-ignored-p repository))
        (error () nil))))

(defun worktree-parent-directory (repository)
  "Directory that receives REPOSITORY's new worktrees (R7.2).

A bare repository has no working tree to disturb. A checkout keeps its
worktrees in .worktrees once git ignores that directory, and beside itself
when the ignore rule cannot be established."
  (let ((root (%ensure-trailing-slash
               (%string-value
                (nerimux/workspace-model:repository-local-path repository)))))
    (if (or (%bare-repository-layout-p repository)
            (%ensure-worktrees-directory-ignored repository))
        (concatenate 'string root ".worktrees/")
        (concatenate 'string (string-right-trim "/" root) "-worktrees/"))))

(defun %optional-rev-parse (repository revision)
  "REVISION's commit, or NIL when REPOSITORY does not have that ref."
  (handler-case
      (let ((resolved (%rev-parse repository "--verify" "--quiet" revision)))
        (and (stringp resolved) (plusp (length resolved)) resolved))
    (error () nil)))

(defun %default-branch-start-point (repository &key (remote-ref-p t))
  "Return the commit a new worktree starts from: the tip of REPOSITORY's
default branch as the remote has it, its local branch when there is no
remote-tracking ref, and the local HEAD when neither resolves. A repository
with no remote, or one whose default branch is not main, is routine in real
use, and reading a fixed origin/main refspec made the create flow unusable
there. HEAD is resolvable for any repository with at least one commit, which
is the only kind CREATE-WORKTREE is ever called against.

REMOTE-REF-P NIL skips refs/remotes/origin: a caller whose fetch just failed
knows the tracking ref names whatever the last successful fetch left there,
and starting a worktree from an unconfirmed tracking ref is the failure mode
the fetch exists to prevent.

An origin tracking ref is only as current as the last fetch. Call
FETCH-REPOSITORY or FETCH-REPOSITORY-ASYNC first when the start point must
reflect the remote's latest state. If the HEAD fallback also fails (e.g. an
empty repository with no commits), the error is left to signal normally."
  (let ((branch (%repository-default-branch repository)))
    (or (and branch
             remote-ref-p
             (%optional-rev-parse repository
                                  (format nil "refs/remotes/origin/~A^{commit}" branch)))
        (and branch
             (%optional-rev-parse repository
                                  (format nil "refs/heads/~A^{commit}" branch)))
        (%rev-parse repository "HEAD"))))

(defun %short-sha (repository commit)
  (%rev-parse repository "--short" commit))

(defun %created-worktree-by-path (repository worktree-path)
  (or
   (nerimux/workspace-model:repository-worktree-by-path repository worktree-path)
   (nerimux/workspace-model:repository-worktree-by-path
    repository
    (string-right-trim
     "/"
     (namestring
      (truename
       (merge-pathnames
        worktree-path
        (%ensure-trailing-slash
         (nerimux/workspace-model:repository-local-path repository)))))))
   (error
    "VCS created a worktree but it was not returned by list-worktrees: ~A"
    worktree-path)))
(defun create-worktree (repository &key branch path start-point force)
  "Create a worktree on a new local branch and refresh the repository model.

BRANCH names the new branch. PATH, when given, must resolve under the worktree
parent. If attachment fails after branch creation, the operation removes that
branch and reports any cleanup failure. START-POINT defaults to the repository's
default branch tip when not given."
  (unless (and repository branch (plusp (length (%string-value branch))))
    (error
     "A repository and non-empty branch are required to create a worktree."))
  (let ((branch-name (%string-value branch)))
    (when (char= (char branch-name 0) #\-)
      (error "A branch name cannot start with -"))
    (when (search "@{" branch-name)
      (error "A branch name cannot contain @{"))
    (let ((canonical-path (and path (validate-worktree-path repository path))))
      (when (and path (null canonical-path))
        (error "Worktree path must stay under the repository worktree parent."))
      (let* ((resolved-start-point
               (or (and start-point (%string-value start-point))
                   (%default-branch-start-point repository)))
             (worktree-path
               (%resolve-worktree-path
                repository
                (%short-sha repository resolved-start-point)
                canonical-path)))
        (%create-worktree-from-new-branch
         repository branch-name worktree-path resolved-start-point force)
        (list-repository-worktrees repository)
        (refresh-repository-status repository)
        (%created-worktree-by-path repository worktree-path)))))

(defun %refresh-worktree-repository (repository)
  (list-repository-worktrees repository)
  (refresh-repository-status repository))

(defun delete-worktree (worktree &key force)
  "Remove WORKTREE after protecting the repository's primary checkout."
  (let ((repository (%delete-worktree-command worktree force)))
    (%refresh-worktree-repository repository)
    t))

(defun lock-worktree (worktree &key reason)
  "Lock WORKTREE so prune and delete operations skip it until unlocked."
  (let ((repository (%lock-worktree-command worktree reason)))
    (%refresh-worktree-repository repository)
    t))

(defun unlock-worktree (worktree)
  "Unlock WORKTREE, restoring it to prune and delete eligibility."
  (let ((repository (%unlock-worktree-command worktree)))
    (%refresh-worktree-repository repository)
    t))

(defun prune-worktrees (repository &key (dry-run t) verbose)
  "Prune REPOSITORY's stale worktree administrative files.

When DRY-RUN is true (the default), git worktree prune --dry-run reports
what would be removed without mutating anything; callers must only pass a
false DRY-RUN once a user has explicitly confirmed the operation."
  (let* ((operation (%prune-worktrees-command repository dry-run verbose))
         (result (second operation)))
    (%refresh-worktree-repository repository)
    result))

(defun %run-vcs-operation-async (name worker
                                      apply-result
                                      on-complete
                                      on-error
                                      callback-dispatch &optional on-start)
  (let ((test-environment-update *worktree-test-environment-update*))
    (cl-concurrent-kit:make-thread
     (lambda ()
       (let ((*worktree-test-environment-update* test-environment-update))
         (%dispatch-callback callback-dispatch on-start)
         (handler-case (let ((worker-result (funcall worker)))
                         (%dispatch-callback callback-dispatch
                                             (lambda ()
                                               (handler-case (let ((result
                                                                    (funcall
                                                                     apply-result
                                                                     worker-result)))
                                                               (when on-complete
                                                                 (funcall
                                                                  on-complete
                                                                  result)))
                                                 (error (condition)
                                                   (when on-error
                                                     (funcall on-error condition))))))
                         worker-result)
           (error (condition)
             (%dispatch-callback callback-dispatch on-error condition)
             nil))))
     :name
     name)))

(defstruct 
    (%worktree-operation-result (:constructor %make-worktree-operation-result))
  (repository nil :read-only t)
  (value nil :read-only t)
  (catalog-generation nil :read-only t)
  (catalog nil :read-only t)
  (repository-generation nil :read-only t)
  (previous-worktrees nil :read-only t)
  (refresh nil :read-only t))

(defun %capture-worktree-operation-result
    (repository value &optional (generation (%begin-repository-data-generation repository)))
  (let ((catalog (%repository-data-generation-catalog generation))
        (catalog-generation (%repository-data-generation-catalog-generation generation))
        (previous (%repository-data-generation-worktrees generation)))
    (%make-worktree-operation-result :repository
                                   repository
                                   :value
                                   value
                                   :catalog-generation catalog-generation
                                   :catalog catalog
                                   :repository-generation generation
                                   :previous-worktrees previous
                                   :refresh
                                   (%read-repository-refresh repository))))

(defun %begin-worktree-request (target)
  (let ((repository (typecase target
                      (nerimux/workspace-model:repository target)
                      (nerimux/workspace-model:worktree
                       (nerimux/workspace-model:worktree-repository target)))))
    (when repository (%begin-repository-data-generation repository))))

(defun %apply-worktree-operation-result (operation-result)
  (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
    (unless (%repository-data-generation-current-p
             (%worktree-operation-result-repository operation-result)
             (%worktree-operation-result-repository-generation operation-result)
             :before-apply t)
      (error "Worktree refresh was superseded; refresh the workspace catalogue."))
    (%apply-repository-refresh
     (%worktree-operation-result-repository operation-result)
     (%worktree-operation-result-refresh operation-result)))
  (%worktree-operation-result-value operation-result))
(defun %worktree-command-arguments (operation &rest arguments)
  (append (list operation) (remove nil arguments)))
(defun %create-worktree-arguments
    (branch path start-point force &key existing-branch-p)
  (append (list "add")
          (when force
            (list "--force"))
          (unless existing-branch-p
            (list "-b" branch))
          (list "--" path start-point)))
(defun %create-worktree-from-new-branch
    (repository branch path start-point force &key track-p)
  (let ((backend (%repository-backend repository)))
    (apply #'vcs-kit:vcs-branch
           (append (list backend)
                   (when track-p (list "--track"))
                   (list "--" branch
                         (if track-p (subseq start-point (length "refs/remotes/")) start-point)
                         :execution-options
                         (%worktree-operation-execution-options))))
    (handler-case
        (apply #'vcs-kit:vcs-worktree
               backend
               (append (%create-worktree-arguments
                        branch path branch force :existing-branch-p t)
                       (list :execution-options
                             (%worktree-operation-execution-options))))
      (error (creation-error)
        (handler-case
            (vcs-kit:vcs-branch
             backend "-D" "--" branch
             :execution-options
             (%worktree-operation-execution-options))
          (error (cleanup-error)
            (error "Worktree creation failed (~A); branch cleanup failed (~A)"
                   creation-error cleanup-error)))
        (error creation-error)))))

(defun %read-worktree-branch-candidates (repository)
  "Return branch candidates as plists with these keys:
:BRANCH is the short branch name; :KIND is :LOCAL or :REMOTE; :REF is the
full Git ref; :REMOTE is the remote name (or NIL for local branches); and
:WORKTREE is the checked-out worktree, or NIL when no matching checkout exists.
Remote checkouts are associated only when their upstream is the exact selected ref."
  (unless repository
    (error "A repository is required to list branch candidates."))
  (let* ((repository (list-repository-worktrees repository))
         (directory (nerimux/workspace-model:repository-local-path repository))
         (worktrees (nerimux/workspace-model:repository-worktrees repository))
         (remote-names
           (sort
            (remove "" (uiop:split-string (%run-git-read directory "remote")
                                           :separator (list #\Newline))
                    :test #'string=)
            #'>
            :key #'length))
         (ref-output
           (%run-git-read directory
                          "for-each-ref"
                          "--format=%(refname)%00%(symref)%00%(upstream)"
                          "refs/heads/"
                          "refs/remotes/"))
         (local-upstreams (make-hash-table :test #'equal))
         (candidates nil))
    (labels ((prefix-p (prefix string)
               (and (>= (length string) (length prefix))
                    (string= prefix string :end2 (length prefix))))
             (remote-parts (reference)
               (let* ((name (subseq reference (length "refs/remotes/")))
                      (remote
                        (find-if (lambda (candidate)
                                   (prefix-p (concatenate 'string candidate "/")
                                             name))
                                 remote-names)))
                 (if remote
                     (values remote (subseq name (1+ (length remote))))
                     (let ((separator (position #\/ name)))
                       (when separator
                         (values (subseq name 0 separator)
                                 (subseq name (1+ separator))))))))
             (checkout-for (branch &optional selected-remote-ref)
               (find-if
                (lambda (worktree)
                  (let* ((checked-out
                           (nerimux/workspace-model:worktree-branch worktree))
                         (checked-out-branch
                           (cond
                             ((and (stringp checked-out)
                                   (prefix-p "refs/heads/" checked-out))
                              (subseq checked-out (length "refs/heads/")))
                             ((stringp checked-out) checked-out)))
                         (local-ref
                           (and checked-out-branch
                                (concatenate 'string
                                             "refs/heads/"
                                             checked-out-branch)))
                         (upstream (and local-ref
                                        (gethash local-ref local-upstreams))))
                    (and checked-out-branch
                         (string= branch checked-out-branch)
                         (or (null selected-remote-ref)
                             (and (stringp upstream)
                                  (string= selected-remote-ref upstream))))))
                worktrees)))
      (dolist (line (uiop:split-string ref-output :separator (list #\Newline)))
        (let* ((fields
                 (uiop:split-string (string-right-trim (list #\Return) line)
                                    :separator (list #\Null)))
               (reference (first fields))
               (symbolic-target (or (second fields) ""))
               (upstream (or (third fields) "")))
          (when (and reference
                     (plusp (length reference))
                     (string= symbolic-target ""))
            (cond
              ((prefix-p "refs/heads/" reference)
               (let ((branch (subseq reference (length "refs/heads/"))))
                 (setf (gethash reference local-upstreams) upstream)
                 (push (list :branch branch
                             :kind :local
                             :ref reference
                             :remote nil
                             :worktree (checkout-for branch))
                       candidates)))
              ((prefix-p "refs/remotes/" reference)
               (multiple-value-bind (remote branch) (remote-parts reference)
                 (when (and remote branch (plusp (length branch)))
                   (push (list :branch branch
                               :kind :remote
                               :ref reference
                               :remote remote
                               :worktree (checkout-for branch reference))
                         candidates))))))))
      (nreverse candidates))))

(defun %create-worktree-command (repository branch path start-point force &optional generation)
  (unless (and repository branch (plusp (length (%string-value branch))))
    (error
     "A repository and non-empty branch are required to create a worktree."))
  (let ((branch-name (%string-value branch)))
    (when (char= (char branch-name 0) #\-)
      (error "A branch name cannot start with -"))
    (when (search "@{" branch-name)
      (error "A branch name cannot contain @{"))
    (let ((canonical-path (and path (validate-worktree-path repository path))))
      (when (and path (null canonical-path))
        (error "Worktree path must stay under the repository worktree parent."))
      (let* ((candidates (unless start-point
                           (%read-worktree-branch-candidates repository)))
             (local-matches
              (remove-if-not
               (lambda (candidate)
                 (and (eq :local (getf candidate :kind))
                      (string= branch-name (getf candidate :branch))))
               candidates))
             (remote-candidates
              (remove-if-not (lambda (candidate)
                               (eq :remote (getf candidate :kind)))
                             candidates))
             (matching-remotes
              (remove-if-not (lambda (candidate)
                               (string= branch-name (getf candidate :branch)))
                             remote-candidates))
             (qualified-remotes
              (remove-if-not
               (lambda (candidate)
                 (string= branch-name
                          (format nil "~A/~A"
                                  (getf candidate :remote)
                                  (getf candidate :branch))))
               remote-candidates))
             (interpretations
              (remove-duplicates
               (append local-matches
                       qualified-remotes
                       ;; An exact local name wins over unqualified remote names.
                       (unless local-matches matching-remotes))
               :test #'string=
               :key (lambda (candidate) (getf candidate :ref))))
             (selected-candidate (first interpretations)))
        (when (> (length interpretations) 1)
          (error "Branch selector is ambiguous; specify one unambiguous name."))
        (when generation
          (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
            (unless (%repository-data-generation-current-p repository generation)
              (error "Worktree refresh was superseded; refresh the workspace catalogue."))
            (setf generation
                  (%begin-repository-data-generation repository))))
        (let* ((selected-branch
                (or (and selected-candidate (getf selected-candidate :branch))
                    branch-name))
               (resolved-start-point
                (or (and selected-candidate (getf selected-candidate :ref))
                    (and start-point (%string-value start-point))
                    (%default-branch-start-point repository)))
               (worktree (and selected-candidate
                              (getf selected-candidate :worktree)))
               (worktree-path
                (if worktree
                    (nerimux/workspace-model:worktree-path worktree)
                  (%resolve-worktree-path
                   repository
                   (%short-sha repository resolved-start-point)
                   canonical-path)))
               (remote-candidate-p
                (and selected-candidate
                     (eq :remote (getf selected-candidate :kind))))
               (new-branch-p (or (null selected-candidate) remote-candidate-p)))
          (unless worktree
            (when (and remote-candidate-p
                       (find-if (lambda (candidate)
                                  (and (eq :local (getf candidate :kind))
                                       (string= selected-branch (getf candidate :branch))))
                                candidates))
              (error (format nil "Cannot create a worktree from remote branch ~A/~A because local branch ~A already exists. Select ~A to use the local branch, or rename/remove it first." (getf selected-candidate :remote) selected-branch selected-branch selected-branch)))
            (if new-branch-p
                (%create-worktree-from-new-branch
                 repository
                 selected-branch
                 worktree-path
                 resolved-start-point
                 (and force (null selected-candidate))
                 :track-p remote-candidate-p)
              (apply #'vcs-kit:vcs-worktree
                     (%repository-backend repository)
                     (append (%create-worktree-arguments
                              selected-branch worktree-path selected-branch nil
                              :existing-branch-p t)
                             (list :execution-options
                                   (%worktree-operation-execution-options))))))
          (values worktree-path generation))))))

(defun %apply-created-worktree (repository operation-result)
  (let ((worktree-path (%apply-worktree-operation-result operation-result)))
    (%created-worktree-by-path repository worktree-path)))

(defun %worktree-operation-command (worktree operation &rest options)
  (let ((repository
         (and worktree (nerimux/workspace-model:worktree-repository worktree))))
    (unless (and worktree repository)
      (error "A repository worktree is required for this operation."))
    (apply #'vcs-kit:vcs-worktree
           (%repository-backend repository)
           (append (apply #'%worktree-command-arguments operation options)
                   (list (nerimux/workspace-model:worktree-path worktree)
                         :execution-options
                         (%worktree-operation-execution-options))))
    repository))

(defun %delete-worktree-command (worktree force)
  (let* ((repository
          (and worktree (nerimux/workspace-model:worktree-repository worktree)))
         (main-worktree
          (and repository
               (nerimux/workspace-model:repository-main-worktree repository))))
    (unless (and worktree repository)
      (error "A repository worktree is required to delete a worktree."))
    (when 
        (or (eq worktree main-worktree)
            (and main-worktree
                 (string= (nerimux/workspace-model:worktree-path worktree)
                          (nerimux/workspace-model:worktree-path main-worktree))))
      (error "The repository's primary worktree cannot be deleted."))
    (when (or (some #'nerimux/pane:pane-live-p
                    (nerimux/workspace-model:worktree-panes worktree))
              (nerimux/pane:pane-live-p
               (nerimux/workspace-model:worktree-agent-pane worktree)))
      (error "Close the worktree's live panes before deleting it."))
    (%worktree-operation-command worktree
                                 "remove"
                                 (when force
                                   "--force"))))

(defun %lock-worktree-command (worktree reason)
  (%worktree-operation-command worktree
                               "lock"
                               (when 
                                   (and reason
                                        (plusp (length (%string-value reason))))
                                 "--reason")
                               (when 
                                   (and reason
                                        (plusp (length (%string-value reason))))
                                 (%string-value reason))))

(defun %unlock-worktree-command (worktree)
  (%worktree-operation-command worktree "unlock"))

(defun %prune-worktrees-command (repository dry-run verbose)
  (unless repository
    (error "A repository is required to prune worktrees."))
  (let ((result
         (apply #'vcs-kit:vcs-worktree
                (%repository-backend repository)
                (append (%worktree-command-arguments "prune"
                                                     (when dry-run
                                                       "--dry-run")
                                                     (when verbose
                                                       "--verbose"))
                        (list :execution-options
                              (%worktree-operation-execution-options))))))
    (list repository result)))

(in-package #:nerimux/vcs)

(defun validate-worktree-path (repository path)
  "Return PATH's canonical absolute destination when it stays under the worktree parent."
  (when (and repository path)
    (let ((path-string (%string-value path)))
      (when (plusp (length path-string))
        (unless (member ".."
                        (uiop:split-string path-string :separator '(#\/))
                        :test #'string=)
          (let* ((pathname (uiop:parse-native-namestring path-string))
                 (pathname (if (eq :absolute (first (pathname-directory pathname)))
                               pathname
                               (merge-pathnames
                                pathname
                                (uiop:ensure-directory-pathname
                                 (nerimux/workspace-model:repository-local-path
                                  repository)))))
                 (candidate (resolve-path-prefix pathname))
                 (parent (resolve-path-prefix
                          (uiop:parse-native-namestring
                           (worktree-parent-directory repository)))))
            (when (and candidate parent
                       (path-under-directory-p candidate parent))
              (namestring candidate))))))))
