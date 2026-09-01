(in-package #:nerimux/vcs)

;;;; Git working-tree and history mutation -- magit's write side: add,
;;;; commit, push, pull, branch, merge, rebase, stash, reset, restore, tag,
;;;; clean, switch. Every one of these is a %DEFINE-CHECKED-OPERATION-
;;;; generated vcs-kit function and therefore type-checks its handle as
;;;; VCS-KIT:REPOSITORY, exactly like GIT-REV-PARSE-VALUE -- see
;;;; %REPOSITORY-CHECKED-HANDLE (vcs-worktree-operations.lisp) and the
;;;; vcs-kit-two-repository-types-trap it documents: the backend-neutral
;;;; VCS-REPOSITORY %MAKE-VCS-REPOSITORY builds type-errors here before any
;;;; git runs, and a broad HANDLER-CASE around that call would turn it into
;;;; a permanent, silent NIL rather than a visible failure.
(defvar *write-operation-output-max-characters*
  100000
  "Cap on a write operation's captured stdout/stderr (F3, CWE-400), passed
as VCS-KIT's :MAX-OUTPUT-CHARACTERS execution option -- same role as
*WORKTREE-LOG-MAX-OUTPUT-CHARACTERS* in vcs-inspect.lisp, needed here
because `git push`/`git pull` echo the remote's own, equally untrusted,
progress and error text.")

(defvar *write-operation-output-max-length*
  4000
  "Maximum characters of a write operation's OUTPUT-STRING kept once it
crosses the D1 boundary (F3b). Ordinary commit/push/merge output is a
handful of lines; this only guards against a pathological hook or a merge
across hundreds of conflicting paths handing the renderer an unbounded
string.")

(defparameter *write-operations*
  (list (cons :add #'vcs-kit:git-add)
        (cons :commit #'vcs-kit:git-commit)
        (cons :push #'vcs-kit:git-push)
        (cons :pull #'vcs-kit:git-pull)
        (cons :branch #'vcs-kit:git-branch)
        (cons :merge #'vcs-kit:git-merge)
        (cons :rebase #'vcs-kit:git-rebase)
        (cons :stash #'vcs-kit:git-stash)
        (cons :reset #'vcs-kit:git-reset)
        (cons :restore #'vcs-kit:git-restore)
        (cons :tag #'vcs-kit:git-tag)
        (cons :clean #'vcs-kit:git-clean)
        (cons :switch #'vcs-kit:git-switch))
  "OPERATION keyword -> checked vcs-kit function, GIT-WRITE-OPERATION's only
dispatch table. An alist of function objects rather than a symbol built
with INTERN/FIND-SYMBOL from OPERATION, so an unrecognized keyword fails
with a plain ASSOC miss instead of ever interning or looking up a name
derived from caller input (see nerimux-unbounded-keyword-interning).")

(defun %write-operation-function (operation)
  (or (cdr (assoc operation *write-operations*))
      (error "Unknown git write operation: ~S" operation)))

(defun %truncate-write-output (text)
  (if (and (stringp text) (> (length text) *write-operation-output-max-length*))
      (subseq text 0 *write-operation-output-max-length*)
      text))

(defun %write-operation-result-text (result)
  "RESULT's stdout and stderr, concatenated -- git puts push/fetch progress
and most error text on stderr, not stdout, so stdout alone would report a
successful push as having produced no output. Sanitized and capped for the
D1 boundary (F5/F3b). RESULT is NIL for a condition that never reached a
process (e.g. a launch failure), in which case this returns \"\"."
  (let* ((stdout (or (and result (vcs-kit:process-result-stdout result)) ""))
         (stderr (or (and result (vcs-kit:process-result-stderr result)) ""))
         (combined
          (cond
            ((and (plusp (length stdout)) (plusp (length stderr)))
             (concatenate 'string stdout (string #\Newline) stderr))
            ((plusp (length stderr)) stderr)
            (t stdout))))
    (%truncate-write-output (%strip-control-characters combined))))

(defun git-write-operation (repository operation &rest arguments)
  "Run a git write OPERATION (:add :commit :push :pull :branch :merge
:rebase :stash :reset :restore :tag :clean :switch) with ARGUMENTS against
REPOSITORY and return (values SUCCESS-P OUTPUT-STRING).

An ordinary git failure -- a rejected push, a conflicting merge, nothing to
commit -- never signals out of this function: VCS-KIT's checked operations
raise a typed VCS-KIT:VCS-ERROR (GIT-EXIT-ERROR and siblings) for exactly
that case, which is caught here and reported as (values NIL OUTPUT-STRING)
instead, OUTPUT-STRING taken from the failed process when the condition
carries one (a GIT-LAUNCH-ERROR or GIT-IO-ERROR does not). Anything else --
a TYPE-ERROR from a wrong-typed argument, a PROGRAM-ERROR from a malformed
trailing options plist -- is a programmer error, not a git failure, and is
left to propagate."
  (let ((function (%write-operation-function operation))
        (handle (%repository-checked-handle repository)))
    (handler-case (let ((result
                         (apply function
                                handle
                                (append arguments
                                        (list :execution-options
                                              (list :max-output-characters
                                                    *write-operation-output-max-characters*))))))
                    (values t (%write-operation-result-text result)))
      (vcs-kit:vcs-error (condition)
        (values nil
                (%write-operation-result-text
                 (and (typep condition 'vcs-kit:git-error)
                      (vcs-kit:git-error-result condition))))))))

;;; Async wrapper: mirrors FETCH-REPOSITORY-ASYNC's wiring (vcs-fetch.lisp)
;;; exactly, down to its own dedicated in-progress table rather than sharing
;;; *IN-PROGRESS-FETCHES* -- a fetch and a write are independent hazards (a
;;; fetch touches no working-tree state a concurrent write could collide
;;; with) and must be free to dedup separately.
(defvar *write-lock*
  (cl-concurrent-kit:make-lock :name "nerimux-vcs-write"))

(defvar *in-progress-writes*
  (make-hash-table :test #'equal))

(defun %write-begin (key)
  (cl-concurrent-kit:with-lock-held (*write-lock*)
                                    (if (gethash key *in-progress-writes*)
                                        nil
                                        (setf (gethash key *in-progress-writes*) t))))

(defun %write-end (key)
  (cl-concurrent-kit:with-lock-held (*write-lock*)
                                    (remhash key *in-progress-writes*)))

(defun git-write-operation-async (repository operation
                                             arguments
                                             &key
                                             callback-dispatch
                                             on-complete
                                             on-error)
  "Run GIT-WRITE-OPERATION on a worker thread and dispatch one completion
callback with the same (values SUCCESS-P OUTPUT-STRING) it returns
synchronously.

Duplicate suppression (mirroring FETCH-REPOSITORY-ASYNC) keys on
REPOSITORY alone, not REPOSITORY+OPERATION: two concurrent git write
commands against the same working tree already collide on git's own
`.git/index.lock` regardless of which two operations they are, so blocking
per-repository here pre-empts that race rather than only an identical
retry. A write requested while one is already in flight for the same
repository dispatches ON-COMPLETE immediately with (values NIL NIL) without
starting a worker -- indistinguishable from an ordinary failure that
produced no output, the same ambiguity FETCH-REPOSITORY-ASYNC's own
duplicate path accepts by dispatching ON-COMPLETE with a bare NIL.

ON-ERROR fires only for a framework-level failure (the worker thread itself
erroring outside GIT-WRITE-OPERATION's own handler-case, e.g. it could not
be launched); an ordinary git failure settles ON-COMPLETE with SUCCESS-P
NIL, exactly as it does synchronously."
  (let ((key
         (list :repository (nerimux/workspace-model:repository-id repository))))
    (if (%write-begin key)
        (cl-concurrent-kit:make-thread
         (lambda ()
           (handler-case (multiple-value-bind (success-p output) 
                             (apply #'git-write-operation
                                    repository
                                    operation
                                    arguments)
                           (%write-end key)
                           (%dispatch-callback callback-dispatch
                                               on-complete
                                               success-p
                                               output))
             (error (condition)
               (%write-end key)
               (%dispatch-callback callback-dispatch on-error condition))))
         :name
         "nerimux-vcs-write")
        (progn
          (%dispatch-callback callback-dispatch on-complete nil nil)
          nil))))

;;; Stash listing: a structured (keyword-argument) vcs-kit observation, not a
;;; %DEFINE-CHECKED-OPERATION write -- takes the backend-neutral
;;; VCS-REPOSITORY %MAKE-VCS-REPOSITORY builds, the same handle
;;; %READ-WORKTREE-COMMITS and %READ-WORKTREE-FILE-DIFF use (vcs-inspect.lisp),
;;; not %REPOSITORY-CHECKED-HANDLE above.
(defun list-worktree-stashes (worktree)
  "WORKTREE's stashes as (REFERENCE . MESSAGE) conses, most recent first --
VCS-KIT:VCS-LIST-STASHES already returns them in that order (git stash
list's own traversal). Never a VCS-KIT:VCS-STASH-ENTRY struct crosses this
boundary (D1)."
  (let ((backend-repository
         (%make-vcs-repository (nerimux/workspace-model:worktree-path worktree))))
    (mapcar
     (lambda (entry)
       (cons (vcs-kit:vcs-stash-entry-reference entry)
             (%sanitize-retained-text (vcs-kit:vcs-stash-entry-message entry))))
     (vcs-kit:vcs-list-stashes backend-repository))))
