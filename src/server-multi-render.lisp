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

(defun %session-panes-for-notifications (session)
  (mapcan (lambda (window) (copy-list (window-panes window)))
          (session-windows session)))

(defun %drain-session-notifications (session)
  "Drain each pane once and return raw notification sequences in arrival order."
  (mapcan #'pane-drain-notifications
          (%session-panes-for-notifications session)))

(defun %session-worktrees (session)
  (remove-duplicates
   (remove nil
           (mapcar #'pane-worktree
                   (%session-panes-for-notifications session)))
   :test #'eq))

(defun %agent-waiting-message (worktree)
  (format nil "~A: ~A"
          (nerimux/renderer:worktree-notification-label worktree)
          (or (worktree-waiting-message worktree) "notification")))

(defun %latest-agent-waiting-message (session)
  (let ((worktree
          (first
           (sort (copy-list
                  (remove-if-not #'worktree-waiting-p
                                 (%session-worktrees session)))
                 #'>
                 :key (lambda (candidate)
                        (or (worktree-waiting-time candidate) 0))))))
    (when worktree
      (%agent-waiting-message worktree))))

(defun %client-render-messages (session conn)
  (let ((waiting (%latest-agent-waiting-message session)))
    (if waiting
        (cons waiting (client-conn-message-log conn))
        (client-conn-message-log conn))))

(defun %osc99-notification-bytes (title body)
  (cl-codec-kit:string-to-octets
   (format nil
           "~C]99;i=nerimux:d=0:p=title;~A~C\\~C]99;i=nerimux:d=1:p=body;~A~C\\"
           #\Escape title #\Escape #\Escape body #\Escape)
   :encoding :utf-8))

(defun %send-host-notification (stream title body)
  (send-frame stream
              (msg-notification (%osc99-notification-bytes title body))))

(defun %client-focuses-pane-p (pane)
  (some (lambda (conn)
          (eq pane (client-conn-focus conn)))
        *clients*))

(defun %notify-agent-waiting-hosts (session)
  (dolist (worktree (%session-worktrees session))
    (when (and (worktree-waiting-p worktree)
               (not (worktree-waiting-host-notified-p worktree)))
      (let ((pane (worktree-agent-pane worktree)))
        (unless (%client-focuses-pane-p pane)
          (dolist (conn (copy-list *clients*))
            (nerimux/ports:notify-host
             (client-conn-stream conn)
             "nerimux"
             (%agent-waiting-message worktree)))))
      (worktree-mark-waiting-host-notified worktree))))

(defun %render-workspace-frame (session conn)
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
                                           (%client-render-messages
                                            session
                                            conn)
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
                                           :job-labels (%workspace-job-labels)
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

(defun %render-status-frame (session conn)
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
                                         (%client-render-messages
                                          session
                                          conn)
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
  (multiple-value-bind (text snapshot)
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
                  (%render-status-frame session conn)
                  (render-transient-full-screen-to-tui-string
                   (client-conn-transient-view conn)
                   (client-conn-rows conn)
                   (client-conn-cols conn))))
             (t
              (case (client-conn-view conn)
                (:repolist (%render-workspace-frame session conn))
                (:status (%render-status-frame session conn))
                (t (%render-pane-frame session conn)))))
    (let ((frame (msg-frame text)))
      (setf (client-conn-frame conn) frame
            (client-conn-row-frame-candidate conn)
            (when (and snapshot (null (client-conn-modal conn))
                       (member (client-conn-view conn) '(:repolist :status)))
              (list frame (%client-row-frame-key conn) snapshot)))
      frame)))

(defun %client-row-frame-key (conn)
  (list (client-conn-rows conn) (client-conn-cols conn)
        (client-conn-view conn) (client-conn-modal conn)))

(defun %send-client-frame (conn frame)
  "Cache and send FRAME to one client connection."
  (setf (client-conn-frame conn) frame)
  (let* ((candidate (client-conn-row-frame-candidate conn))
         (eligible (and (eq frame (first candidate))
                        (equal (%client-row-frame-key conn) (second candidate))))
         (previous (client-conn-sent-row-frame conn))
         (delta (when (and eligible
                           (equal (second previous) (second candidate)))
                  (nerimux/renderer:ansi-row-delta
                   (third previous) (third candidate))))
         (completed nil))
    (unwind-protect
         (progn
           (unless (and delta (zerop (length delta)))
             (send-frame (client-conn-stream conn)
                         (if delta (msg-frame delta) frame)))
           (setf (client-conn-sent-row-frame conn) (when eligible candidate)
                 completed t))
      ;; A partial write leaves the terminal state unknown, even if flush failed.
      (unless completed (setf (client-conn-sent-row-frame conn) nil)))))

(defun %broadcast-frame (session)
  "Render dirty content and broadcast one shared notification drain."
  (when *clients*
    (let ((dirty *dirty*)
          (notifications (%drain-session-notifications session)))
      (%notify-agent-waiting-hosts session)
      (when (or dirty notifications)
        (setf *dirty* nil)
        (dolist (conn (copy-list *clients*))
          (with-loop-safe-error (nil :on-error (%drop-client conn))
            (dolist (raw-sequence notifications)
              (send-frame (client-conn-stream conn)
                          (msg-notification raw-sequence)))
            (when dirty
              (%send-client-frame conn
                                  (%render-client-frame session conn)))))))))

(defun %client-fds ()
  "Return the socket fds of every attached client."
  (mapcar #'client-conn-fd *clients*))
