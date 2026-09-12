(in-package #:nerimux)


(defun %workspace-prefix-context (session conn)
  "Return (values PANE WINDOW WORKTREE) for CONN's current focus, or all NIL
   when nothing is focused.  The shared starting point for every prefix
   action below."
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (window (and pane (pane-window pane)))
         (worktree (and pane (pane-worktree pane))))
    (values pane window worktree)))

(defun %workspace-prefix-unzoom (window)
  "R5.6: split, focus move, window switch, and pane close all disturb a
   zoomed layout, so each un-zooms WINDOW first when it is zoomed, rather
   than acting on (or silently failing against) the collapsed zoom tree."
  (when (and window (window-zoom-p window))
    (window-zoom-toggle window)))

(defun %workspace-prefix-split (session conn orient)
  "C-q - / C-q | : split the focused pane's window along ORIENT (R5.1/R5.3)."
  (multiple-value-bind (pane window worktree)
      (%workspace-prefix-context session conn)
    (when (%reject-pending-worktree-attachment conn :worktree worktree :pane pane :window window)
      (return-from %workspace-prefix-split nil))
    (cond
      ((or (null pane) (null window))
       (%client-notify conn "no focused pane"))
      ((%worktree-cancel-pending-p worktree)
       (%client-notify conn "worktree cancellation is pending"))
      (t
       (%workspace-prefix-unzoom window)
       (let ((new-pane (window-split session window orient
                                     :start-dir (and worktree
                                                     (worktree-path worktree)))))
         (if new-pane
             (progn
               (when worktree (worktree-add-pane worktree new-pane))
               (when (pane-live-p new-pane)
                 (start-reader-thread new-pane))
               (window-select-pane window new-pane)
               (%set-client-focus conn new-pane session)
               (%remember-worktree-pane worktree new-pane)
               (%mark-dirty))
             (%client-notify conn "pane too small to split")))))
    nil))

(defun %workspace-prefix-resize (session conn direction)
  "Resize the focused pane along DIRECTION by the fixed workspace step.
   DIRECTION selects both the axis and whether the focused pane grows or
   shrinks."
  (multiple-value-bind (pane window worktree)
      (%workspace-prefix-context session conn)
    (when (%reject-pending-worktree-attachment conn :worktree worktree :pane pane :window window)
      (return-from %workspace-prefix-resize nil))
    (cond
      ((or (null pane) (null window))
       (%client-notify conn "no focused pane"))
      ((%worktree-cancel-pending-p worktree)
       (%client-notify conn "worktree cancellation is pending"))
      (t
       (%workspace-prefix-unzoom window)
       (if (window-resize-active window direction +workspace-prefix-resize-delta+)
           (%mark-dirty)
           (%client-notify conn "pane cannot be resized")))))
  nil)

(defun %workspace-refocus-after-window-close (session conn worktree)
  "R5.4 fallback focus once a window closes because its last pane closed:
   another window of the same WORKTREE (most recently active first), else the
   repolist."
  (let* ((candidates (and worktree (worktree-panes worktree)))
         (best-pane
          (and candidates
               (first
                (sort (copy-list candidates)
                      #'>
                      :key
                      (lambda (p)
                        (window-last-active-time (pane-window p))))))))
    (if best-pane
        (let* ((window (pane-window best-pane))
               (active (window-active-pane window)))
          (when (%reject-pending-worktree-attachment conn :pane active :window window)
            (return-from %workspace-refocus-after-window-close nil))
          (session-select-window session window)
          (%set-client-focus conn active session))
        (%set-client-view conn :repolist))))

