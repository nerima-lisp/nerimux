(in-package #:nerimux/commands)

;;; PTY teardown for a closed pane. The kill/rename/select/resize command
;;; set this file once held is gone with the command dispatcher that
;;; would have driven it; only the low-level PTY close survives, called
;;; directly by the runtime reader and the server on pane exit.

(defun close-pane-pty (target)
  (nerimux/ports:close-pty (pane-fd target) (pane-pid target)))
