(in-package #:nerimux)

;;; ── C-q prefix action table (R4.4, 1.5) ─────────────────────────────────────
;;;
;;; Each action below takes SESSION/CONN and returns NIL (keep serving) or
;;; :drop (detach, for `d`).  %workspace-prefix-dispatch is the single place
;;; that maps a struck byte to an action; a byte not listed here is dropped.
(defconstant +max-panes-per-window+
  4
  "Hard cap on panes within one window (§1.4, R5.2).  A split requested while
   a window is already at the cap opens a new window for the same worktree
   instead of subdividing an existing pane further.")

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
  "C-q - / C-q | : split the focused pane's window along ORIENT (R5.1/R5.3).
   At the per-window pane cap, opens a new window in the same worktree
   instead (R5.2) via the existing %open-client-worktree-pane path."
  (multiple-value-bind (pane window worktree)
      (%workspace-prefix-context session conn)
    (cond
      ((or (null pane) (null window))
       (%client-notify conn "no focused pane"))
      (t
       ;; Un-zoom BEFORE reading window-panes: while zoomed, window-panes
       ;; reflects only the single collapsed leaf (window-refresh-panes runs
       ;; against the zoom's 1-leaf tree, not the real one), so the pane-cap
       ;; check below would undercount a window that is actually already at
       ;; +max-panes-per-window+.
       (%workspace-prefix-unzoom window)
       (cond
         ((>= (length (window-panes window)) +max-panes-per-window+)
          (%open-client-worktree-pane session conn worktree))
         (t
          (let ((new-pane (window-split session window orient
                                        :start-dir (and worktree
                                                        (worktree-path worktree)))))
            (if new-pane
                (progn
                  (when worktree (worktree-add-pane worktree new-pane))
                  ;; A split whose PTY failed to spawn comes back with a dead
                  ;; (non-live) pane; starting a reader thread on it would call
                  ;; select-fds on an invalid fd and crash the process.
                  (when (pane-live-p new-pane)
                    (start-reader-thread new-pane))
                  (window-select-pane window new-pane)
                  (%set-client-focus conn new-pane)
                  (%mark-dirty))
                ;; %split-fit-p already refused the split (too small); R5.1
                ;; asks only for a message and otherwise doing nothing.
                (%client-notify conn "pane too small to split")))))))
    nil))

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
          (session-select-window session window)
          (%set-client-focus conn active))
        (%set-client-view conn :repolist))))

