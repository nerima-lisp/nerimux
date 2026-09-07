(in-package #:nerimux)

(defun %client-start-worktree-commits-refresh (worktree)
  "Launch an async recent-commit fetch for WORKTREE, mirroring
   %WORKSPACE-PREFIX-FETCH-REPOSITORY's dispatch wiring (server-multi-
   dispatch-prefix.lisp): CALLBACK-DISPATCH marshals the worker's completion
   back onto the main event loop, where both outcomes just need a redraw --
   REFRESH-WORKTREE-COMMITS-ASYNC has already written WORKTREE's two slots
   by the time either callback runs. The caller sets COMMITS-STATE :PENDING
   before calling this, which is also the dedup guard: this is only ever
   called when COMMITS-STATE was NIL or :FAILED."
  (handler-case
      (nerimux/vcs:refresh-worktree-commits-async
       (nerimux/workspace-model:worktree-repository worktree) worktree
       :callback-dispatch #'%enqueue-main-thread-callback
       :on-complete (lambda (result) (declare (ignore result)) (%mark-dirty))
       :on-error (lambda (condition) (declare (ignore condition)) (%mark-dirty)))
    (error ()
      (setf (nerimux/workspace-model:worktree-commits-state worktree) :failed)
      (%mark-dirty))))

(defun %client-start-worktree-file-diff-refresh (worktree path)
  "Launch an async `git diff -- PATH` fetch for WORKTREE, mirroring
   %CLIENT-START-WORKTREE-COMMITS-REFRESH's wiring exactly: CALLBACK-
   DISPATCH marshals the worker's completion back onto the main event loop,
   where both outcomes write *WORKSPACE-FILE-DIFFS* and just need a redraw.
   Unlike the commits refresh, there is no domain-model slot to write --
   REFRESH-WORKTREE-FILE-DIFF-ASYNC's ON-COMPLETE hands back the raw worker
   result, so this closure is what turns it into the cache entry the
   renderer reads. The caller sets the cache entry to :PENDING before
   calling this, which is also the dedup guard: this is only ever called
   when the entry was absent or :FAILED."
  (let ((key (list (nerimux/workspace-model:worktree-id worktree) path)))
    (flet ((%on-error (condition)
             (declare (ignore condition))
             (%set-workspace-file-diff key (list :failed 0 nil))
             (%mark-dirty)))
      (handler-case
          (nerimux/vcs:refresh-worktree-file-diff-async
           (nerimux/workspace-model:worktree-repository worktree) worktree path
           :callback-dispatch #'%enqueue-main-thread-callback
           :on-complete
           (lambda (worker-result)
             (%set-workspace-file-diff
              key
              (if (eq (first worker-result) :ready)
                  (list :ready (second worker-result) (cddr worker-result))
                  (list :failed 0 nil)))
             (%mark-dirty))
           :on-error #'%on-error)
        (error (condition) (%on-error condition))))))
