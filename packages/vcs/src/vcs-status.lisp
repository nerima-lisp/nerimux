(in-package #:nerimux/vcs)

(defvar *git-read-output-limit* (* 1024 1024)
  "Maximum stdout byte count captured by %RUN-GIT-READ. Output over this limit
signals %GIT-READ-ERROR.")
(defparameter *vcs-diagnostic-logger*
  (log-kit:make-logger
   :name "nerimux/vcs"
   :handler (make-instance 'log-kit:text-handler :stream *error-output*)
   :level log-kit:+level-info+)
  "Structured logger for non-TUI VCS diagnostics.")
(defconstant +numstat-pathspec-argv-byte-limit+ (* 128 1024)
  "Maximum UTF-8 bytes, including NUL terminators, passed in numstat pathspec arguments.")

(defvar *git-read-timeout-seconds* 30
  "Deadline for one %RUN-GIT-READ call. A process that exceeds it is terminated
and reported as %GIT-READ-ERROR.")

(defconstant +status-error-message-max-length+ 400
  "Maximum characters retained for a displayed status failure reason.")

(define-condition %git-read-error (error)
  ((directory :initarg :directory :reader %git-read-error-directory)
   (subcommand :initarg :subcommand :reader %git-read-error-subcommand)
   (arguments :initarg :arguments :reader %git-read-error-arguments)
   (exit-code :initarg :exit-code :initform nil :reader %git-read-error-exit-code)
   (output-limit :initarg :output-limit :initform nil
                 :reader %git-read-error-output-limit)
   (stderr :initarg :stderr :initform nil :reader %git-read-error-stderr))
  (:report
   (lambda (condition stream)
     (format stream "git ~A failed~@[ (exit ~D)~]~@[ (stdout exceeded ~D-byte limit)~]~@[ : ~A~]"
             (%git-read-error-subcommand condition)
             (%git-read-error-exit-code condition)
             (%git-read-error-output-limit condition)
             (%git-read-error-stderr condition))))
  (:documentation
   "Signaled by %RUN-GIT-READ for a non-zero git exit, stdout overflow, timeout,
or launch failure."))

(defun %sanitize-status-error-text (text)
  "Collapse control characters to spaces and cap TEXT for a one-line UI reason."
  (let ((clean
          (with-output-to-string (stream)
            (loop for character across (if (stringp text) text "")
                  do (cond
                       ((or (char= character #\Newline)
                            (char= character #\Return)
                            (char= character #\Tab))
                        (write-char #\Space stream))
                       ((not (nerimux/text:control-character-p character))
                        (write-char character stream)))))))
    (let ((clean (string-trim '(#\Space) clean)))
      (if (> (length clean) +status-error-message-max-length+)
          (concatenate 'string
                       (subseq clean 0 (- +status-error-message-max-length+ 3))
                       "...")
          clean))))

(defun %git-read-error-message (condition)
  "Return a bounded, single-line explanation suitable for model and renderer."
  (if (typep condition '%git-read-error)
      (let* ((command
               (format nil "git ~A" (%git-read-error-subcommand condition)))
             (exit-code (%git-read-error-exit-code condition))
             (stderr (%git-read-error-stderr condition))
             (detail
               (or stderr
                   (and (%git-read-error-output-limit condition)
                        (format nil "output exceeded ~D-byte limit"
                                (%git-read-error-output-limit condition)))
                   "no diagnostic output")))
        (%sanitize-status-error-text
         (if exit-code
             (format nil "~A exited ~D: ~A" command exit-code detail)
             (format nil "~A failed: ~A" command detail))))
      (%sanitize-status-error-text (princ-to-string condition))))

(defun %process-result-stderr-text (result)
  (let ((stderr (process-kit:process-result-stderr result)))
    (cond
      ((null stderr) nil)
      ((stringp stderr) (%sanitize-status-error-text stderr))
      (t
       (%sanitize-status-error-text
        (sb-ext:octets-to-string stderr
                                 :external-format '(:utf-8 :replacement #\?)))))))

(defun %run-git-read (directory subcommand &rest arguments)
  "Run git through VCS-KIT with a deadline and bounded octet capture."
  (let ((result
          (handler-case
              (apply (function vcs-kit:run-vcs)
                     nil subcommand arguments
                     (append
                      (list :executable "git"
                            :directory directory
                            :input ""
                            :timeout *git-read-timeout-seconds*
                            :output :capture
                            :error-output :capture
                            :result-type :octets
                            :max-output-characters *git-read-output-limit*)
                      (when (or *worktree-test-environment-update*
                                (string= subcommand "diff"))
                        (list :environment-update
                              (append
                               (remove-if
                                (lambda (entry)
                                  (and (string= subcommand "diff")
                                       (string= (car entry) "GIT_LITERAL_PATHSPECS")))
                                *worktree-test-environment-update*)
                               (when (string= subcommand "diff")
                                 (list (cons "GIT_LITERAL_PATHSPECS" nil))))))))
            (vcs-kit:vcs-command-error (condition)
              (error '%git-read-error
                     :directory directory
                     :subcommand subcommand
                     :arguments arguments
                     :stderr (%sanitize-status-error-text
                              (princ-to-string condition)))))))
    (let* ((success-p (process-kit:process-success-p result))
           (output-limit
             (when (process-kit:process-result-stdout-truncated-p result)
               *git-read-output-limit*)))
      (when (or (not success-p) output-limit)
        (error '%git-read-error
               :directory directory
               :subcommand subcommand
               :arguments arguments
               :exit-code (unless success-p
                            (process-kit:process-result-exit-code result))
               :output-limit output-limit
               :stderr (%process-result-stderr-text result))))
    (sb-ext:octets-to-string
     (process-kit:process-result-stdout result)
     :external-format '(:utf-8 :replacement #\?))))

(defun %git-status-snapshot (directory)
  "DIRECTORY's status as a VCS-KIT:VCS-STATUS-SNAPSHOT with VCS-STATUS-ENTRY
entries -- the same conversion VCS-KIT:VCS-STATUS-STRUCTURED performs
(VCS-KIT::%VCS-STATUS-SNAPSHOT / VCS-KIT::%VCS-STATUS-ENTRY, both internal to
cl-vcs-kit), applied to VCS-KIT:PARSE-STATUS's reading of `git status
--porcelain=v2 --branch -z --untracked-files=normal` -- the exact argument
list VCS-STATUS-STRUCTURED builds for its own (untracked-files :normal)
default -- run through %RUN-GIT-READ instead of a checked vcs-kit repository
handle."
  (let* ((parsed
           (vcs-kit:parse-status
            (%run-git-read directory "status" "--porcelain=v2" "--branch" "-z"
                           "--untracked-files=normal")))
         (snapshot (vcs-kit::%vcs-status-snapshot parsed)))
    (setf (vcs-kit:vcs-status-snapshot-entries snapshot)
          (mapcar #'vcs-kit::%vcs-status-entry (vcs-kit:status-snapshot-entries parsed)))
    snapshot))

(defun %git-numstat-entries (directory &optional paths)
  "Return numstat entries for PATHS, falling back to full diff for unsafe or oversized pathspecs."
  (vcs-kit:parse-numstat
   (if paths
       (let* ((pathspecs
                (mapcar
                 (lambda (path)
                   (concatenate (quote string) ":(top,literal)" path))
                 paths))
              (pathspec-argv-bytes
                (loop for pathspec in pathspecs
                      sum
                      (1+
                       (length
                        (sb-ext:string-to-octets
                         pathspec
                         :external-format :utf-8)))))
              (fallback-reason
                (cond
                  ((some (lambda (path) (find #\? path)) paths)
                   :replacement-marker-in-decoded-path)
                  ((> pathspec-argv-bytes +numstat-pathspec-argv-byte-limit+)
                   :pathspec-argv-too-large))))
         (when fallback-reason
           (log-kit:emit-log
            *vcs-diagnostic-logger*
            log-kit:+level-warn+
            (format nil
                    "using unfiltered diff for numstat because ~A"
                    (case fallback-reason
                      (:replacement-marker-in-decoded-path
                       "a decoded path may contain the UTF-8 replacement marker")
                      (:pathspec-argv-too-large
                       "the pathspec argv exceeds its byte limit")))
            (list :reason fallback-reason
                  :path-count (length paths)
                  :pathspec-argv-bytes pathspec-argv-bytes
                  :pathspec-argv-byte-limit +numstat-pathspec-argv-byte-limit+)))
         (if fallback-reason
             (%run-git-read directory "diff" "--numstat" "-z")
             (apply (function %run-git-read) directory "diff" "--numstat" "-z" "--"
                    pathspecs)))
       (%run-git-read directory "diff" "--numstat" "-z"))))

(defun %changed-file-code (entry)
  "The 2-char git-status---short-style code for ENTRY (D1). :ORDINARY,
:RENAME-OR-COPY and :UNMERGED entries already carry real index/worktree
status characters from the porcelain XY field; :UNTRACKED and :IGNORED
entries do not (the git-layer parser leaves them at the VCS-STATUS-ENTRY
default of two spaces -- see vcs-kit's parse-status.lisp), so those two
kinds are mapped explicitly to the \"??\"/\"!!\" codes `git status --short`
itself would show."
  (case (vcs-kit:vcs-status-entry-kind entry)
    (:untracked "??")
    (:ignored "!!")
    (t
     (format nil
             "~A~A"
             (vcs-kit:vcs-status-entry-index-status entry)
             (vcs-kit:vcs-status-entry-worktree-status entry)))))

(defun %changed-file-path (entry)
  "ENTRY's path part for the (CODE . PATH) cons (F5/F6): control characters
stripped (%STRIP-CONTROL-CHARACTERS -- a path from git status is as
untrusted as a diff line or commit subject), and for a :RENAME-OR-COPY
entry, the source and destination joined as \"old -> new\" (a plain ASCII
arrow, never a Unicode glyph) so the rename's source path is not silently
dropped the way a bare VCS-STATUS-ENTRY-PATH would drop it. Every other
kind uses PATH alone, as before."
  (let ((path (%strip-control-characters (vcs-kit:vcs-status-entry-path entry)))
        (original
         (and (eq (vcs-kit:vcs-status-entry-kind entry) :rename-or-copy)
              (vcs-kit:vcs-status-entry-original-path entry))))
    (if original
        (format nil "~A -> ~A" (%strip-control-characters original) path)
        path)))

(defun %worktree-status-changed-files (entries)
  "ENTRIES (a VCS-STATUS-SNAPSHOT's VCS-STATUS-ENTRY list) as plain
(CODE . PATH) conses -- the infrastructure-to-domain boundary D1 requires:
presentation and the domain model never see a cl-vcs-kit struct."
  (mapcar
   (lambda (entry)
     (cons (%changed-file-code entry) (%changed-file-path entry)))
   entries))

(defun %changed-file-column-set-p (status)
  "T when STATUS -- a VCS-STATUS-ENTRY's INDEX-STATUS or WORKTREE-STATUS
single-character field -- names a real change rather than an empty column.
Porcelain v2 spells an unset column as a dot, which is what git actually
emits and what the parser hands over character by character; a space is
`git status --short`'s spelling of the same thing and is excluded too, as
is \"?\" (untracked/ignored entries are their own record shape, never a
real XY pair) to mirror --short's definition of a set column (magit
alignment, Unit MODEL). Treating the dot as set put every unstaged change
in the staged section as well, and left \"Unstaged changes\" populated
after `git add -A`."
  (not (or (string= status ".") (string= status " ") (string= status "?"))))
(defun %numstat-eligible-entry-p (entry)
  "Whether ENTRY contributes to worktree numstat."
  (case (vcs-kit:vcs-status-entry-kind entry)
    ((:untracked :ignored) nil)
    (:unmerged t)
    ((:ordinary :rename-or-copy)
     (%changed-file-column-set-p
      (vcs-kit:vcs-status-entry-worktree-status entry)))
    (otherwise t)))

(defun %worktree-status-untracked-files (entries)
  "ENTRIES of KIND :UNTRACKED as (\"??\" . PATH) conses (magit alignment,
Unit MODEL) -- a partition of the same ENTRIES %WORKTREE-STATUS-CHANGED-
FILES already covers, not a second fetch."
  (let (result)
    (dolist (entry entries (nreverse result))
      (when (eq (vcs-kit:vcs-status-entry-kind entry) :untracked)
        (push (cons "??" (%changed-file-path entry)) result)))))

(defun %worktree-status-unmerged-files (entries)
  "Conflict ENTRIES (%STATUS-ENTRY-CONFLICT-P) as (CODE . PATH) conses,
CODE the same real XY pair %CHANGED-FILE-CODE already builds for them
(magit alignment, Unit MODEL)."
  (let (result)
    (dolist (entry entries (nreverse result))
      (when (%status-entry-conflict-p entry)
        (push (cons (%changed-file-code entry) (%changed-file-path entry))
              result)))))

(defmacro %collect-status-files (entries status-accessor)
  (let ((entries-var (gensym "ENTRIES-"))
        (result-var (gensym "RESULT-"))
        (entry-var (gensym "ENTRY-"))
        (kind-var (gensym "KIND-"))
        (status-var (gensym "STATUS-")))
    `(let ((,entries-var ,entries))
       (let (,result-var)
         (dolist (,entry-var ,entries-var (nreverse ,result-var))
           (let ((,kind-var (vcs-kit:vcs-status-entry-kind ,entry-var)))
             (unless 
                 (or (eq ,kind-var :untracked)
                     (eq ,kind-var :ignored)
                     (%status-entry-conflict-p ,entry-var))
               (let ((,status-var (,status-accessor ,entry-var)))
                 (when (%changed-file-column-set-p ,status-var)
                   (push (cons ,status-var (%changed-file-path ,entry-var))
                         ,result-var))))))))))

(defun %worktree-status-staged-files (entries)
  "Non-conflict, non-untracked/ignored ENTRIES whose INDEX-STATUS (the X
column, index side) is set, as (CODE . PATH) conses with CODE that single
character -- magit's staged section (Unit MODEL). A rename-or-copy entry
with both X and Y set also appears in %WORKTREE-STATUS-UNSTAGED-FILES:
that duplication is magit's own display behaviour, not a bug."
  (%collect-status-files entries vcs-kit:vcs-status-entry-index-status))

(defun %worktree-status-unstaged-files (entries)
  "As %WORKTREE-STATUS-STAGED-FILES, but for WORKTREE-STATUS (the Y
column, worktree side) -- magit's unstaged section (Unit MODEL)."
  (%collect-status-files entries vcs-kit:vcs-status-entry-worktree-status))

(defstruct (%numstat-result
             (:constructor %make-numstat-result
                 (&key state additions deletions error-message)))
  state
  additions
  deletions
  error-message)

(defun %status-failure-message (condition)
  (if (typep condition '%git-read-error)
      (%git-read-error-message condition)
      (%sanitize-status-error-text (princ-to-string condition))))

(defun %worktree-status-diff-line-counts
    (directory &optional (entries nil entries-supplied-p))
  "Return a typed numstat reading for eligible paths in DIRECTORY."
  (handler-case
      (let* ((paths
               (when entries-supplied-p
                 (loop for entry in entries
                       for kind = (vcs-kit:vcs-status-entry-kind entry)
                       when (%numstat-eligible-entry-p entry)
                       append
                       (cons (vcs-kit:vcs-status-entry-path entry)
                             (when (eq kind :rename-or-copy)
                               (let ((original
                                       (vcs-kit:vcs-status-entry-original-path entry)))
                                 (and original (list original))))))))
             (numstat-entries
               (if entries-supplied-p
                   (and paths (%git-numstat-entries directory paths))
                   (%git-numstat-entries directory))))
        (if (and entries-supplied-p (null paths))
            (%make-numstat-result
             :state :ready :additions 0 :deletions 0)
            (let ((additions 0)
                  (deletions 0))
              (dolist (entry numstat-entries)
                (incf additions (or (vcs-kit:numstat-entry-additions entry) 0))
                (incf deletions (or (vcs-kit:numstat-entry-deletions entry) 0)))
              (%make-numstat-result
               :state :ready :additions additions :deletions deletions))))
    (error (condition)
      (handler-case
          (log-kit:emit-log
           *vcs-diagnostic-logger*
           log-kit:+level-warn+
           (format nil "Git numstat failed in ~A" directory)
           (list :directory directory
                 :condition (princ-to-string condition)))
        (error () nil))
      (%make-numstat-result
       :state :failed
       :additions nil
       :deletions nil
       :error-message (%status-failure-message condition)))))

(declaim (ftype function %read-stashes-at))

(defun %read-worktree-status-at (path fallback-head repository-path
                                  &key (stashes nil stashes-supplied-p))
  "Read status, numstat, and the shared stash result for PATH."
  (multiple-value-bind (directory missing-p)
      (%worktree-status-directory path repository-path)
    (if missing-p
        (%make-worktree-status-update
         :path path :missing-p t :head fallback-head :ahead 0 :behind 0
         :numstat-state :ready :additions 0 :deletions 0)
        (handler-case
            (let* ((snapshot (%git-status-snapshot directory))
                   (entries (vcs-kit:vcs-status-snapshot-entries snapshot))
                   (branch-head
                     (vcs-kit:vcs-status-snapshot-branch-head snapshot))
                   (stash-reading
                     (if stashes-supplied-p stashes
                         (%read-stashes-at directory)))
                   (numstat
                     (if (some (function %numstat-eligible-entry-p) entries)
                         (%worktree-status-diff-line-counts directory entries)
                         (%make-numstat-result
                          :state :ready :additions 0 :deletions 0))))
              (%make-worktree-status-update
               :path path :status-state :ready :snapshot snapshot
               :head (or branch-head fallback-head)
               :dirty-p (not (null entries))
               :conflict-p
               (not (null (some (function %status-entry-conflict-p) entries)))
               :ahead (or (vcs-kit:vcs-status-snapshot-ahead snapshot) 0)
               ;; cl-vcs-kit currently copies the signed behind field into its
               ;; backend-neutral snapshot; nerimux stores the count.
               :behind (abs (or (vcs-kit:vcs-status-snapshot-behind snapshot) 0))
               :numstat-state (%numstat-result-state numstat)
               :numstat-error-message (%numstat-result-error-message numstat)
               :additions (%numstat-result-additions numstat)
               :deletions (%numstat-result-deletions numstat)
               :changed-files (%worktree-status-changed-files entries)
               :stashes stash-reading))
          (%git-read-error (condition)
            (handler-case
                (log-kit:emit-log
                 *vcs-diagnostic-logger*
                 log-kit:+level-warn+
                 (format nil "Git status could not be read in ~A" directory)
                 (list :directory directory
                       :condition (princ-to-string condition)))
              (error () nil))
            (%make-worktree-status-update
             :path path
             :status-state :read-error
             :status-error-message (%git-read-error-message condition))))))
)

(defun %read-worktree-status (worktree &key (stashes nil stashes-supplied-p))
  "As %READ-WORKTREE-STATUS-AT, resolving WORKTREE's own path/head/repository
first; STASHES forwards unchanged, so a caller with no shared reading to
offer (a single-worktree refresh) can omit it and get the old per-worktree
read."
  (let ((repository (nerimux/workspace-model:worktree-repository worktree)))
    (if stashes-supplied-p
        (%read-worktree-status-at
         (nerimux/workspace-model:worktree-path worktree)
         (nerimux/workspace-model:worktree-head worktree)
         (and repository
              (nerimux/workspace-model:repository-local-path repository))
         :stashes stashes)
        (%read-worktree-status-at
         (nerimux/workspace-model:worktree-path worktree)
         (nerimux/workspace-model:worktree-head worktree)
         (and repository
              (nerimux/workspace-model:repository-local-path repository))))))

(defun %apply-worktree-stash-reading (worktree update)
  "Apply the stash result captured beside UPDATE's status snapshot."
  (let ((reading (%worktree-status-update-stashes update)))
    (when reading
      (if (typep reading '%stash-reading)
          (setf (nerimux/workspace-model:worktree-stashes worktree)
                (%stash-reading-entries reading)
                (nerimux/workspace-model:worktree-stashes-state worktree)
                (%stash-reading-state reading)
                (nerimux/workspace-model:worktree-stashes-error-message worktree)
                (%stash-reading-error-message reading))
          (setf (nerimux/workspace-model:worktree-stashes worktree) (cdr reading)
                (nerimux/workspace-model:worktree-stashes-state worktree) (car reading)
                (nerimux/workspace-model:worktree-stashes-error-message worktree)
                nil)))))

(defun %apply-worktree-status (repository update)
  (let* ((worktree
           (nerimux/workspace-model:repository-worktree-by-path
            repository (%worktree-status-update-path update)))
         (snapshot (%worktree-status-update-snapshot update))
         (entries (and snapshot (vcs-kit:vcs-status-snapshot-entries snapshot))))
    (unless worktree
      (error "Status update refers to an unknown worktree: ~A"
             (%worktree-status-update-path update)))
    (if (eq :read-error (%worktree-status-update-status-state update))
        (progn
          (setf (nerimux/workspace-model:worktree-missing-p worktree) nil)
          (nerimux/workspace-model:worktree-transition-status
           worktree :read-error
           :error-message (%worktree-status-update-status-error-message update)))
        (progn
          (setf (nerimux/workspace-model:worktree-missing-p worktree)
                (%worktree-status-update-missing-p update))
          (nerimux/workspace-model:worktree-transition-status
           worktree :ready :snapshot snapshot :snapshot-supplied-p t)
          (setf (nerimux/workspace-model:worktree-head worktree)
                (%worktree-status-update-head update)
                (nerimux/workspace-model:worktree-dirty-p worktree)
                (%worktree-status-update-dirty-p update)
                (nerimux/workspace-model:worktree-conflict-p worktree)
                (%worktree-status-update-conflict-p update)
                (nerimux/workspace-model:worktree-ahead worktree)
                (%worktree-status-update-ahead update)
                (nerimux/workspace-model:worktree-behind worktree)
                (%worktree-status-update-behind update)
                (nerimux/workspace-model:worktree-changed-files worktree)
                (%worktree-status-update-changed-files update)
                (nerimux/workspace-model:worktree-untracked-files worktree)
                (%worktree-status-untracked-files entries)
                (nerimux/workspace-model:worktree-unmerged-files worktree)
                (%worktree-status-unmerged-files entries)
                (nerimux/workspace-model:worktree-staged-files worktree)
                (%worktree-status-staged-files entries)
                (nerimux/workspace-model:worktree-unstaged-files worktree)
                (%worktree-status-unstaged-files entries)
                (nerimux/workspace-model:worktree-numstat-state worktree)
                (%worktree-status-update-numstat-state update)
                (nerimux/workspace-model:worktree-numstat-error-message worktree)
                (%worktree-status-update-numstat-error-message update))
          (when (eq :ready (%worktree-status-update-numstat-state update))
            (setf (nerimux/workspace-model:worktree-additions worktree)
                  (%worktree-status-update-additions update)
                  (nerimux/workspace-model:worktree-deletions worktree)
                  (%worktree-status-update-deletions update)))
          (%apply-worktree-stash-reading worktree update)))
    worktree))

(defun worktree-upstream (worktree)
  "WORKTREE's tracked upstream ref (\"origin/main\"), or NIL when its branch
tracks nothing -- read from the status snapshot the last status pass stored
on WORKTREE, so no git process runs and no vcs-kit struct leaves this
package (D1)."
  (let ((snapshot (and worktree
                       (nerimux/workspace-model:worktree-status worktree))))
    (and snapshot (vcs-kit:vcs-status-snapshot-branch-upstream snapshot))))