(defun %workspace-prefix-close-pane (session conn)
  "C-q x : close the focused pane (R5.4).  Kills its PTY, drops it from its
   worktree and window, and — when that empties the window — closes the
   window too and refocuses per %workspace-refocus-after-window-close.

   RETIRE-PANE-PTY rather than CLOSE-PANE-PTY: this is the one path that
   closes a single pane while the server keeps serving, so it is the one path
   whose pane still has a live reader thread that must be told to stop.  The
   shutdown paths (%FORCE-KILL-PANES, RUN-SERVER's unwind) deliberately keep
   using CLOSE-PANE-PTY, because they read PANE-PID back afterwards to
   escalate to SIGKILL."
  (multiple-value-bind (pane window worktree) 
      (%workspace-prefix-context session conn)
    (cond
      ((or (null pane) (null window)) (%client-notify conn "no focused pane"))
      (t
        (%workspace-prefix-unzoom window)
        (retire-pane-pty pane)
        (when worktree
          (setf (worktree-panes worktree) (delete pane
                                                  (worktree-panes worktree)))
          (setf (pane-worktree pane) nil))
        (let ((sibling (window-remove-pane window pane)))
          (if sibling
              (progn
                (window-select-pane window sibling)
                (session-select-window session window)
                (%set-client-focus conn sibling))
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
    (cond
      ((or (null pane) (null window)) (%client-notify conn "no focused pane"))
      (t
        (%workspace-prefix-unzoom window)
        (let ((neighbor (pane-neighbor window pane direction)))
          (if neighbor
              (progn
                (window-select-pane window neighbor)
                (%set-client-focus conn neighbor)
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
               (%workspace-prefix-unzoom window)
               (session-select-window session next-window)
               (%set-client-focus conn (window-active-pane next-window))
               (%mark-dirty)))))))
  nil)

(defun %workspace-prefix-open-status (session conn)
  "C-q w (FR-009): step out of a pane towards the workspace views, one level
   per press -- :pane to :status, and :status on to :repolist.

   The second step is what makes the repolist reachable at all. FR-006's `q`
   ladder returns :status to the focused pane whenever one is live, which is
   the ordinary case, so `q` alone can never walk OUT to the flat multi-repo
   list; and the magit keymap retired `o`, which was the only key that did
   that before. Without this, a user with any live pane could reach :repolist
   only by closing every pane in the window.

   With no pane focused -- or a focused pane with no worktree, which the
   status view has nothing to render for either -- this goes straight to
   :repolist rather than notifying and leaving the screen as it was, so the
   key is never a dead end."
  (multiple-value-bind (pane window worktree) 
      (%workspace-prefix-context session conn)
    (declare (ignore window))
    (cond
      ((eq (client-conn-view conn) :status) (%set-client-view conn :repolist))
      ((and pane worktree)
        (setf (client-conn-selected-worktree conn) worktree)
        (%set-client-view conn :status))
      (t (%set-client-view conn :repolist))))
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
        (handler-case (nerimux/vcs:fetch-repository-async repository
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
   refresh status.  No longer bound to C-q C-f -- same removal, and the same
   reason to keep the function, as %WORKSPACE-PREFIX-FETCH-REPOSITORY above.
   Duplicate suppression and the completion callback mirror that function,
   one level up (nerimux/vcs:FETCH-ORGANIZATION-ASYNC)."
  (let ((organization (%client-selected-organization conn)))
    (cond
      ((not organization)
       (%client-notify conn "fetch requires a selected organization"))
      ((not (nerimux/vcs:vcs-package-available-p))
       (%client-notify conn "VCS adapter unavailable"))
      (t
        (%client-notify conn "fetching organization...")
        (handler-case (nerimux/vcs:fetch-organization-async organization
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

(defun %open-confirm-view (conn operation fields action)
  "Put a y/n confirmation in front of CONN and remember what to run on y.
   OPERATION titles the box; FIELDS is the ordered (LABEL . VALUE) body."
  (setf (client-conn-confirm-view conn)
        (nerimux/renderer:make-confirm-view :operation operation
                                            :fields fields
                                            :prompt-p t)
        (client-conn-confirm-action conn) action)
  ;; MODAL :confirm alongside CONFIRM-VIEW (contract §5): %HANDLE-MULTI-KEY-
  ;; MESSAGE routes purely on MODAL, so without this a confirmation would be
  ;; drawn but never reached by the key dispatch that is supposed to answer it.
  (%set-client-modal conn :confirm)
  nil)

(defun %close-confirm-view (conn)
  "Take the confirmation down and forget its pending action."
  (setf (client-conn-confirm-view conn) nil
        (client-conn-confirm-action conn) nil)
  (%set-client-modal conn nil))

(defun %handle-confirm-key (session conn payload)
  "Answer the confirmation CONN is looking at.  Returns two values: whether the
   key was consumed here, and the loop disposition.

   Only y and n are consumed.  Every other key is swallowed too — a
   confirmation that let j scroll the tree underneath it would be asking about
   one thing while the user changed another."
  (declare (ignore session))
  (let ((action (client-conn-confirm-action conn)))
    (cond
      ((%client-key-p payload #\y)
        (%close-confirm-view conn)
        (values t (and action (funcall action))))
      ((%client-key-p payload #\n)
        (%close-confirm-view conn)
        (%client-notify conn "cancelled")
        (values t nil))
      (t (values t nil)))))

(defun %workspace-prefix-quit-server (session conn)
  "C-q Q (R8.2): ask before stopping the server, showing how many panes are
   still running so the count is in front of the user at the moment they answer
   — not discovered afterwards."
  (let* ((live  (%session-live-panes session))
         (count (length live)))
    (%open-confirm-view
     conn
     "SERVER QUIT"
     (list (cons "session" (session-name session))
           (cons "panes" (format nil "~D open" count))
           (cons "effect" (if (plusp count)
                              "every pane is signalled and the server exits"
                              "the server exits")))
     (lambda ()
       ;; The confirm view already showed the live-pane count, so answering y IS
       ;; the force decision; %server-kill-request's refusal branch exists for
       ;; `nerimux kill` without --force, which has no screen to show it on.
       (%server-kill-request session t)
       :quit))))

(defun %workspace-prefix-dispatch (session conn byte)
  "Resolve BYTE — the key struck right after C-q — against 1.5's table and
   run its action.  Returns the loop disposition (NIL to keep serving,
   :drop for `d`).  A BYTE with no binding here is discarded: the prefix
   already consumed it and nothing else happens (R4.4)."
  (when (integerp byte)
    (cond
      ((= byte (char-code #\-)) (%workspace-prefix-split session conn :v))
      ((= byte (char-code #\|)) (%workspace-prefix-split session conn :h))
      ((= byte (char-code #\x)) (%workspace-prefix-close-pane session conn))
      ((= byte (char-code #\z)) (%workspace-prefix-toggle-zoom session conn))
      ((= byte (char-code #\h)) (%workspace-prefix-move-focus session conn :left))
      ((= byte (char-code #\j)) (%workspace-prefix-move-focus session conn :down))
      ((= byte (char-code #\k)) (%workspace-prefix-move-focus session conn :up))
      ((= byte (char-code #\l)) (%workspace-prefix-move-focus session conn :right))
      ((= byte (char-code #\n)) (%workspace-prefix-cycle-window session conn 1))
      ((= byte (char-code #\p)) (%workspace-prefix-cycle-window session conn -1))
      ((= byte (char-code #\w)) (%workspace-prefix-open-status session conn))
      ((= byte (char-code #\t))
       (%client-open-selected-worktree-command session conn nil))
      ((= byte (char-code #\[)) (%workspace-prefix-open-scrollback session conn))
      ((= byte (char-code #\d)) :drop)
      ((= byte (char-code #\Q)) (%workspace-prefix-quit-server session conn))
      ((= byte (client-conn-workspace-prefix-code conn))
       ;; C-q C-q: drop any MODAL and hand the keyboard back to whatever VIEW
       ;; is on screen (FR-007) — the only prefix action with no pane or
       ;; worktree precondition, so it is handled inline rather than via a
       ;; one-line %workspace-prefix-* wrapper.
       (%set-client-modal conn nil)
       nil)
      (t nil))))
