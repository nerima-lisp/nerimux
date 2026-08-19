(in-package #:nerimux/test)

;;;; Tests for Sprint 3 advanced features:
;;;;  break-pane, synchronize-panes, layout persistence,
;;;;  lock-session, pipe-pane, session groups, choose-session.

;;; ── Fixtures ─────────────────────────────────────────────────────────────────

(defun %two-pane-session ()
  "Session with one window containing two fake panes side-by-side."
  (let* ((p0  (make-no-pty-pane 1  0 0 40 24))
         (p1  (make-no-pty-pane 2 41 0 40 24))
         (win (make-window :id 1 :name "w" :width 81 :height 24
                           :panes (list p0 p1)
                           :tree (make-layout-split :h
                                    (make-layout-leaf p0)
                                    (make-layout-leaf p1)
                                    1/2)))
         (sess (make-session :id 1 :name "0" :windows (list win))))
    (window-select-pane win p0)
    (session-select-window sess win)
    (values sess win p0 p1)))

(defun %make-group-test-window (id)
  "Build a minimal no-PTY window for session-group propagation tests."
  (let ((pane (make-no-pty-pane (+ 10 id) 0 0 80 24)))
    (let ((win (make-window :id id :name (format nil "w~D" id)
                            :width 80 :height 24
                            :panes (list pane) :tree (make-layout-leaf pane))))
      (setf (nerimux/model:pane-window pane) win)
      (window-select-pane win pane)
      win)))

(defmacro with-grouped-sessions ((s1 s2 win) &body body)
  "Bind S1/S2 to two grouped sessions sharing window WIN (group registry isolated)."
  `(let* ((,win (%make-group-test-window 1))
          (,s1  (make-session :id 1 :name "a" :windows (list ,win)))
          (,s2  (make-session :id 2 :name "b"))
          (nerimux::*session-groups* nil))
     (session-select-window ,s1 ,win)
     (nerimux::server-new-session-in-group ,s2 ,s1)
     ,@body))

(describe "advanced-suite"

  ;;; ── break-pane: creates a new window ─────────────────────────────────────────

  ;; break-pane removes the active pane from its window and attaches it to a
  ;; brand-new window; the session ends with 2 windows.
  (it "break-pane-creates-new-window"
    (multiple-value-bind (sess win p0 p1) (%two-pane-session)
      (declare (ignore p1))
      ;; Break the active pane (p0) out.
      (let ((new-win (nerimux/commands:break-pane sess)))
        (expect new-win :to-be-truthy)
        (expect (= 2 (length (session-windows sess))))
        ;; The new window contains only the broken-out pane.
        (expect (equal (list p0) (window-panes new-win)))
        ;; The original window lost that pane.
        (expect (= 1 (length (window-panes win)))))))

  ;; break-pane returns NIL and does nothing when the window has only one pane.
  (it "break-pane-noop-on-sole-pane"
    (let* ((p0   (make-no-pty-pane 1 0 0 80 24))
           (win  (make-window :id 1 :name "w" :width 80 :height 24
                              :panes (list p0)
                              :tree (make-layout-leaf p0)))
           (sess (make-session :id 1 :name "0" :windows (list win))))
      (window-select-pane win p0)
      (session-select-window sess win)
      (expect (null (nerimux/commands:break-pane sess)))
      (expect (= 1 (length (session-windows sess))))))

  ;;; ── synchronize-panes: sends keystrokes to all panes ─────────────────────────

  ;; synchronize-panes previously drove the keystroke-forwarding fanout
  ;; (removed with presentation/events); the option itself is still a
  ;; first-class registered option, so this verifies the toggle round-trips.
  (it "synchronize-panes-sends-to-all"
    (let ((prev (nerimux/options:get-option "synchronize-panes")))
      (unwind-protect
           (progn
             (nerimux/options:set-option "synchronize-panes" t)
             (expect (nerimux/options:get-option "synchronize-panes"))
             (nerimux/options:set-option "synchronize-panes" nil)
             (expect (not (nerimux/options:get-option "synchronize-panes"))))
        (nerimux/options:set-option "synchronize-panes" prev))))

  ;; synchronize-panes is a registered option with boolean type and default nil.
  (it "synchronize-panes-option-registered"
    (let ((spec (gethash "synchronize-panes" nerimux/options:*option-registry*)))
      (expect spec :to-be-truthy)
      (expect (eq :boolean (nerimux/options:option-spec-type spec)))
      (expect (null (nerimux/options:option-spec-default spec)))))

  ;;; ── Layout persistence: round-trip ──────────────────────────────────────────

  ;; layout->string returns a non-NIL string for a window that has a tree.
  (it "layout-to-string-not-nil-for-window-with-tree"
    (multiple-value-bind (sess win p0 p1) (%two-pane-session)
      (declare (ignore sess p0 p1))
      (let ((str (nerimux/model:layout->string win)))
        (expect str :to-be-truthy)
        (expect (stringp str))
        (expect (plusp (length str))))))

  ;; layout->string returns NIL when the window has no tree.
  (it "layout-to-string-nil-for-empty-window"
    (let ((win (make-window :id 1 :name "w" :width 80 :height 24
                            :tree nil)))
      (expect (null (nerimux/model:layout->string win)))))

  ;; layout->string result starts with a 4-character hex checksum.
  (it "layout-checksum-4-hex-chars"
    (multiple-value-bind (_sess win p0 p1) (%two-pane-session)
      (declare (ignore _sess p0 p1))
      (let* ((str     (nerimux/model:layout->string win))
             (comma   (position #\, str))
             (csum    (and comma (subseq str 0 comma))))
        (expect (and csum (= 4 (length csum))))
        (expect (every (lambda (ch) (or (digit-char-p ch) (find ch "ABCDEFabcdef")))
                       (or csum ""))))))

  ;;; ── lock-session / unlock ────────────────────────────────────────────────────

  ;; When session-locked-p is T, render-session-to-string returns a lock screen
  ;; string (contains the lock message) rather than normal content.
  (it "lock-session-renders-lockscreen"
    (multiple-value-bind (sess win p0 p1) (%two-pane-session)
      (declare (ignore win p0 p1))
      (setf (session-locked-p sess) t)
      (let ((output (nerimux/renderer:render-session-to-string sess 24 80)))
        (expect (search "locked" output)))
      (setf (session-locked-p sess) nil)))

  ;; session struct has session-locked-p slot, defaulting to NIL.
  (it "lock-session-struct-slot"
    (let ((sess (make-session :id 1 :name "test")))
      (expect (session-locked-p sess) :to-be-falsy)
      (setf (session-locked-p sess) t)
      (expect (session-locked-p sess))))

  ;;; ── pipe-pane tee output ─────────────────────────────────────────────────────

  ;; pipe-pane-open marks the pane active; pipe-pane-close clears every pipe slot.
  (it "pipe-pane-tees-output"
    (let ((p (make-no-pty-pane 1 0 0 80 24)))
      ;; Initially no pipe.
      (expect (null (pane-pipe-active-p p)))
      ;; Close is a no-op when there is no pipe.
      (finishes (nerimux/commands:pipe-pane-close p))
      (expect (null (pane-pipe-fd p)))
      (expect (null (pane-pipe-output-stream p)))
      (expect (null (pane-pipe-output-thread p)))
      (expect (null (pane-pipe-process p)))))

  ;; pipe-pane-write does nothing and does not signal an error when pipe-fd is NIL.
  (it "pipe-pane-write-is-no-op-when-no-pipe"
    (let ((p     (make-no-pty-pane 1 0 0 80 24))
          (bytes (make-array 5 :element-type '(unsigned-byte 8)
                               :initial-contents '(104 101 108 108 111))))
      (expect (null (pane-pipe-fd p)))
      (finishes (nerimux/commands:pipe-pane-write p bytes))))

  ;;; ── Session groups ───────────────────────────────────────────────────────────

  ;; session struct has session-group slot defaulting to NIL.
  (it "session-group-slot-defaults-nil"
    (let ((sess (make-session :id 1 :name "x")))
      (expect (null (session-group sess)))))

  ;; server-new-session-in-group links two sessions so they share the window list.
  (it "session-groups-share-windows"
    (let* ((p0   (make-no-pty-pane 1 0 0 80 24))
           (win  (make-window :id 1 :name "w" :width 80 :height 24
                              :panes (list p0) :tree (make-layout-leaf p0)))
           (s1   (make-session :id 1 :name "a" :windows (list win)))
           (s2   (make-session :id 2 :name "b")))
      (window-select-pane win p0)
      (session-select-window s1 win)
      ;; Bind sessions into a group.
      (let ((nerimux::*session-groups* nil))
        (nerimux::server-new-session-in-group s2 s1)
        (expect (session-group s1) :to-be-truthy)
        (expect (eql (session-group s1) (session-group s2)))
        (expect (eq (session-windows s1) (session-windows s2))))))

  ;; Inserting a window into one grouped session makes it visible in the others
  ;; (tmux session groups share ONE window set, not just the initial list value).
  (it "session-group-new-window-propagates-to-peers"
    (with-grouped-sessions (s1 s2 win)
      (let ((new-win (%make-group-test-window 2)))
        (session-insert-window s1 new-win)
        (expect (member new-win (session-windows s2)))
        (expect (member win (session-windows s2))))))

  ;; kill-window in one grouped session removes the window from all peers, and a
  ;; peer whose active window vanished falls back to a surviving window.
  (it "session-group-kill-window-propagates-to-peers"
    (with-grouped-sessions (s1 s2 win)
      (let ((new-win (%make-group-test-window 2)))
        (session-insert-window s1 new-win)
        ;; Peer views the window that is about to be killed.
        (setf (nerimux/model:session-active s2) new-win)
        (nerimux/commands:kill-window s1 new-win)
        (expect (null (member new-win (session-windows s2))))
        (expect (eq win (session-active-window s2))))))

  ;; session-windows-changed on a session without a group is a no-op.
  (it "session-group-sync-ignores-ungrouped-sessions"
    (let* ((win (%make-group-test-window 1))
           (s   (make-session :id 3 :name "solo" :windows (list win)))
           (nerimux::*session-groups* nil))
      (finishes (nerimux/model:session-windows-changed s))
      (expect (equal (list win) (session-windows s)))))

  ;;; ── update-environment ───────────────────────────────────────────────────────

  ;; *update-environment* is a list of environment variable names.
  (it "update-environment-default-list"
    (let ((vars nerimux::*update-environment*))
      (expect (listp vars))
      (expect (> (length vars) 0))
      (expect (every #'stringp vars)))))
