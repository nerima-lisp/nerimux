(in-package #:nerimux)

;;; ── C-q prefix action table (R4.4, 1.5) ─────────────────────────────────────
;;;
;;; Each action below takes SESSION/CONN and returns NIL (keep serving) or
;;; :drop (detach, for `d`).  %workspace-prefix-dispatch is the single place
;;; that maps a struck byte to an action; a byte not listed here is dropped.

(defconstant +max-panes-per-window+ 4
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
   another window of the same WORKTREE (most recently active first), else
   overview."
  (let* ((candidates (and worktree (worktree-panes worktree)))
         (best-pane
           (and candidates
                (first (sort (copy-list candidates) #'>
                             :key (lambda (p) (window-last-active-time
                                               (pane-window p))))))))
    (if best-pane
        (let* ((window (pane-window best-pane))
               (active (window-active-pane window)))
          (session-select-window session window)
          (%set-client-focus conn active))
        (%set-client-view conn :overview))))

(defun %workspace-prefix-close-pane (session conn)
  "C-q x : close the focused pane (R5.4).  Kills its PTY, drops it from its
   worktree and window, and — when that empties the window — closes the
   window too and refocuses per %workspace-refocus-after-window-close."
  (multiple-value-bind (pane window worktree)
      (%workspace-prefix-context session conn)
    (cond
      ((or (null pane) (null window))
       (%client-notify conn "no focused pane"))
      (t
       (%workspace-prefix-unzoom window)
       (close-pane-pty pane)
       (when worktree
         (setf (worktree-panes worktree) (delete pane (worktree-panes worktree)))
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
        (progn (window-zoom-toggle window) (%mark-dirty))
        (%client-notify conn "no focused pane")))
  nil)

(defun %workspace-prefix-move-focus (session conn direction)
  "C-q h/j/k/l : move focus to the neighbouring pane in DIRECTION,
   un-zooming first per R5.6."
  (multiple-value-bind (pane window) (%workspace-prefix-context session conn)
    (cond
      ((or (null pane) (null window))
       (%client-notify conn "no focused pane"))
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

(defun %workspace-prefix-fetch-repository (conn)
  "C-q F (R7.1): fetch the selected repository, then refresh status.

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
       (handler-case
           (nerimux/vcs:fetch-repository-async
            repository
            :callback-dispatch #'%enqueue-main-thread-callback
            :on-complete
            (lambda (result)
              (if result
                  (progn
                    (%refresh-client-picker conn)
                    (%client-notify conn "fetch complete"))
                  (%client-notify conn "fetch already in progress")))
            :on-error
            (lambda (condition)
              (%client-notify conn (format nil "fetch failed: ~A" condition))))
         (error (condition)
           (%client-notify conn (format nil "fetch failed: ~A" condition)))))))
  nil)

(defun %workspace-prefix-fetch-organization (conn)
  "C-q C-f (R7.1): fetch every repository in the selected organization
concurrently, then refresh status. Duplicate suppression and the completion
callback mirror %WORKSPACE-PREFIX-FETCH-REPOSITORY, one level up
(nerimux/vcs:FETCH-ORGANIZATION-ASYNC)."
  (let ((organization (%client-selected-organization conn)))
    (cond
      ((not organization)
       (%client-notify conn "fetch requires a selected organization"))
      ((not (nerimux/vcs:vcs-package-available-p))
       (%client-notify conn "VCS adapter unavailable"))
      (t
       (%client-notify conn "fetching organization...")
       (handler-case
           (nerimux/vcs:fetch-organization-async
            organization
            :callback-dispatch #'%enqueue-main-thread-callback
            :on-complete
            (lambda (repositories)
              (if repositories
                  (progn
                    (%refresh-client-picker conn)
                    (%client-notify conn "fetch complete"))
                  (%client-notify conn "fetch already in progress")))
            :on-error
            (lambda (repository condition)
              (%client-notify
               conn
               (format nil "fetch failed for ~A: ~A"
                       (nerimux/model:repository-id repository) condition))))
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
  (%mark-dirty)
  nil)

(defun %close-confirm-view (conn)
  "Take the confirmation down and forget its pending action."
  (setf (client-conn-confirm-view conn) nil
        (client-conn-confirm-action conn) nil)
  (%mark-dirty))

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
      ((= byte (char-code #\F)) (%workspace-prefix-fetch-repository conn))
      ((= byte #x06) (%workspace-prefix-fetch-organization conn)) ; C-f
      ((= byte (char-code #\d)) :drop)
      ((= byte (char-code #\Q)) (%workspace-prefix-quit-server session conn))
      ((= byte (client-conn-workspace-prefix-code conn))
       ;; C-q C-q: back to :normal — the only prefix action with no pane or
       ;; worktree precondition, so it is handled inline rather than via a
       ;; one-line %workspace-prefix-* wrapper.
       (%transition-client-ui-mode conn :enter-normal)
       (%mark-dirty)
       nil)
      (t nil))))
