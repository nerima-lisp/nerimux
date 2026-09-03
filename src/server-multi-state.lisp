(in-package #:nerimux)

(defvar *clients*
  nil)

(defvar *main-thread-callback-lock*
  (cl-concurrent-kit:make-lock :name "nerimux-main-thread-callbacks"))

(defvar *main-thread-callbacks*
  nil)

(defvar *workspace-catalog-refresh-started-p*
  nil)

(defvar *workspace-collapsed-node-ids*
  (make-hash-table :test #'equal))

(defvar *workspace-expanded-node-ids*
  (make-hash-table :test #'equal)
  "Repository rows under the overview tree's Repositories section default
   COLLAPSED (the section-based redesign's decision) -- the opposite polarity
   from *WORKSPACE-COLLAPSED-NODE-IDS*, whose absence means expanded. A
   (:REPOSITORY ID) key present here means that repository row shows its
   worktrees; absent (including every repository a client has never touched)
   means collapsed.")

(defvar *workspace-refreshing-ids*
  (make-hash-table :test #'equal))

(defvar *workspace-stale-ids*
  (make-hash-table :test #'equal))

(defvar *workspace-worktree-last-pane*
  (make-hash-table :test #'equal))

(defvar *workspace-catalog-loaded-p*
  nil)

(defvar *workspace-scan-progress*
  nil)

(defvar *workspace-file-diffs*
  (make-hash-table :test #'equal)
  "Per-file diff cache for a :FILE row's inline expansion (Wave C), keyed
   (WORKTREE-ID PATH). Value is (STATE TOTAL LINES): STATE one of :PENDING/
   :READY/:FAILED, TOTAL the file's full diff line count, LINES the first
   *WORKTREE-DIFF-LINE-LIMIT* of them (NIL until :READY). Deliberately
   bootstrap-side rather than a domain-model slot (unlike WORKTREE-RECENT-
   COMMITS/-COMMITS-STATE) -- a reviewed decision, since a diff is keyed on
   a (worktree, path) pair rather than owned by one worktree struct.
   Cleared wholesale at catalog-refresh settle (%SET-WORKSPACE-CATALOG-
   REFRESH-STATE); there is no per-worktree status-refresh settle site to
   scope the clear more tightly. Bounded independently of that clear by
   *WORKSPACE-FILE-DIFFS-CACHE-LIMIT* (F4) -- write through
   %SET-WORKSPACE-FILE-DIFF (server-multi.lisp), never a raw SETF of
   GETHASH, so the bound and *WORKSPACE-FILE-DIFFS-ORDER* stay consistent.")

(defvar *workspace-file-diffs-order*
  nil
  "Insertion order of *WORKSPACE-FILE-DIFFS* keys, oldest first (F4,
   CWE-400) -- backs %SET-WORKSPACE-FILE-DIFF's fixed-size eviction. The
   catalog-refresh CLRHASH above has no fixed schedule (a client may go a
   long time between refreshes), so between two refreshes the number of
   distinct (worktree-id path) keys a client can expand is otherwise
   unbounded across the process lifetime.")

(defparameter *workspace-file-diffs-cache-limit*
  64
  "Maximum distinct entries kept in *WORKSPACE-FILE-DIFFS* at once (F4).")

(defun %enqueue-main-thread-callback (thunk)
  "Queue THUNK for execution by the multi-client event loop."
  (check-type thunk function)
  (cl-concurrent-kit:with-lock-held (*main-thread-callback-lock*)
                                    (push thunk *main-thread-callbacks*))
  nil)

(defun %drain-main-thread-callbacks ()
  "Run callbacks queued by worker threads, keeping one failure local."
  (let ((callbacks
         (cl-concurrent-kit:with-lock-held (*main-thread-callback-lock*)
                                           (prog1
                                             (nreverse *main-thread-callbacks*)
                                             (setf *main-thread-callbacks* nil)))))
    (dolist (callback callbacks)
      (handler-case (funcall callback)
        (error (condition)
          (format *error-output*
                  "~&nerimux main-thread callback failed: ~A~%"
                  condition)
          (finish-output *error-output*)))))
  nil)
