(in-package #:nerimux/vcs)

(defvar *git-read-output-limit* (* 1024 1024)
  "Maximum stdout byte count captured by %RUN-GIT-READ. Output over this limit
signals %GIT-READ-ERROR.")

(defvar *git-read-timeout-seconds* 30
  "Deadline for one %RUN-GIT-READ call. A process that exceeds it is terminated
and reported as %GIT-READ-ERROR.")

(define-condition %git-read-error (error)
  ((directory :initarg :directory :reader %git-read-error-directory)
   (subcommand :initarg :subcommand :reader %git-read-error-subcommand)
   (arguments :initarg :arguments :reader %git-read-error-arguments)
   (exit-code :initarg :exit-code :initform nil :reader %git-read-error-exit-code)
   (output-limit :initarg :output-limit :initform nil
                 :reader %git-read-error-output-limit))
  (:report
   (lambda (condition stream)
     (format stream "git ~A~{ ~A~} in ~A failed~@[ (exit ~D)~]~@[ (stdout exceeded ~D-byte limit)~]"
             (%git-read-error-subcommand condition)
             (%git-read-error-arguments condition)
             (%git-read-error-directory condition)
             (%git-read-error-exit-code condition)
             (%git-read-error-output-limit condition))))
  (:documentation
   "Signaled by %RUN-GIT-READ for a non-zero git exit, stdout overflow, timeout,
or launch failure."))

(defun %run-git-read (directory subcommand &rest arguments)
  "Run git through VCS-KIT with a deadline and bounded octet capture."
  (let ((result
          (handler-case
              (vcs-kit:run-vcs nil subcommand arguments
                               :executable "git"
                               :directory directory
                               :input ""
                               :timeout *git-read-timeout-seconds*
                               :output :capture
                               :error-output :capture
                               :result-type :octets
                               :max-output-characters *git-read-output-limit*)
            (vcs-kit:vcs-command-error ()
              (error '%git-read-error
                     :directory directory
                     :subcommand subcommand
                     :arguments arguments)))))
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
               :output-limit output-limit)))
    (sb-ext:octets-to-string
     (process-kit:process-result-stdout result)
     :external-format (quote (:utf-8 :replacement #\?)))))

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
  "Return DIRECTORY git diff numstat entries, restricted to literal PATHS when supplied."
  (vcs-kit:parse-numstat
   (if paths
       (apply (function %run-git-read) directory "diff" "--numstat" "-z" "--"
              (mapcar
               (lambda (path) (concatenate (quote string) ":(literal)" path))
               paths))
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

(defun %worktree-status-diff-line-counts (directory &optional (entries nil entries-supplied-p))
  "Return additions and deletions for eligible paths in DIRECTORY."
  (handler-case
      (let* ((paths
              (when entries-supplied-p
                (loop for entry in entries
                      for kind = (vcs-kit:vcs-status-entry-kind entry)
                      when (case kind
                             ((:untracked :ignored) nil)
                             (:unmerged t)
                             ((:ordinary :rename-or-copy)
                              (%changed-file-column-set-p
                               (vcs-kit:vcs-status-entry-worktree-status entry)))
                             (otherwise t))
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
            (values 0 0)
          (let ((additions 0)
                (deletions 0))
            (dolist (entry numstat-entries (values additions deletions))
              (incf additions (or (vcs-kit:numstat-entry-additions entry) 0))
              (incf deletions (or (vcs-kit:numstat-entry-deletions entry) 0))))))
    (error (condition) (declare (ignore condition)) (values 0 0))))

(declaim (ftype function %read-stashes-at))

(defun %read-worktree-status-at (path fallback-head repository-path
                                  &key (stashes nil stashes-supplied-p))
  "STASHES, when supplied, is a (STATE . ENTRIES) reading in the shape
%READ-STASHES-AT returns, used in place of reading one here -- refs/stash is
shared by every worktree of one repository, so a caller refreshing several at
once reads it exactly once and passes the same reading down (see
%REPOSITORY-STATUS-SHARED-STASHES and %RAW-WORKTREES-SHARED-STASHES)."
  (multiple-value-bind (directory missing-p)
      (%worktree-status-directory path repository-path)
    (if missing-p
        (%make-worktree-status-update
         :path path :missing-p t :head fallback-head :ahead 0 :behind 0
         :additions 0 :deletions 0)
        (let* ((snapshot
                 (%git-status-snapshot directory))
               (entries (vcs-kit:vcs-status-snapshot-entries snapshot))
               (branch-head
                 (vcs-kit:vcs-status-snapshot-branch-head snapshot))
               (stash-reading
                 (if stashes-supplied-p stashes (%read-stashes-at directory))))
          (multiple-value-bind (additions deletions)
              (if (some
                   (lambda (entry)
                     (case (vcs-kit:vcs-status-entry-kind entry)
                       ((:untracked :ignored) nil)
                       (:unmerged t)
                       ((:ordinary :rename-or-copy)
                        (%changed-file-column-set-p
                         (vcs-kit:vcs-status-entry-worktree-status entry)))
                       (otherwise t)))
                   entries)
                  (%worktree-status-diff-line-counts directory entries)
                  (values 0 0))
            (%make-worktree-status-update
             :path path :snapshot snapshot
             :head (or branch-head fallback-head)
             :dirty-p (not (null entries))
             :conflict-p (not (null (some #'%status-entry-conflict-p entries)))
             :ahead (or (vcs-kit:vcs-status-snapshot-ahead snapshot) 0)
             ;; cl-vcs-kit currently copies Git's signed -<behind> field into
             ;; its backend-neutral snapshot; nerimux stores the count.
             :behind (abs (or (vcs-kit:vcs-status-snapshot-behind snapshot) 0))
             :additions additions
             :deletions deletions
             :changed-files (%worktree-status-changed-files entries)
             :stashes stash-reading))))))

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
  "Move UPDATE's stash reading, when its pass took one, onto WORKTREE.

The reading travels inside the update so it is applied only with the capture
it was read beside: keyed by path outside the struct, a capture the generation
check discarded stayed behind and was applied next to a different snapshot."
  (let ((reading (%worktree-status-update-stashes update)))
    (when reading
      (setf (nerimux/workspace-model:worktree-stashes worktree) (cdr reading)
            (nerimux/workspace-model:worktree-stashes-state worktree)
            (car reading)))))

(defun %apply-worktree-status (repository update)
  (let* ((worktree
           (nerimux/workspace-model:repository-worktree-by-path
            repository (%worktree-status-update-path update)))
         (snapshot (%worktree-status-update-snapshot update))
         (entries (and snapshot (vcs-kit:vcs-status-snapshot-entries snapshot))))
    (unless worktree
      (error "Status update refers to an unknown worktree: ~A"
             (%worktree-status-update-path update)))
    (setf (nerimux/workspace-model:worktree-missing-p worktree)
          (%worktree-status-update-missing-p update)
          (nerimux/workspace-model:worktree-status worktree)
          (%worktree-status-update-snapshot update)
          (nerimux/workspace-model:worktree-head worktree)
          (%worktree-status-update-head update)
          (nerimux/workspace-model:worktree-dirty-p worktree)
          (%worktree-status-update-dirty-p update)
          (nerimux/workspace-model:worktree-conflict-p worktree)
          (%worktree-status-update-conflict-p update)
          (nerimux/workspace-model:worktree-ahead worktree)
          (%worktree-status-update-ahead update)
          (nerimux/workspace-model:worktree-behind worktree)
          (%worktree-status-update-behind update)
          (nerimux/workspace-model:worktree-additions worktree)
          (%worktree-status-update-additions update)
          (nerimux/workspace-model:worktree-deletions worktree)
          (%worktree-status-update-deletions update)
          (nerimux/workspace-model:worktree-changed-files worktree)
          (%worktree-status-update-changed-files update)
          (nerimux/workspace-model:worktree-untracked-files worktree)
          (%worktree-status-untracked-files entries)
          (nerimux/workspace-model:worktree-unmerged-files worktree)
          (%worktree-status-unmerged-files entries)
          (nerimux/workspace-model:worktree-staged-files worktree)
          (%worktree-status-staged-files entries)
          (nerimux/workspace-model:worktree-unstaged-files worktree)
          (%worktree-status-unstaged-files entries))
    (%apply-worktree-stash-reading worktree update)
    worktree))

(defun worktree-upstream (worktree)
  "WORKTREE's tracked upstream ref (\"origin/main\"), or NIL when its branch
tracks nothing -- read from the status snapshot the last status pass stored
on WORKTREE, so no git process runs and no vcs-kit struct leaves this
package (D1)."
  (let ((snapshot (and worktree
                       (nerimux/workspace-model:worktree-status worktree))))
    (and snapshot (vcs-kit:vcs-status-snapshot-branch-upstream snapshot))))
