(in-package #:nerimux/vcs)

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
The porcelain-v2 parser defaults an unset column to a single space; \"?\"
never actually reaches this field for any KIND parse-status.lisp produces
(untracked/ignored entries are their own record shape, never a real XY
pair), but is excluded anyway to mirror `git status --short`'s own
definition of a set column (magit alignment, Unit MODEL)."
  (not (or (string= status " ") (string= status "?"))))

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

(defun %read-worktree-status-at (path fallback-head repository-path)
  (let* ((directory (if (plusp (length path)) path repository-path))
         (missing-p (and (stringp directory)
                         (plusp (length directory))
                         (null (probe-file directory)))))
    (if missing-p
        (%make-worktree-status-update
         :path path :missing-p t :head fallback-head :ahead 0 :behind 0)
        (let* ((snapshot
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
           :behind (or (vcs-kit:vcs-status-snapshot-behind snapshot) 0)
           :changed-files (%worktree-status-changed-files entries))))))

(defun %read-worktree-status (worktree)
  (let ((repository (nerimux/workspace-model:worktree-repository worktree)))
    (%read-worktree-status-at (nerimux/workspace-model:worktree-path worktree)
                              (nerimux/workspace-model:worktree-head worktree)
                              (and repository
                                   (nerimux/workspace-model:repository-local-path
                                    repository)))))

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
    worktree))