(defvar *client-pending-close-panes*
  (make-hash-table :test #'eq :weakness :key)
  "The pane each client's first C-q x asked about, keyed by connection.")

(defun %release-closed-pane-selection (pane worktree)
  "Move every client's tree selection off PANE before the close removes it.

   WINDOW-REMOVE-PANE clears PANE-WINDOW (window-tree.lisp), and the repolist
   draws a pane row's key as (window-id (pane-window pane)), so a selection
   still pointing here signals out of the render loop and the client is
   dropped -- what closing an exited pane reached through the tree did
   (NMX-PANES-1). The worktree row is what the close returns the user to."
  (dolist (conn *clients*)
    (when (eq pane (client-conn-selected-tree-object conn))
      (%set-client-selected-tree-object conn worktree))))

(defun %client-clear-pending-close-pane (conn)
  "Forget the pane C-q x asked about: any other key answers no (NMX-P19)."
  (remhash conn *client-pending-close-panes*))

(defun %workspace-prefix-close-pane (session conn)
  "C-q x : close the focused pane (R5.4).  Kills its PTY, drops it from its
   worktree and window, and, when that empties the window, closes the
   window too and refocuses per %workspace-refocus-after-window-close.

   A pane whose process is still running takes two presses (NMX-P19): the
   first only says so, because the single press was closing live shells and
   agents outright with nothing on screen having asked.  A pane whose process
   has already exited has nothing left to lose and closes on the first.

   RETIRE-PANE-PTY rather than CLOSE-PANE-PTY: this is the one path that
   closes a single pane while the server keeps serving, so it is the one path
   whose pane still has a live reader thread that must be told to stop.  The
   shutdown paths (%FORCE-KILL-PANES, RUN-SERVER's unwind) deliberately keep
   using CLOSE-PANE-PTY, because they read PANE-PID back afterwards to
   escalate to SIGKILL."
  (multiple-value-bind (pane window worktree)
      (%workspace-prefix-context session conn)
    (when (or (%reject-pending-worktree-attachment conn :worktree worktree :pane pane :window window)
              (some (lambda (candidate)
                      (%window-delete-pending-p (pane-window candidate)))
                    (and worktree (worktree-panes worktree))))
      (return-from %workspace-prefix-close-pane nil))
    (cond
      ((or (null pane) (null window)) (%client-notify conn "no focused pane"))
      ((and (pane-live-p pane)
            (not (eq pane (gethash conn *client-pending-close-panes*))))
       (setf (gethash conn *client-pending-close-panes*) pane)
       (%client-notify conn "C-q x again to close"))
      (t
        (%client-clear-pending-close-pane conn)
        (%workspace-prefix-unzoom window)
        (retire-pane-pty pane)
        (%release-closed-pane-selection pane worktree)
        (when worktree
          (setf (worktree-panes worktree) (delete pane
                                                  (worktree-panes worktree)))
          (setf (pane-worktree pane) nil))
        (let ((sibling (window-remove-pane window pane)))
          (if sibling
              (progn
                (window-select-pane window sibling)
                (session-select-window session window)
                (%set-client-focus conn sibling session))
              (progn
                (session-remove-window session window)
                (%workspace-refocus-after-window-close session conn worktree))))))
    (%mark-dirty)
    nil))

(defun %workspace-prefix-toggle-zoom (session conn)
  "C-q z : toggle zoom on the focused pane's window."
  (multiple-value-bind (pane window) (%workspace-prefix-context session conn)
    (declare (ignore pane))
    (if window
        (progn
          (window-zoom-toggle window)
          (%mark-dirty))
        (%client-notify conn "no focused pane")))
  nil)

(defun %workspace-prefix-move-focus (session conn direction)
  "C-q h/j/k/l : move focus to the neighbouring pane in DIRECTION,
   un-zooming first per R5.6."
  (multiple-value-bind (pane window) (%workspace-prefix-context session conn)
    (when (%reject-pending-worktree-attachment conn :pane pane :window window)
      (return-from %workspace-prefix-move-focus nil))
    (cond
      ((or (null pane) (null window)) (%client-notify conn "no focused pane"))
      (t
        (%workspace-prefix-unzoom window)
        (let ((neighbor (pane-neighbor window pane direction)))
          (if neighbor
              (progn
                (window-select-pane window neighbor)
                (%set-client-focus conn neighbor session)
                (%remember-worktree-pane (pane-worktree neighbor) neighbor)
                (%mark-dirty))
              (%client-notify conn (format nil "no pane ~A" direction)))))))
  nil)

(defun %workspace-prefix-cycle-window (session conn delta)
  "C-q n / C-q p : cycle DELTA steps through the current worktree's windows
   (wrapping), un-zooming the departing window first per R5.6."
  (multiple-value-bind (pane window worktree)
      (%workspace-prefix-context session conn)
    (declare (ignore pane))
    (cond
      ((or (null window) (null worktree))
       (%client-notify conn "no worktree selected"))
      (t
       (let* ((windows (%worktree-windows worktree))
              (count (length windows))
              (index (position window windows :test #'eq)))
         (if (or (null index) (<= count 1))
             (%client-notify conn "no other window")
             (let* ((next-window (nth (mod (+ index delta) count) windows)))
               (when (%reject-pending-worktree-attachment conn
                                                         :pane (window-active-pane next-window)
                                                         :window next-window)
                 (return-from %workspace-prefix-cycle-window nil))
               (%workspace-prefix-unzoom window)
               (session-select-window session next-window)
               (%set-client-focus conn (window-active-pane next-window) session)
               (%remember-worktree-pane worktree (window-active-pane next-window))
               (%mark-dirty)))))))
  nil)

(defun %workspace-prefix-open-scrollback (session conn)
  "C-q [ (FR-008): enter scrollback on the focused pane -- the new entry
   point for what was copy mode.  %CLIENT-ENTER-COPY-MODE
   (server-multi-dispatch-command-workspace.lisp) already resolves the
   focused pane, puts its screen into copy mode, and reports \"no focused
   pane\" when there is none; this only layers the MODAL transition on top
   of that success rather than duplicating its pane-resolution and
   no-pane-reporting logic here."
  (when (%client-enter-copy-mode session conn)
    (%set-client-modal conn :scrollback))
  nil)

(defun %send-client-parting (conn text)
  "Send TEXT as the line CONN prints once it has left the alternate screen
   (client.lisp).  Detach and quit otherwise end in the same blank host
   terminal, with nothing saying which of the two happened."
  (handler-case (send-frame (client-conn-stream conn) (msg-reply text))
    (peer-io-failure () nil)))

(defun %workspace-prefix-detach (session conn)
  "C-q d: leave the session running and tell CONN what it left behind."
  (%send-client-parting conn
                        (format nil
                                "nerimux: detached (session ~A, ~D pane~:P running)"
                                (session-name session)
                                (length (%session-live-panes session))))
  :drop)

(defun %workspace-prefix-quit-server (session conn)
  "C-q Q (R8.2): ask before stopping the server, showing how many panes are
   still running so the count is in front of the user at the moment they answer
   not discovered afterwards."
  (let* ((live  (%session-live-panes session))
         (count (length live)))
    (%open-confirm-view
     conn
     "Quit server"
     (list (cons "panes" (format nil "~D open" count))
           (cons "effect" (if (plusp count)
                              "every pane is signalled and the server exits"
                              "the server exits")))
     (lambda ()
       (%server-kill-request session t)
       (dolist (client (copy-list *clients*))
         (%send-client-parting client "nerimux: server stopped"))
       :quit))))

(define-key-rules %workspace-prefix-key-action (session conn byte)
  "Resolve BYTE, the key struck right after C-q, against 1.5's table and
   run its action.  Returns the loop disposition (NIL to keep serving,
   :drop for `d`).  A BYTE with no binding here is discarded: the prefix
   already consumed it and nothing else happens (R4.4)."
  (#\- (%workspace-prefix-split session conn :v))
  (#\| (%workspace-prefix-split session conn :h))
  (#\< (%workspace-prefix-resize session conn :left))
  (#\> (%workspace-prefix-resize session conn :right))
  (#\{ (%workspace-prefix-resize session conn :up))
  (#\} (%workspace-prefix-resize session conn :down))
  (#\x (%workspace-prefix-close-pane session conn))
  (#\z (%workspace-prefix-toggle-zoom session conn))
  (#\h (%workspace-prefix-move-focus session conn :left))
  (#\j (%workspace-prefix-move-focus session conn :down))
  (#\k (%workspace-prefix-move-focus session conn :up))
  (#\K (nerimux/commands:stop-worktree-agent
         (client-conn-selected-worktree conn) :on-finish #'%mark-dirty)
        nil)
  (#\l (%workspace-prefix-move-focus session conn :right))
  (#\n (%workspace-prefix-cycle-window session conn 1))
  (#\p (%workspace-prefix-cycle-window session conn -1))
  (#\w (%workspace-prefix-open-overview session conn))
  (#\t (%client-open-selected-worktree-command session conn nil))
  (#\[ (%workspace-prefix-open-scrollback session conn))
  ;; The pane view's status strip advertises this and a focused pane sends
  ;; every other byte to the shell, so without the binding the hint lies (R4).
  (#\? (%client-open-help-view conn) nil)
  (#\d (%workspace-prefix-detach session conn))
  (#\Q (%workspace-prefix-quit-server session conn))
  ((and (integerp byte)
        (= byte (client-conn-workspace-prefix-code conn)))
   (%set-client-modal conn nil)
   nil)
  (t nil))

(defun %workspace-prefix-dispatch (session conn byte)
  "Run the prefix binding for BYTE, first answering any pending C-q x with no:
   every key but a second x leaves the pane the user was asked about open."
  (unless (eql byte (char-code #\x))
    (%client-clear-pending-close-pane conn))
  (%workspace-prefix-key-action session conn byte))


(defun %workspace-prefix-open-overview (session conn)
  "Return directly to the workspace overview, retaining the focused worktree
   selection."
  (multiple-value-bind (pane window worktree)
      (%workspace-prefix-context session conn)
    (declare (ignore window))
    (when (and pane worktree)
      (%set-client-selected-worktree conn worktree))
    (%set-client-view conn :repolist))
  nil)


(defun %workspace-prefix-fetch-repository (conn)
  "Fetch the selected repository, then refresh status.  No longer bound to
   C-q F (magit alignment, contract §2/§3: fetch moves to the `f`
   transient) -- kept as a function because workspace-input-prefix-tests.lisp
   still exercises it directly and the `f` transient is a separate unit's
   call site for the same logic.

A fetch already running for this repository is not started twice; the
caller that finds one in flight is told so and the in-flight fetch's own
completion is what eventually refreshes the picker (nerimux/vcs's
FETCH-REPOSITORY-ASYNC)."
  (let ((repository (%client-selected-repository conn)))
    (cond
      ((not repository)
       (%client-notify conn "fetch requires a selected repository"))
      ((not (nerimux/vcs:vcs-package-available-p))
       (%client-notify conn "VCS adapter unavailable"))
      (t
        (%client-notify conn "fetching...")
        (handler-case (%workspace-fetch-repository-async repository
                                                          :callback-dispatch
                                                          #'%enqueue-main-thread-callback
                                                          :on-complete
                                                          (lambda (result)
                                                            (if result
                                                                (progn
                                                                  (%refresh-client-picker
                                                                   conn)
                                                                  (%client-notify
                                                                   conn
                                                                   "fetch complete"))
                                                                (%client-notify
                                                                 conn
                                                                 "fetch already in progress")))
                                                          :on-error
                                                          (lambda (condition)
                                                            (%client-notify conn
                                                                            (format
                                                                             nil
                                                                             "fetch failed: ~A"
                                                                             condition))))
          (error (condition)
            (%client-notify conn (format nil "fetch failed: ~A" condition)))))))
  nil)


(defun %workspace-prefix-fetch-organization (conn)
  "Fetch every repository in the selected organization concurrently, then
   refresh status.  Duplicate suppression and the completion callback mirror
   %WORKSPACE-PREFIX-FETCH-REPOSITORY above, one level up
   (nerimux/vcs:FETCH-ORGANIZATION-ASYNC)."
  (let ((organization (%client-selected-organization conn)))
    (cond
      ((not organization)
       (%client-notify conn "fetch requires a selected organization"))
      ((not (nerimux/vcs:vcs-package-available-p))
       (%client-notify conn "VCS adapter unavailable"))
      (t
        (%client-notify conn "fetching organization...")
        (handler-case (%workspace-fetch-organization-async organization
                                                            :callback-dispatch
                                                            #'%enqueue-main-thread-callback
                                                            :on-complete
                                                            (lambda 
                                                                (repositories)
                                                              (if repositories
                                                                  (progn
                                                                    (%refresh-client-picker
                                                                     conn)
                                                                    (%client-notify
                                                                     conn
                                                                     "fetch complete"))
                                                                  (%client-notify
                                                                   conn
                                                                   "fetch already in progress")))
                                                            :on-error
                                                            (lambda 
                                                                (repository
                                                                 condition)
                                                              (%client-notify
                                                               conn
                                                               (format nil
                                                                       "fetch failed for ~A: ~A"
                                                                       (nerimux/workspace-model:repository-id
                                                                        repository)
                                                                       condition))))
          (error (condition)
            (%client-notify conn (format nil "fetch failed: ~A" condition)))))))
  nil)
