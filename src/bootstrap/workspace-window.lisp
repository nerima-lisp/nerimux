(in-package #:nerimux)

;;;; Window creation for the workspace UI.
;;;;
;;;; One entry point: open a window for a worktree. The parameters a tmux
;;;; `new-window` carried -- at-index, after-current, before-current, detach --
;;;; went with the command table that was the only way to supply them.

;;; +status-line-rows+ (the status line is one row at the bottom, always --
;;; requirements 1.4) is defined in server.lisp, which loads before this file
;;; in the bootstrap-server ASDF module; reused here rather than redefined.

;;; Windows and panes are numbered from 1 (requirements 1.4).
(defconstant +first-window-index+ 1
  "Index the first window in a session takes.")

(defun %workspace-new-window (session &key name start-dir (start-reader-p t))
  "Create a window in SESSION and return it.
   NAME defaults to the shell basename.  START-DIR is the new pane's working
   directory.  START-READER-P is NIL when the caller starts the reader thread
   itself once the pane is fully built."
  (let* ((rows     (- *term-rows* +status-line-rows+))
         (cols     *term-cols*)
         (win-name (or name (nerimux/model::%shell-basename)))
         (win      (session-new-window session win-name rows cols
                                       +first-window-index+ start-dir)))
    (when start-reader-p
      (start-reader-thread (window-active-pane win)))
    win))
