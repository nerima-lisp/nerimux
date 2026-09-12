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

(defparameter +message-display-seconds+ 5
  "How long the strip keeps a notification when no keystroke follows it.")

(defvar *client-message-display*
  (make-hash-table :test #'eq :weakness :key)
  "CONN -> (LOG-HEAD RAISED-AT VIEW) for the notification CONN's strip shows.
   Keyed by the message log's head cons rather than by its text, because
   %CLIENT-NOTIFY conses a fresh cell per call and the same sentence raised
   twice is two messages. RAISED-AT is NIL once the notification has been
   retired, so returning to the view that raised it does not bring it back.")

(defun %client-message-expired-p (conn)
  (let ((raised-at (second (gethash conn *client-message-display*))))
    (and raised-at
         (>= (- (get-universal-time) raised-at) +message-display-seconds+))))

(defun %client-retire-expired-notification (conn)
  "Retire CONN's strip notification once it has outlived
   +MESSAGE-DISPLAY-SECONDS+. %CLIENT-STRIP-NOTIFICATION does this too, but
   only the three view renderers reach it: a client sitting in :help, the
   process log or a read view would keep an expired notification forever, and
   %BROADCAST-FRAME reads %CLIENT-MESSAGE-EXPIRED-P as dirty on every poll."
  (let ((state (gethash conn *client-message-display*)))
    (when (and state (%client-message-expired-p conn))
      (setf (second state) nil))))

(defun %client-note-keystroke (conn)
  "Retire whatever CONN's strip is showing: a notification describes the action
   that raised it, and the next key the user presses starts a different one."
  (let ((state (gethash conn *client-message-display*)))
    (when (second state)
      (setf (second state) nil)
      (%mark-dirty))))

(defun %client-strip-notification (conn)
  "CONN's newest notification while it is still current: shown from the frame
   that raised it until the next keystroke, a view change, or
   +MESSAGE-DISPLAY-SECONDS+, whichever comes first."
  (let ((log (client-conn-message-log conn)))
    (when log
      (let ((state (gethash conn *client-message-display*)))
        (cond
          ((not (eq log (first state)))
           (setf (gethash conn *client-message-display*)
                 (list log (get-universal-time) (client-conn-view conn)))
           (first log))
          ((null (second state)) nil)
          ((or (not (eq (client-conn-view conn) (third state)))
               (%client-message-expired-p conn))
           (setf (second state) nil)
           nil)
          (t (first log)))))))

(defun %client-render-messages (session conn)
  (remove nil
          (list (%latest-agent-waiting-message session)
                (%client-strip-notification conn))))

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

(defvar *client-revealed-selection*
  (make-hash-table :test #'eq :weakness :key)
  "CONN -> the tree object its repolist frame last brought into view, so the
   reveal below runs once per selection instead of once per frame and never
   re-expands a row the user has since folded.")

(defun %reveal-tree-object-ancestors (object)
  "Expand what hides OBJECT's row: a worktree named by an attach selector sits
   inside a repository row that is collapsed until something expands it, and
   both a worktree's row and a repository's own row are also hidden when their
   organization is folded -- folding an organization must not leave a
   selection permanently invisible once something below it asks to be shown."
  (typecase object
    (nerimux/workspace-model:worktree
     (let ((repository (nerimux/workspace-model:worktree-repository object)))
       (when repository
         (setf (gethash (list :repository
                              (nerimux/workspace-model:repository-id repository))
                        (%workspace-expanded-nodes))
               t)
         (let ((organization (nerimux/workspace-model:repository-organization repository)))
           (when organization
             (remhash (list :organization
                            (nerimux/workspace-model:organization-id organization))
                      (%workspace-collapsed-nodes)))))))
    (nerimux/workspace-model:repository
     (let ((organization (nerimux/workspace-model:repository-organization object)))
       (when organization
         (remhash (list :organization
                        (nerimux/workspace-model:organization-id organization))
                  (%workspace-collapsed-nodes)))))))

(defun %client-reveal-tree-selection (conn)
  "Put CONN's selected row on screen, expanding its ancestors when it is
   folded away: a selection the user cannot see is one the next key discards."
  (let ((object (%client-tree-object conn)))
    (when (and object
               (not (eq object (gethash conn *client-revealed-selection*))))
      (setf (gethash conn *client-revealed-selection*) object)
      (let* ((filter (client-conn-tree-filter conn))
             (index (position object
                              (%workspace-tree-objects
                               (nerimux/vcs:workspace-organizations) filter)
                              :test #'equal)))
        (unless index
          (%reveal-tree-object-ancestors object)
          (setf index (position object
                                (%workspace-tree-objects
                                 (nerimux/vcs:workspace-organizations) filter)
                                :test #'equal)))
        (when index
          (%adjust-client-tree-scroll
           conn
           index
           (max 1 (nerimux/renderer:workspace-tree-view-rows
                   (client-conn-rows conn)))))))))

(defun %client-selection-fallback-object (object objects)
  "The row a selection falls back to when OBJECT's own row is no longer drawn:
   its nearest ancestor still in OBJECTS -- a worktree falls back to its
   repository, a repository to its organization -- else the first drawn row."
  (flet ((drawn (candidate)
           (and candidate
                (position candidate objects :test #'equal)
                candidate)))
    (or (typecase object
          (nerimux/workspace-model:worktree
           (drawn (nerimux/workspace-model:worktree-repository object)))
          (nerimux/workspace-model:repository
           (drawn (nerimux/workspace-model:repository-organization object)))
          (nerimux/pane:pane
           (drawn (nerimux/pane:pane-worktree object)))
          (cons
           (find-if (lambda (candidate)
                      (and (typep candidate 'nerimux/workspace-model:worktree)
                           (equal (second object)
                                  (nerimux/workspace-model:worktree-id
                                   candidate))))
                    objects))
          (t nil))
        (first objects))))

(defun %client-reveal-or-move-selection (conn &optional objects)
  "Keep CONN's selected row on screen: expand what hides it, and when it is
   hidden by something no expansion can undo -- a visibility-level preset or
   a tree filter that drops it from the tree entirely -- move the selection
   to the nearest visible ancestor or row. A frame with no visible cursor
   still answers the footer's row hints and the detail panel from a row the
   user cannot see.
   OBJECTS, when supplied, is the tree object list a caller already derived
   from a flatten it needed anyway (%RENDER-WORKSPACE-FRAME, from the same
   entries it passes to the renderer) -- passing it here means this call
   does not flatten the tree a second time. NIL (the default, and what every
   dispatch call site still passes) recomputes it, matching the old
   behaviour exactly: an empty OBJECTS list skips the reveal-or-move check
   either way, so a caller with nothing to hand over loses nothing by
   omitting it."
  (%client-reveal-tree-selection conn)
  (let* ((objects (or objects
                      (%workspace-tree-objects
                       (nerimux/vcs:workspace-organizations)
                       (client-conn-tree-filter conn))))
         (object (%client-tree-object conn)))
    (when (and objects
               object
               (not (position object objects :test #'equal)))
      (%set-client-selected-tree-object
       conn
       (%client-selection-fallback-object object objects))
      (%client-reveal-tree-selection conn))))

(defvar *client-visibility-level-applied*
  (make-hash-table :test #'eq :weakness :key)
  "CONN -> the visibility level the workspace fold tables were last shaped to.
   The level presets rewrite *WORKSPACE-COLLAPSED-NODE-IDS* /
   *WORKSPACE-EXPANDED-NODE-IDS* rather than filtering the drawn rows,
   because %WORKSPACE-TREE-OBJECTS navigates by those same tables: a
   render-only filter would leave `n' landing on rows the frame does not
   draw. Reshaping only when the level CHANGES is what leaves a Tab the user
   pressed on one row afterwards standing.")

(defun %request-worktree-commits (worktree)
  "Start WORKTREE's recent-commit fetch when nothing has ever asked for it,
   the same :PENDING guard %CLIENT-TOGGLE-SELECTED-TREE-ROW uses. Marking the
   worktree node expanded is not enough on its own: while COMMITS-STATE is
   NIL the entry builder emits no commit row at all, so level 4 would open a
   worktree onto a group that stays invisible until a manual Tab."
  (when (member (nerimux/workspace-model:worktree-commits-state worktree)
                '(nil :failed))
    (setf (nerimux/workspace-model:worktree-commits-state worktree) :pending)
    (%client-start-worktree-commits-refresh worktree)))

(defun %apply-visibility-level (level organizations)
  "Shape the workspace fold tables to LEVEL (contract SS2): 1 section
   headings only, 2 sections open with repository rows folded, 3 repository
   rows open, 4 each worktree's own files, panes and commits open too."
  (let ((collapsed (%workspace-collapsed-nodes))
        (expanded (%workspace-expanded-nodes)))
    (clrhash collapsed)
    (clrhash expanded)
    (when (= level 1)
      (dolist (section '(:attention :active :repositories))
        (setf (gethash (list :section section) collapsed) t)))
    (when (>= level 3)
      (dolist (organization organizations)
        (dolist (repository
                 (nerimux/workspace-model:organization-repositories
                  organization))
          (setf (gethash (list :repository
                               (nerimux/workspace-model:repository-id
                                repository))
                         expanded)
                t)
          (when (>= level 4)
            (dolist (worktree
                     (nerimux/workspace-model:repository-worktrees repository))
              (setf (gethash (list :worktree
                                   (nerimux/workspace-model:worktree-id
                                    worktree))
                             expanded)
                    t)
              (%request-worktree-commits worktree))))))))

(defun %client-apply-visibility-level (conn organizations)
  "Reshape the fold tables when CONN's visibility level has moved since the
   last frame. The first frame only records the level: the tables already
   hold whatever attach and the default level built, and clearing that here
   would fold away the row the attach selector just revealed."
  (let ((level (client-conn-visibility-level conn))
        (applied (gethash conn *client-visibility-level-applied*)))
    (when (and applied (/= level applied))
      (%apply-visibility-level level organizations))
    (setf (gethash conn *client-visibility-level-applied*) level)))

(defun %client-picker-status (conn)
  "Whether CONN's picker query compiled as a regex, as
   FILTER-GLOBAL-PICKER-ITEMS reports it in its second value. It reports it
   for an empty item list too, so asking here costs a regex compile rather
   than a second pass over the catalog."
  (when (client-conn-picker-regex-p conn)
    (nth-value 1
               (nerimux/picker:filter-global-picker-items
                '()
                (client-conn-picker-query conn)
                :regex-p t))))

(defun %client-picker-open-p (conn)
  (eq (client-conn-modal conn) :picker))

(defun %render-workspace-frame (session conn)
  "The repolist frame (FR-002). Split out of %RENDER-CLIENT-FRAME so the modal
   precedence above it stays readable as a list of one-line branches.
   Flattens the tree once, after %CLIENT-APPLY-VISIBILITY-LEVEL has settled
   the fold tables for this frame: TREE-ENTRIES feeds both
   %CLIENT-REVEAL-OR-MOVE-SELECTION (as the OBJECTS it would otherwise
   re-derive with a flatten of its own) and RENDER-WORKSPACE-OVERVIEW-TO-
   TUI-STRING (as :TREE-ENTRIES, so it does not flatten a second time)."
  (%client-apply-visibility-level conn (nerimux/vcs:workspace-organizations))
  (let ((tree-entries
          (nerimux/renderer:workspace-flat-tree-entries
           (nerimux/vcs:workspace-organizations)
           *workspace-collapsed-node-ids*
           :job-labels (%workspace-job-labels)
           :refreshing-ids *workspace-refreshing-ids*
           :stale-ids *workspace-stale-ids*
           :filter (client-conn-tree-filter conn)
           :expanded-node-ids *workspace-expanded-node-ids*
           :file-diffs *workspace-file-diffs*)))
    (%client-reveal-or-move-selection conn (mapcar #'third tree-entries))
    (render-workspace-overview-to-tui-string (nerimux/vcs:workspace-organizations)
                                             (client-conn-rows conn)
                                             (client-conn-cols conn)
                                             :tree-entries tree-entries
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
                                             ;; Matched verbatim by
                                             ;; +WORKSPACE-GHQ-MISSING-ROOT+
                                             ;; (renderer-workspace-frame.lisp),
                                             ;; which drops the `ghq get' remedy
                                             ;; when ghq is what is missing.
                                             (or (nerimux/vcs:ghq-root-directory)
                                                 "ghq not found on PATH")
                                             :picker-items
                                             (when (%client-picker-open-p conn)
                                               (%client-picker-visible-items conn))
                                             :picker-query
                                             (client-conn-picker-query conn)
                                             :picker-index
                                             (client-conn-picker-index conn)
                                             :picker-regex-p
                                             (client-conn-picker-regex-p conn)
                                             :picker-status
                                             (%client-picker-status conn)
                                             :scanning-p
                                             (and
                                              *workspace-catalog-refresh-started-p*
                                              (not *workspace-catalog-loaded-p*))
                                             :command-buffer
                                             (client-conn-command-buffer conn))))

(defun %render-status-frame (session conn)
  "The magit status frame (FR-003). Split out because two arms of
   %RENDER-CLIENT-FRAME reach it -- the ordinary :status view and a :transient
   opened while in that view, which the status frame hosts in place by growing
   its own key panel rather than by replacing the screen.
   MODE/COMMAND-BUFFER/TREE-FILTER go down the same way %RENDER-WORKSPACE-
   FRAME passes them: `:` and `/` are bound in this view too
   (%HANDLE-CLIENT-UI-KEY-PAYLOAD), so without them the user types into a
   modal that draws nothing at all."
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
                                          conn)
                                         :picker-open-p
                                         (%client-picker-open-p conn)
                                         :picker-items
                                         (when (%client-picker-open-p conn)
                                           (%client-picker-visible-items conn))
                                         :picker-query
                                         (client-conn-picker-query conn)
                                         :picker-index
                                         (client-conn-picker-index conn)
                                         :picker-regex-p
                                         (client-conn-picker-regex-p conn)
                                         :picker-status
                                         (%client-picker-status conn)
                                         :mode
                                         (client-conn-modal conn)
                                         :command-buffer
                                         (client-conn-command-buffer conn)
                                         :tree-filter
                                         (client-conn-tree-filter conn)))

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
                                :messages
                                (%client-render-messages session conn)
                                :command-buffer
                                (client-conn-command-buffer conn)
                                :picker-items
                                (when (%client-picker-open-p conn)
                                  (%client-picker-visible-items conn))
                                :picker-query
                                (client-conn-picker-query conn)
                                :picker-index
                                (client-conn-picker-index conn)
                                :picker-regex-p
                                (client-conn-picker-regex-p conn)
                                :picker-status
                                (%client-picker-status conn)))

(defun %render-client-view-frame (session conn)
  "CONN's ordinary view, with no modal over it. The bordered-panel modals
   below pass this down as their BASE-FRAME so the tree or buffer they were
   opened from stays on screen above the panel."
  (case (client-conn-view conn)
    (:repolist (%render-workspace-frame session conn))
    (:status (%render-status-frame session conn))
    (t (%render-pane-frame session conn))))

(defun %render-client-frame (session conn)
  "Render SESSION for CONN's geometry and cache the encoded frame on CONN.

   Precedence mirrors %HANDLE-MULTI-KEY-MESSAGE's exactly, and deliberately so:
   whoever owns the keyboard must be what the user is looking at. When the two
   orders disagree, a key answers a question that is not on screen.

   A :PICKER modal has no arm of its own: each view's own frame draws the
   picker when it is open, so the default arm below already puts it over
   whichever view the user opened it from rather than over the pane view."
  (%client-retire-expired-notification conn)
  (multiple-value-bind (text snapshot)
           (case (client-conn-modal conn)
             (:confirm
              (render-confirm-view-to-tui-string
               (client-conn-confirm-view conn)
               (client-conn-rows conn)
               (client-conn-cols conn)
               (%render-client-view-frame session conn)))
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
             ((:read-view :read-search)
              (render-read-view-to-tui-string
               (client-conn-read-view conn)
               (client-conn-rows conn)
               (client-conn-cols conn)
               (when (eq (client-conn-modal conn) :read-search)
                 (client-conn-read-search-widget conn))))
             (:text-prompt
              (render-text-prompt-to-tui-string
               (client-conn-text-prompt-title conn)
               (client-conn-text-prompt-widget conn)
               (client-conn-rows conn)
               (client-conn-cols conn)
               (%render-client-view-frame session conn)
               (%client-render-messages session conn)))
             (:transient
              (if (eq (client-conn-view conn) :status)
                  (%render-status-frame session conn)
                  (render-transient-panel-to-tui-string
                   (client-conn-transient-view conn)
                   (client-conn-rows conn)
                   (client-conn-cols conn)
                   (%render-client-view-frame session conn))))
             (t (%render-client-view-frame session conn)))
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
    (let ((dirty (or *dirty* (some #'%client-message-expired-p *clients*)))
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
