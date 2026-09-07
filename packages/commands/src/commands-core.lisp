(in-package #:nerimux/commands)

(defun %close-pane-pty-locked (target)
  (let ((fd (pane-fd target))
        (pid (pane-pid target)))
    (when (plusp fd)
      (let* ((generation (pane-process-generation target))
             (owns-request
               (null (sb-ext:compare-and-swap (pane-stop-requested target)
                                               nil generation))))
        (unwind-protect
             (progn
               (setf (pane-fd target) -1
                     (pane-pid target) -1)
               (multiple-value-bind (code kind)
                   (handler-case (nerimux/ports:close-pty fd pid)
                     (error (condition)
                       (setf (pane-fd target) fd (pane-pid target) pid)
                       (error condition)))
                 (when (member kind '(:exited :signaled))
                   (pane-mark-process-exit target
                                           :status (and (eq kind :exited) code)
                                           :signal (and (eq kind :signaled) code)))
                 (values code kind)))
          (when owns-request
            (sb-ext:compare-and-swap (pane-stop-requested target) generation nil)))))))

(defun close-pane-pty (target)
  "Retire and close TARGET's current process generation exactly once."
  (cl-concurrent-kit:with-lock-held ((pane-process-lock target))
    (%close-pane-pty-locked target)))

(defun retire-pane-pty (target)
  (close-pane-pty target))

(defun stop-worktree-agent (worktree &key on-finish)
  "Request agent termination without blocking the client event loop."
  (let* ((pane (and worktree (nerimux/workspace-model:worktree-agent-pane worktree)))
         (generation (and pane (pane-process-generation pane)))
         (close-pty nerimux/ports:*close-pty*))
    (when (and (worktree-running-agent-p worktree)
               (null (sb-ext:compare-and-swap (pane-stop-requested pane)
                                              nil generation)))
      (handler-case
          (cl-concurrent-kit:make-thread
           (lambda ()
             (unwind-protect
                  (handler-case
                      (cl-concurrent-kit:with-lock-held ((pane-process-lock pane))
                        (when (eq generation (pane-process-generation pane))
                          (let ((nerimux/ports:*close-pty* close-pty))
                            (%close-pane-pty-locked pane))))
                    (error (condition)
                      (sb-ext:compare-and-swap (pane-stop-requested pane) generation nil)
                      (pane-notify pane (format nil "Agent stop failed: ~A" condition))))
               (sb-ext:compare-and-swap (pane-stop-requested pane) generation nil)
               (when on-finish (funcall on-finish))))
           :name (format nil "agent-stop-~D" (pane-id pane)))
        (error (condition)
          (sb-ext:compare-and-swap (pane-stop-requested pane) generation nil)
          (error condition))))))
