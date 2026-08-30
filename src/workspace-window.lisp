(in-package #:nerimux)

;;;; Window creation for the workspace UI.
;;;;
;;;; One entry point: open a window for a worktree. The parameters a
;;;; `new-window` command once carried -- at-index, after-current,
;;;; before-current, detach -- went with the command table that was the
;;;; only way to supply them.

;;; +status-line-rows+ (the status line is one row at the bottom, always --
;;; requirements 1.4) is defined in server.lisp, which loads before this file
;;; in the bootstrap-server ASDF module; reused here rather than redefined.

;;; Windows and panes are numbered from 1 (requirements 1.4).
(defconstant +first-window-index+ 1
  "Index the first window in a session takes.")

(defun %workspace-new-window (session &key name start-dir default-command
                                          (start-reader-p t))
  "Create a window in SESSION and return it.
   NAME defaults to the shell basename.  START-DIR is the new pane's working
   directory.  START-READER-P is NIL when the caller starts the reader thread
   itself once the pane is fully built."
  (let* ((rows     (- *term-rows* +status-line-rows+))
         (cols     *term-cols*)
         (win-name (or name (nerimux/session::%shell-basename)))
         (win      (if default-command
                       (session-new-window session win-name rows cols
                                           +first-window-index+ start-dir
                                           default-command)
                       (session-new-window session win-name rows cols
                                           +first-window-index+ start-dir))))
    (when start-reader-p
      (start-reader-thread (window-active-pane win)))
    win))

;;; ── Worktree ↔ window naming (R5.8) ─────────────────────────────────────────

(defun %worktree-windows (worktree)
  "Distinct windows holding at least one of WORKTREE's panes, ordered by
   window id (the order the tree shows them in, R5.8)."
  (sort (remove-duplicates (mapcar #'pane-window (worktree-panes worktree))
                           :test #'eq)
        #'< :key #'window-id))

(defun %worktree-window-base-name (worktree)
  "The branch name a new window for WORKTREE is built from, falling back to
   the worktree path or id when there is no branch (detached HEAD)."
  (let ((branch (worktree-branch worktree))
        (path (worktree-path worktree)))
    (or (when (and branch (plusp (length branch))) branch)
        (when (and path (plusp (length path))) path)
        (worktree-id worktree)
        "worktree")))

(defun %worktree-window-name (worktree)
  "Branch name + sequence number for WORKTREE's next window (R5.8): the first
   window is bare (\"feat/phase3\"), later ones are numbered (\"feat/phase3
   (2)\") by counting the windows WORKTREE already has open."
  (let* ((base (%worktree-window-base-name worktree))
         (ordinal (1+ (length (%worktree-windows worktree)))))
    (if (= ordinal 1)
        base
        (format nil "~A (~D)" base ordinal))))
