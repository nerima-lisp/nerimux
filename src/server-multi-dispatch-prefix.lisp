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
  "C-q - / C-q | : split the focused pane's window along ORIENT (R5.1/R5.3).
   At the per-window pane cap, opens a new window in the same worktree
   instead (R5.2) via the existing %open-client-worktree-pane path."
  (multiple-value-bind (pane window worktree)
      (%workspace-prefix-context session conn)
    (cond
      ((or (null pane) (null window))
       (%client-notify conn "no focused pane"))
      (t
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
                  (when (pane-live-p new-pane)
                    (start-reader-thread new-pane))
                  (window-select-pane window new-pane)
                  (%set-client-focus conn new-pane)
                  (%mark-dirty))
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
       (%server-kill-request session t)
       :quit))))

(define-key-rules %workspace-prefix-dispatch (session conn byte)
  "Resolve BYTE — the key struck right after C-q — against 1.5's table and
   run its action.  Returns the loop disposition (NIL to keep serving,
   :drop for `d`).  A BYTE with no binding here is discarded: the prefix
   already consumed it and nothing else happens (R4.4)."
  (#\- (%workspace-prefix-split session conn :v))
  (#\| (%workspace-prefix-split session conn :h))
  (#\x (%workspace-prefix-close-pane session conn))
  (#\z (%workspace-prefix-toggle-zoom session conn))
  (#\h (%workspace-prefix-move-focus session conn :left))
  (#\j (%workspace-prefix-move-focus session conn :down))
  (#\k (%workspace-prefix-move-focus session conn :up))
  (#\l (%workspace-prefix-move-focus session conn :right))
  (#\n (%workspace-prefix-cycle-window session conn 1))
  (#\p (%workspace-prefix-cycle-window session conn -1))
  (#\w (%workspace-prefix-open-status session conn))
  (#\t (%client-open-selected-worktree-command session conn nil))
  (#\[ (%workspace-prefix-open-scrollback session conn))
  (#\d :drop)
  (#\Q (%workspace-prefix-quit-server session conn))
  ((and (integerp byte)
        (= byte (client-conn-workspace-prefix-code conn)))
   (%set-client-modal conn nil)
   nil)
  (t nil))
