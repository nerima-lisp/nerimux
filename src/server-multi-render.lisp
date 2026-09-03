(in-package #:nerimux)

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
    (setf *term-rows* rows
          *term-cols* cols)
    (%relayout-active-window session rows cols)
    (%mark-dirty)))

(defun %render-workspace-frame (conn)
  "The repolist frame (FR-002). Split out of %RENDER-CLIENT-FRAME so the modal
   precedence above it stays readable as a list of one-line branches."
  (render-workspace-overview-to-tui-string (nerimux/vcs:workspace-organizations)
                                           (client-conn-rows conn)
                                           (client-conn-cols conn)
                                           :focus-pane
                                           (client-conn-focus conn)
                                           :selected-tree-object
                                           (client-conn-selected-tree-object
                                            conn)
                                           :selected-worktree
                                           (client-conn-selected-worktree conn)
                                           :tree-scroll
                                           (client-conn-tree-scroll conn)
                                           :messages
                                           (client-conn-message-log conn)
                                           :mode
                                           (or (client-conn-modal conn)
                                               (client-conn-view conn))
                                           :prefix-code
                                           (client-conn-workspace-prefix-code
                                            conn)
                                           :collapsed-node-ids
                                           *workspace-collapsed-node-ids*
                                           :expanded-node-ids
                                           *workspace-expanded-node-ids*
                                           :tree-filter
                                           (client-conn-tree-filter conn)
                                           :refreshing-ids
                                           *workspace-refreshing-ids*
                                           :stale-ids
                                           *workspace-stale-ids*
                                           :file-diffs
                                           *workspace-file-diffs*
                                           :scan-progress
                                           *workspace-scan-progress*
                                           :catalog-empty-hint
                                           (nerimux/vcs:ghq-root-directory)
                                           :scanning-p
                                           (and
                                            *workspace-catalog-refresh-started-p*
                                            (not *workspace-catalog-loaded-p*))
                                           :command-buffer
                                           (client-conn-command-buffer conn)))

(defun %render-status-frame (conn)
  "The magit status frame (FR-003). Split out because two arms of
   %RENDER-CLIENT-FRAME reach it -- the ordinary :status view and a :transient
   opened while in that view, which the status frame hosts in place by growing
   its own key panel rather than by replacing the screen."
  (render-workspace-status-to-tui-string (client-conn-selected-worktree conn)
                                         (client-conn-rows conn)
                                         (client-conn-cols conn)
                                         :selected-object
                                         (client-conn-selected-tree-object conn)
                                         :scroll
                                         (client-conn-tree-scroll conn)
                                         :expanded-node-ids
                                         *workspace-expanded-node-ids*
                                         :file-diffs
                                         *workspace-file-diffs*
                                         :visibility-level
                                         (client-conn-visibility-level conn)
                                         :messages
                                         (client-conn-message-log conn)
                                         :transient
                                         (client-conn-transient-view conn)
                                         :prefix-code
                                         (client-conn-workspace-prefix-code
                                          conn)))

(defun %render-pane-frame (session conn)
  "The pane frame. The :MODE it passes down is CONN's MODAL, not a mode of its
   own: with FR-007 there is no longer a modeless-vs-input distinction to show,
   so the status bar's chip reports only what has taken the keyboard AWAY from
   the shell, and reports nothing at all in the ordinary case."
  (render-session-to-tui-string session
                                (client-conn-rows conn)
                                (client-conn-cols conn)
                                :focus-pane
                                (client-conn-focus conn)
                                :viewport
                                (client-conn-viewport conn)
                                :mode
                                (client-conn-modal conn)
                                :command-buffer
                                (client-conn-command-buffer conn)
                                :picker-items
                                (when (eq (client-conn-modal conn) :picker)
                                  (%client-picker-visible-items conn))
                                :picker-query
                                (client-conn-picker-query conn)
                                :picker-index
                                (client-conn-picker-index conn)
                                :picker-regex-p
                                (client-conn-picker-regex-p conn)))

(defun %render-client-frame (session conn)
  "Render SESSION for CONN's geometry and cache the encoded frame on CONN.

   Precedence mirrors %HANDLE-MULTI-KEY-MESSAGE's exactly, and deliberately so:
   whoever owns the keyboard must be what the user is looking at. When the two
   orders disagree, a key answers a question that is not on screen."
  (let ((frame
          (msg-frame
           (case (client-conn-modal conn)
             (:confirm
              (render-confirm-view-to-tui-string
               (client-conn-confirm-view conn)
               (client-conn-rows conn)
               (client-conn-cols conn)))
             (:help
              (render-help-view-to-tui-string
               (client-conn-rows conn)
               (client-conn-cols conn)))
             (:process-log
              (render-process-log-to-tui-string
               (client-conn-process-log conn)
               (client-conn-rows conn)
               (client-conn-cols conn)
               :scroll (client-conn-process-log-scroll conn)))
             (:picker (%render-pane-frame session conn))
             (:transient
              (if (eq (client-conn-view conn) :status)
                  (%render-status-frame conn)
                  (render-transient-full-screen-to-tui-string
                   (client-conn-transient-view conn)
                   (client-conn-rows conn)
                   (client-conn-cols conn))))
             (t
              (case (client-conn-view conn)
                (:repolist (%render-workspace-frame conn))
                (:status (%render-status-frame conn))
                (t (%render-pane-frame session conn))))))))
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
                            (%send-client-frame conn
                                                (%render-client-frame session
                                                                      conn))))))

(defun %client-fds ()
  "Return the socket fds of every attached client."
  (mapcar #'client-conn-fd *clients*))
