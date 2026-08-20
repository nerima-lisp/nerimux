(in-package #:nerimux)

;;;; Window creation for the workspace UI.
;;;;
;;;; This is the workspace-sized replacement for the tmux command table's
;;;; %cmd-new-window, which was the only symbol in application/dispatch/ that
;;;; surviving code still called after the key and command fallthroughs were
;;;; removed.  Keeping the whole command table alive for one function was not
;;;; worth it, and the tmux version carried five parameters the workspace never
;;;; passed: at-index, after-current, before-current and detach exist for
;;;; `new-window -a/-b/-t/-d`, which no longer has a way to be invoked.
;;;;
;;;; What is left is the path the workspace actually uses: open a window for a
;;;; worktree, or re-create one while restoring a runtime snapshot.

(defun %workspace-new-window (session &key name start-dir (start-reader-p t))
  "Create a window in SESSION and return it.
   NAME defaults to the shell basename.  START-DIR is the new pane's working
   directory.  START-READER-P is NIL during snapshot restore, where the caller
   starts the reader thread itself once the pane is fully rebuilt."
  (let* ((rows     (- *term-rows* (nerimux/options:status-line-count)))
         (cols     *term-cols*)
         (win-name (or name (nerimux/model::%shell-basename)))
         (base     (or (nerimux/options:get-option "base-index") 0))
         (win      (session-new-window session win-name rows cols base start-dir)))
    (when start-reader-p
      (start-reader-thread (window-active-pane win)))
    (nerimux/hooks:run-hooks nerimux/hooks:+hook-after-new-window+ win)
    win))
