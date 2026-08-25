(in-package #:nerimux/model)

;;; ── Session ID counter ──────────────────────────────────────────────────────

(defparameter *session-id-counter* 0
  "Auto-increment counter for session IDs. Each new session gets (incf *session-id-counter*).")

;;; ── Session ────────────────────────────────────────────────────────────────

(defstruct session
  "Top-level container: a named set of windows with one active."
  (id          0   :type fixnum)
  (name        ""  :type string)
  (windows     nil :type list)
  (active      nil)
  (last-active 0   :type integer)   ; universal-time of last access; updated on touch
  (created (get-universal-time) :type integer) ; universal-time at construction (#{session_created})
  (window-stack nil :type list)     ; windows in MRU order, current first (#{window_stack_index})
  ;; Per-session window index overrides: window -> index in THIS session.
  ;; One window can carry different indexes in different sessions; the
  ;; override applies only where link-window placed it at a non-default
  ;; slot (absent = the window's own id).
  (window-index-map (make-hash-table :test #'eq) :type hash-table)
  (clients     nil :type list)      ; list of connected client descriptors
  ;; NIL or string: session working dir (new-session/attach-session -c)
  (start-directory nil)
  (environment (make-hash-table :test #'equal))
  (environment-unsets nil :type list)
  ;; Names marked hidden via set-environment -h:
  ;; excluded from plain show-environment and from child-process environments.
  (environment-hidden nil :type list))

(defun session-active-window (session)
  "Return SESSION's active window, falling back to the first window when active is NIL."
  (or (session-active session)
      (first (session-windows session))))

(defun session-select-window (session window)
  "Make WINDOW the active window of SESSION.
   Updates WINDOW's last-active-time as a side effect so that session-last-window
   returns the correct recency order.  Callers that need a pure focus assignment
   without the timestamp side effect should set (session-active session) directly."
  (setf (session-active session) window)
  (when window
    ;; MRU stack for #{window_stack_index}: current window moves to the front.
    (setf (session-window-stack session)
          (cons window (delete window (session-window-stack session))))
    (setf (window-last-active-time window) (get-universal-time))))

(defun session-active-pane (session)
  "Return the active pane of SESSION's active window, or NIL when there is no window."
  (let ((window (session-active-window session)))
    (when window (window-active-pane window))))

;;; ── Full-screen window factory ──────────────────────────────────────────────
;;;
;;; Data/logic separation:
;;;   %attach-full-screen-pane  — window data setup (PTY pane → tree leaf)
;;;   session-new-window        — session attachment (window → session list)

(defun %attach-full-screen-pane (window rows cols &key start-dir)
  "Fork a shell and install it as WINDOW's sole full-screen leaf pane.
   START-DIR: when non-NIL, the shell starts in that directory.
   The initial pane gets +PANE-BASE-INDEX+."
  (let* ((pane (%fork-pane nil +pane-base-index+ 0 0 cols rows :start-dir start-dir)))
    (setf (window-panes  window) (list pane)
          (window-active window) pane
          (window-tree   window) (make-layout-leaf pane)
          (pane-window   pane)   window)))

(defun %next-window-id (session &optional (base-index 0))
  "Return the smallest integer >= BASE-INDEX not already used by any window in SESSION.
   BASE-INDEX defaults to 0."
  (let ((used (mapcar #'window-id (session-windows session))))
    (loop for i from base-index
          unless (member i used) return i)))

(defun session-window-index (session window)
  "WINDOW's index within SESSION: the per-session override when
   link-window placed it at a different slot here, else the window's own id."
  (or (and session
           (gethash window (session-window-index-map session)))
      (window-id window)))

(defun set-session-window-index (session window index)
  "Give WINDOW the per-session INDEX in SESSION.  An index equal to the
   window's own id clears the override (the default addressing)."
  (if (eql index (window-id window))
      (remhash window (session-window-index-map session))
      (setf (gethash window (session-window-index-map session)) index))
  index)

(defun session-windows-in-index-order (session)
  "SESSION's windows sorted by their per-session window index — the order
   used for listing windows (status bar, list-windows).  Identical to the plain
   list when no window carries an index override."
  (sort (copy-list (session-windows session)) #'<
        :key (lambda (w) (session-window-index session w))))

(defun session-insert-window (session window)
  "Insert WINDOW into SESSION's window list, keeping the list sorted by window-id.
   Does NOT update the active window — callers manage focus separately.
   Returns the updated window list (pure list management)."
  (setf (session-windows session)
        (sort (cons window (session-windows session)) #'< :key #'window-id))
  (session-windows session))

(defun session-new-window (session name rows cols &optional (base-index 0)
                                                            start-dir)
  "Create a new window with one full-screen pane, attach it to SESSION, and
   make it the active window.
   The new window receives the lowest free id >= BASE-INDEX (default 0).
   START-DIR: when non-NIL, the new pane's shell starts in that directory.
   The window list is kept sorted by window-id after insertion.
   Data/logic separation: window construction (%attach-full-screen-pane,
   session-insert-window) happens first; focus assignment (session-select-window)
   is a separate named step so callers can see the two concerns distinctly."
  (let* ((new-id (%next-window-id session base-index))
         (win (make-window :id new-id :name name :width cols :height rows)))
    (%attach-full-screen-pane win rows cols :start-dir start-dir)
    (session-insert-window session win)
    ;; Focus assignment is logic — kept as an explicit named call so callers
    ;; can opt out by using session-insert-window directly if no focus switch
    ;; is desired.
    (session-select-window session win)
    win))

;;; ── Window removal ──────────────────────────────────────────────────────────

(defun session-remove-window (session window)
  "Remove WINDOW from SESSION: drop it from the window list, the MRU stack,
   and the winlink index-override table.  Clears SESSION's active window when
   it was WINDOW — callers (R5.4: closing a window's last pane) reassign
   focus themselves; this only stops SESSION from pointing at a window that
   no longer exists.  Returns the updated window list."
  (setf (session-windows session) (delete window (session-windows session))
        (session-window-stack session)
        (delete window (session-window-stack session)))
  (remhash window (session-window-index-map session))
  (when (eq (session-active session) window)
    (setf (session-active session) nil))
  (session-windows session))

;;; ── Global state & initialisation ─────────────────────────────────────────

(defun session-touch (session)
  "Update SESSION's last-active timestamp to the current universal time."
  (setf (session-last-active session) (get-universal-time))
  session)

(defun %default-shell ()
  "Shell to spawn for a pane's child process: $SHELL, or \"/bin/sh\" when unset
   (§1.4 — the shell is no longer configurable, so this is the whole rule)."
  (or (nerimux/ports:environment-value "SHELL") "/bin/sh"))

(defun %shell-basename ()
  "Basename of the shell %DEFAULT-SHELL resolves to, used as the initial
   window name."
  (let* ((shell (%default-shell))
         (slash-pos (position #\/ shell :from-end t)))
    (if slash-pos
        (subseq shell (1+ slash-pos))
        shell)))

(defconstant +status-line-rows+ 1
  "Rows the status bar occupies (§1.4: status line is fixed to one row at the
   bottom). Replaces the old configurable 0..5 range from the `status' option.")

(defconstant +base-index+ 1
  "First window id in a session (§1.4: window / pane numbering starts at 1).")

(defun create-initial-session (rows cols &key start-dir)
  "Bootstrap: one session, one window, one full-screen pane.
   The first window gets +BASE-INDEX+.
   START-DIR: when non-NIL, the initial shell starts in that directory.
   PANE-ROWS subtracts +STATUS-LINE-ROWS+ from ROWS to leave one row for the
   status bar at the bottom of the outer terminal."
  (let* ((session   (make-session :id (incf *session-id-counter*)
                                  :name "0"
                                  :last-active (get-universal-time)))
         ;; Reserve one row at the bottom for the status bar.
         (pane-rows (- rows +status-line-rows+)))
    (session-new-window session (%shell-basename) pane-rows cols +base-index+ start-dir)
    session))

(defun all-panes (session)
  "Flat list of every pane across all windows of SESSION."
  (loop for window in (session-windows session)
        nconc (copy-list (window-panes window))))

;;; ── Window reordering ────────────────────────────────────────────────────────

(defun session-move-window (session window target-index)
  "Move WINDOW to TARGET-INDEX (0-based) in SESSION's window list.
   Clamps TARGET-INDEX to valid range. Returns the updated window list."
  (let* ((wins      (session-windows session))
         (win-count (length wins))
         (src-idx   (position window wins)))
    (when src-idx
      (let* ((dst     (max 0 (min (1- win-count) target-index)))
             (without (append (subseq wins 0 src-idx)
                              (subseq wins (1+ src-idx))))
             (before  (subseq without 0 dst))
             (after   (subseq without dst)))
        (setf (session-windows session) (append before (list window) after)))))
  (session-windows session))

(defun session-swap-windows (session index-a index-b)
  "Exchange the windows at INDEX-A and INDEX-B in SESSION's window list.
   Indices are 0-based. No-op when indices are equal or out of range."
  (let* ((wins      (session-windows session))
         (win-count (length wins)))
    (when (and (/= index-a index-b)
               (< -1 index-a win-count)
               (< -1 index-b win-count))
      (let ((new-wins (copy-list wins)))
        (rotatef (nth index-a new-wins) (nth index-b new-wins))
        (setf (session-windows session) new-wins))))
  (session-windows session))

(defun session-last-window (session)
  "Return the window with the second-highest last-active-time (i.e. the
   previously active window), or NIL when only one window exists."
  (let* ((wins   (session-windows session))
         (sorted (sort (copy-list wins) #'>
                       :key #'window-last-active-time)))
    (second sorted)))

;;; Environment management has been split into
;;; session-environment-process.lisp, session-environment-overlay.lisp, and
;;; session-environment-child.lisp.
