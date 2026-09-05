(in-package #:nerimux/vcs)

(defvar *worktree-commit-log-limit*
  5
  "Maximum recent commits REFRESH-WORKTREE-COMMITS-ASYNC fetches per worktree.")

(defvar *worktree-log-max-output-characters*
  100000
  "Cap on `git log`'s captured stdout (F3, CWE-400): passed as VCS-KIT's
   :MAX-OUTPUT-CHARACTERS execution option so a pathological commit history
   cannot make one worker thread hold an unbounded string, independent of
   *WORKTREE-COMMIT-LOG-LIMIT* -- that limit bounds the number of commits
   requested, not the size of any single field within them.")

(defvar *worktree-text-max-characters*
  500
  "Maximum characters kept per retained diff line or commit subject (F3b,
   CWE-400) -- applied at ingestion, before storage, by %TRUNCATE-TEXT.
   Bounds a single pathological line/message independent of
   *WORKTREE-LOG-MAX-OUTPUT-CHARACTERS*/*WORKTREE-DIFF-MAX-OUTPUT-
   CHARACTERS*, which bound the whole captured process output instead.")

(defun %truncate-text (text)
  "TEXT capped at *WORKTREE-TEXT-MAX-CHARACTERS*, verbatim below the cap."
  (if (and (stringp text) (> (length text) *worktree-text-max-characters*))
      (subseq text 0 *worktree-text-max-characters*)
      text))

(defun %sanitize-retained-text (text)
  "TEXT (a diff line or commit subject) as ingestion is allowed to keep:
control characters stripped (NERIMUX/VCS::%STRIP-CONTROL-CHARACTERS, F5,
defined in vcs.lisp which loads before this file) and the result capped
by %TRUNCATE-TEXT (F3b). Applied to every line/subject this module
retains, never to one already discarded by *WORKTREE-DIFF-LINE-LIMIT* or
*WORKTREE-COMMIT-LOG-LIMIT* -- truncating a line about to be thrown away
would be wasted work."
  (%truncate-text (%strip-control-characters text)))

(defun %shorten-commit-id (id)
  (if (and (stringp id) (> (length id) 7))
      (subseq id 0 7)
      (or id "")))

(defun %commit-subject-line (message)
  "MESSAGE's first line only -- the inline expansion shows one line per
commit, not the full commit body -- sanitized and capped (F3b/F5) before
it is retained."
  (%sanitize-retained-text
   (if message
       (let ((newline (position #\Newline message)))
         (if newline
             (subseq message 0 newline)
             message))
       "")))

(defun %worktree-commit-entry (commit)
  "COMMIT (a VCS-KIT:VCS-COMMIT) as a plain (HASH . SUBJECT) cons -- never a
vcs-kit struct, matching D1/D2's infrastructure-to-domain boundary."
  (cons (%shorten-commit-id (vcs-kit:vcs-commit-id commit))
        (%commit-subject-line (vcs-kit:vcs-commit-message commit))))

(defun %read-worktree-commits (worktree)
  "Read up to *WORKTREE-COMMIT-LOG-LIMIT* recent commits for WORKTREE's own
path, as plain (HASH . SUBJECT) conses, newest first (git log's own
traversal order).

IMPORTANT (known trap, see vcs-worktree-operations.lisp:118-122): the
handle passed to VCS-KIT:VCS-LIST-COMMITS must be a VCS-KIT:VCS-REPOSITORY
built by %MAKE-VCS-REPOSITORY -- exactly as %READ-WORKTREE-STATUS-AT builds
one -- never the git-layer MAKE-REPOSITORY object VCS-KIT:GIT-REV-PARSE-
VALUE and friends take; a wrong-type handle there type-errors before any
git runs."
  (let ((backend-repository
         (%make-vcs-repository (nerimux/workspace-model:worktree-path worktree))))
    (mapcar #'%worktree-commit-entry
            (vcs-kit:vcs-list-commits backend-repository
                                      :arguments
                                      (list
                                       (format nil
                                               "--max-count=~D"
                                               *worktree-commit-log-limit*))
                                      :execution-options
                                      (list :max-output-characters
                                            *worktree-log-max-output-characters*)))))

(defvar *worktree-diff-line-limit*
  200
  "Maximum diff lines REFRESH-WORKTREE-FILE-DIFF-ASYNC keeps per file; the
   worker still counts the true total so the caller can report how many
   lines were left out.")

(defvar *worktree-diff-max-output-characters*
  1000000
  "Cap on `git diff`'s captured stdout (F3, CWE-400): passed as VCS-KIT's
   :MAX-OUTPUT-CHARACTERS execution option so a single pathological diff
   (e.g. a generated file with no line breaks) cannot make one worker
   thread hold an unbounded string before *WORKTREE-DIFF-LINE-LIMIT* ever
   gets a chance to cut it down to size.")

(defun %split-diff-lines (stdout)
  "STDOUT (a `git diff` PROCESS-RESULT-STDOUT) split into one string per
line, dropping the single trailing empty segment a newline-terminated
STDOUT otherwise leaves -- diff output ends with a newline whenever it has
any content, and keeping that segment would report one line more than the
diff actually has. The empty string (no diff, e.g. an unchanged path) is
NIL, not a list holding one empty line."
  (let ((text
         (if (and (plusp (length stdout))
                  (char= (char stdout (1- (length stdout))) #\Newline))
             (subseq stdout 0 (1- (length stdout)))
             stdout)))
    (when (plusp (length text))
      (loop with start = 0
            for newline = (position #\Newline text :start start)
            collect (subseq text start (or newline (length text)))
            while newline
            do (setf start (1+ newline))))))

(defun %read-worktree-file-diff (worktree path)
  "(TOTAL-LINE-COUNT . FIRST-N-LINES) for `git diff -- PATH` in WORKTREE,
FIRST-N-LINES capped at *WORKTREE-DIFF-LINE-LIMIT*, each line sanitized and
capped by %SANITIZE-RETAINED-TEXT (F3b/F5) before it is retained.

IMPORTANT (same trap as %READ-WORKTREE-COMMITS above): the handle passed to
VCS-KIT:VCS-DIFF must be a VCS-KIT:VCS-REPOSITORY built by
%MAKE-VCS-REPOSITORY, never the git-layer MAKE-REPOSITORY object.

VCS-KIT:VCS-DIFF is the plain %DEFINE-VCS-OPERATION function
(repository &rest arguments), NOT a keyword-argument entry point -- unlike
VCS-KIT:VCS-LIST-COMMITS above, which really does take :ARGUMENTS/
:EXECUTION-OPTIONS keywords. ARGUMENTS here is a flat argv list, with a
trailing :EXECUTION-OPTIONS keyword/value pair split off by VCS-KIT's own
%SPLIT-VCS-OPERATION-OPTIONS when present (see vcs-commands-operation.lisp).
A previous call here of the shape (VCS-DIFF REPOSITORY :ARGUMENTS (LIST
\"--\" PATH)) forwarded the literal keyword :ARGUMENTS and a list as two
raw argv entries to `git diff` instead of \"--\" and PATH, so every call
failed with a non-zero exit (VCS-DIFF runs /checked); it went unnoticed
because this file's own test doubles for VCS-KIT:VCS-DIFF were shaped to
match that same wrong call convention rather than the real one.

\"--no-ext-diff\" and \"--no-color\" precede \"--\": a user's global git config
can set diff.external or color.diff=always, and this parser expects git's
own unified +/- hunks with no ANSI escapes in them -- a configured external
diff driver instead produces arbitrary side-by-side text with no +/- lines
at all, which %SPLIT-DIFF-LINES then treats as ordinary diff content."
  (let* ((backend-repository
          (%make-vcs-repository
           (nerimux/workspace-model:worktree-path worktree)))
         (result
          (vcs-kit:vcs-diff backend-repository
                            "--no-ext-diff"
                            "--no-color"
                            "--"
                            path
                            :execution-options
                            (list :max-output-characters
                                  *worktree-diff-max-output-characters*)))
         (lines (%split-diff-lines (vcs-kit:process-result-stdout result)))
         (retained
          (subseq lines 0 (min (length lines) *worktree-diff-line-limit*))))
    (cons (length lines) (mapcar #'%sanitize-retained-text retained))))

(defun refresh-worktree-file-diff-async (repository worktree
                                                    path
                                                    &key
                                                    on-complete
                                                    on-error
                                                    callback-dispatch)
  "Fetch WORKTREE's `git diff -- PATH` on a worker thread and settle with
:READY/TOTAL/LINES or :FAILED to ON-COMPLETE, mirroring REFRESH-WORKTREE-
COMMITS-ASYNC's shape exactly -- including catching the worker's own errors
so a nonexistent path or a diff-less file settles :FAILED/:READY rather than
propagating.

Unlike REFRESH-WORKTREE-COMMITS-ASYNC, there is no domain-model slot to
write here (the bootstrap-side *WORKSPACE-FILE-DIFFS* cache owns this data,
a reviewed decision -- infrastructure stays free of that bootstrap state),
so APPLY-RESULT is the identity: ON-COMPLETE receives the raw worker result,
(:READY TOTAL . LINES) or (:FAILED), and the caller's ON-COMPLETE is
responsible for writing it into its own cache.

REPOSITORY is accepted, and ignored, for the same call-shape symmetry
REFRESH-WORKTREE-COMMITS-ASYNC documents. Dedup (never launch while a cache
entry is already :PENDING) is the caller's responsibility, exactly as it is
there."
  (declare (ignore repository))
  (%run-vcs-operation-async "nerimux-vcs-worktree-file-diff"
                            (lambda ()
                              (handler-case (cons :ready
                                                  (%read-worktree-file-diff
                                                   worktree
                                                   path))
                                (error ()
                                  (cons :failed nil))))
                            #'identity
                            on-complete
                            on-error
                            callback-dispatch))

(defun refresh-worktree-commits-async (repository worktree
                                                  &key
                                                  on-complete
                                                  on-error
                                                  callback-dispatch)
  "Fetch WORKTREE's recent commit history on a worker thread and write
WORKTREE-RECENT-COMMITS/WORKTREE-COMMITS-STATE once it settles.

REPOSITORY is accepted for symmetry with every other *-ASYNC entry point in
this file (and so a future caller can key a dedup table on it) but is not
itself needed: the worker only reads WORKTREE's own path. Unlike
%RUN-VCS-OPERATION-ASYNC's other callers, the worker here catches its own
errors (a nonexistent directory, a repository with no commits) and always
returns a (STATE . COMMITS) pair rather than letting the operation signal --
that is what turns a failure into an observable :FAILED COMMITS-STATE on
WORKTREE instead of only a callback nobody watching UI state necessarily
handles. ON-COMPLETE fires with WORKTREE for both a :READY and a :FAILED
settlement; ON-ERROR is reserved for a framework-level failure (e.g.
%RUN-VCS-OPERATION-ASYNC's own thread-launch or APPLY-RESULT step), which
%RUN-VCS-OPERATION-ASYNC's outer HANDLER-CASE already routes there.

Dedup (never launch while WORKTREE-COMMITS-STATE is :PENDING) is the
caller's responsibility -- the bootstrap Tab handler already has to check
COMMITS-STATE before deciding to expand, so re-checking it here would just
be the same guard twice.

SETTLEMENT TARGET (F2): the worker captures WORKTREE by closure, but
LIST-REPOSITORY-WORKTREES always allocates a fresh WORKTREE struct per
path even for an in-place single-repository refresh (see
%APPLY-REPOSITORY-WORKTREES in vcs.lisp), and a full catalog rescan
replaces every struct in the tree. Either can land while this fetch is
still in flight, which would otherwise settle onto an orphaned struct no
longer reachable from *WORKSPACE-ORGANIZATIONS* -- invisible to any
renderer, and stuck at whatever COMMITS-STATE the caller set before
launching (typically :PENDING forever, since the caller's own dedup guard
then refuses to relaunch). %SETTLE-TARGET-WORKTREE resolves the actual
struct to write onto: WORKTREE itself when it is still live, else the
struct in the current catalog sharing its id (the common case this fixes),
else WORKTREE itself again -- which covers both a fetch launched before
any catalog was ever published and a WORKTREE since deleted outright; in
the deleted case the write lands on an unreachable struct and is inert,
not wrong."
  (declare (ignore repository))
  (%run-vcs-operation-async "nerimux-vcs-worktree-commits"
                            (lambda ()
                              (handler-case (cons :ready
                                                  (%read-worktree-commits
                                                   worktree))
                                (error ()
                                  (cons :failed nil))))
                            (lambda (worker-result)
                              (destructuring-bind (state . commits) 
                                  worker-result
                                (let ((target
                                       (%settle-target-worktree worktree)))
                                  (setf (nerimux/workspace-model:worktree-recent-commits
                                         target) (if (eq state :ready)
                                                     commits
                                                     nil)
                                        (nerimux/workspace-model:worktree-commits-state
                                         target) state)
                                  target)))
                            on-complete
                            on-error
                            callback-dispatch))
