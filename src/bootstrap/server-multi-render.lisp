(in-package #:nerimux)

;;;; Client geometry and frame delivery for the multi-client server.

(defun %client-size-reduce (fn)
  "Apply FN across all attached clients' rows and cols, returning both." 
  (values (reduce fn *clients* :key #'client-conn-rows)
          (reduce fn *clients* :key #'client-conn-cols)))

(defun %effective-client-size ()
  "Return the smallest attached client's geometry, or the terminal default." 
  (if (null *clients*)
      (values *term-rows* *term-cols*)
      (%client-size-reduce #'min)))

(defun %apply-effective-size (session)
  "Apply the shared layout geometry selected by the attached clients." 
  (multiple-value-bind (rows cols) (%effective-client-size)
    (setf *term-rows* rows *term-cols* cols)
    (%relayout-active-window session rows cols)
    (%mark-dirty)))

(defun %render-client-frame (session conn)
  "Render SESSION for CONN's geometry and cache the encoded frame on CONN." 
  (let ((frame
          (msg-frame
           (cond
             ((client-conn-confirm-view conn)
              (render-confirm-view-to-tui-string
               (client-conn-confirm-view conn)
               (client-conn-rows conn)
               (client-conn-cols conn)))
             ;; A pending y/n confirmation outranks a passive help screen
             ;; (approved decision): CONFIRM-VIEW is checked first above.
             ((client-conn-help-view-p conn)
              (render-help-view-to-tui-string
               (client-conn-rows conn)
               (client-conn-cols conn)))
             ((and (eq (client-conn-view conn) :overview)
                   (not (eq (client-conn-mode conn) :picker)))
              (render-workspace-overview-to-tui-string
               (nerimux/vcs:workspace-organizations)
               (client-conn-rows conn)
               (client-conn-cols conn)
               :focus-pane (client-conn-focus conn)
               :selected-tree-object (client-conn-selected-tree-object conn)
               :selected-worktree (client-conn-selected-worktree conn)
               :tree-scroll (client-conn-tree-scroll conn)
               :messages (client-conn-message-log conn)
               :mode (client-conn-mode conn)
               :prefix-code (client-conn-workspace-prefix-code conn)
               :collapsed-node-ids *workspace-collapsed-node-ids*
               :expanded-node-ids *workspace-expanded-node-ids*
               :tree-filter (client-conn-tree-filter conn)
               :refreshing-ids *workspace-refreshing-ids*
               :stale-ids *workspace-stale-ids*
               :file-diffs *workspace-file-diffs*
               :scan-progress *workspace-scan-progress*
               :catalog-empty-hint (nerimux/vcs:ghq-root-directory)
               :scanning-p (and *workspace-catalog-refresh-started-p*
                                (not *workspace-catalog-loaded-p*))
               :command-buffer (client-conn-command-buffer conn)))
             (t
              (render-session-to-tui-string
               session
               (client-conn-rows conn)
               (client-conn-cols conn)
               :focus-pane (client-conn-focus conn)
               :viewport (client-conn-viewport conn)
               :mode (client-conn-mode conn)
               :command-buffer (client-conn-command-buffer conn)
               :picker-items
               (when (eq (client-conn-mode conn) :picker)
                 (%client-picker-visible-items conn))
               :picker-query (client-conn-picker-query conn)
               :picker-index (client-conn-picker-index conn)
               :picker-regex-p (client-conn-picker-regex-p conn)))))))
    (setf (client-conn-frame conn) frame)
    frame))

(defun %send-client-frame (conn frame)
  "Cache and send FRAME to one client connection."
  (setf (client-conn-frame conn) frame)
  (send-frame (client-conn-stream conn) frame))

(defun %broadcast-frame (session)
  "Render and send a dirty frame to every attached client."
  (when (and *dirty* *clients*)
    (setf *dirty* nil)
    (dolist (conn (copy-list *clients*))
      (with-loop-safe-error (nil :on-error (%drop-client conn))
        (%send-client-frame conn (%render-client-frame session conn))))))

(defun %client-fds ()
  "Return the socket fds of every attached client."
  (mapcar #'client-conn-fd *clients*))
