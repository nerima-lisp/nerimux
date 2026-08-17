(in-package #:cl-tmux/model)

;;; ── Pane ───────────────────────────────────────────────────────────────────

(defstruct pane
  "One terminal pane: a PTY fd + virtual screen + position within its window."
  ;; ── Identity ──────────────────────────────────────────────────────────────
  (id       0   :type fixnum)
  ;; ── Geometry ──────────────────────────────────────────────────────────────
  (x        0   :type fixnum)
  (y        0   :type fixnum)
  (width    80  :type fixnum)
  (height   24  :type fixnum)
  ;; ── PTY file descriptors ──────────────────────────────────────────────────
  (fd       -1  :type fixnum)         ; master PTY file descriptor
  (pid      -1  :type fixnum)         ; child process PID
  (pipe-fd  nil)                      ; NIL or stream for pipe-pane output tee
  (pipe-output-stream nil)            ; NIL or stream for command stdout -> pane
  (pipe-output-thread nil)            ; NIL or copier thread for command stdout
  (pipe-process nil)                  ; NIL or process-kit:process-handle for pipe-pane
  ;; ── Terminal emulator ─────────────────────────────────────────────────────
  (screen   nil)
  ;; ── Window back-pointer and state ─────────────────────────────────────────
  (window   nil)                      ; back-pointer to the owning window (set on attach)
  (worktree nil)                      ; logical repository worktree shown by this pane
  (marked           nil)              ; T when this pane is the marked pane (C-b m)
  (input-disabled   nil :type boolean) ; T when select-pane -d disables input
  ;; ── Identity strings ──────────────────────────────────────────────────────
  (title    "" :type string)          ; pane title set via OSC 0/2 (#{pane_title})
  (tty      "" :type string)          ; slave PTY device path, e.g. /dev/pts/3 (#{pane_tty})
  ;; ── Spawn record (#{pane_start_command} / #{pane_start_path}) ────────────
  (start-command "" :type string)     ; resolved command the pane started with
  (start-path    "" :type string)     ; initial working directory
  ;; ── Death record (remain-on-exit / #{pane_dead_status} family) ───────────
  (dead-status nil)                   ; NIL or exit code of the dead child
  (dead-signal nil)                   ; NIL or terminating signal number
  (dead-time   nil)                   ; NIL or universal-time when the pane died
  (tags nil :type list)
  (note "" :type string)
  (unread-output-p nil :type boolean)
  (bell-p nil :type boolean)
  (process-exited-p nil :type boolean)
  (non-zero-exit-p nil :type boolean)
  (startup-failed-p nil :type boolean)
  (last-output-time nil)
  (last-focused-time nil)
  (last-output "" :type string)
  (notification "" :type string)
  ;; ── Per-pane option overrides ─────────────────────────────────────────────
  (local-options (make-hash-table :test #'equal) :type hash-table))

(defun worktree-add-pane (worktree pane)
  "Attach PANE to WORKTREE and return PANE."
  (when (and worktree pane)
    (pushnew pane (worktree-panes worktree) :test #'eq)
    (setf (pane-worktree pane) worktree))
  pane)

(defun %pane-output-preview (bytes)
  (with-output-to-string (stream)
    (let ((start (max 0 (- (length bytes) 256))))
      (loop for index from start below (length bytes)
            for code = (elt bytes index)
            do (write-char
                (cond
                  ((or (= code 10) (= code 13)) #\Space)
                  ((= code 9) #\Tab)
                  ((<= 32 code 126) (code-char code))
                  (t #\.))
                stream)))))

(defun pane-mark-output (pane bytes)
  (when (and pane bytes)
    (setf (pane-unread-output-p pane) t
          (pane-last-output-time pane) (get-universal-time)
          (pane-last-output pane) (%pane-output-preview bytes)))
  pane)

(defun pane-mark-bell (pane)
  (when pane
    (setf (pane-bell-p pane) t
          (pane-unread-output-p pane) t
          (pane-last-output-time pane) (get-universal-time)))
  pane)

(defun pane-mark-process-exit (pane &key status signal)
  (when pane
    (setf (pane-process-exited-p pane) t
          (pane-non-zero-exit-p pane)
          (or (and (integerp status) (not (zerop status)))
              (and (integerp signal) (plusp signal)))
          (pane-unread-output-p pane) t
          (pane-last-output-time pane) (get-universal-time)))
  pane)

(defun pane-mark-startup-failure (pane)
  (when pane
    (setf (pane-startup-failed-p pane) t
          (pane-process-exited-p pane) t
          (pane-non-zero-exit-p pane) t
          (pane-unread-output-p pane) t
          (pane-last-output-time pane) (get-universal-time)))
  pane)

(defun pane-notify (pane message)
  (when pane
    (setf (pane-notification pane)
          (if (stringp message) message (princ-to-string message))
          (pane-unread-output-p pane) t
          (pane-last-output-time pane) (get-universal-time)))
  pane)

(defun pane-clear-unread-output (pane)
  (when pane
    (setf (pane-unread-output-p pane) nil))
  pane)

(defun pane-mark-focused (pane)
  (when pane
    (setf (pane-last-focused-time pane) (get-universal-time))
    (pane-clear-unread-output pane))
  pane)

(defun pane-attention-reasons (pane)
  (when pane
    (let ((reasons nil))
      (when (pane-unread-output-p pane) (push :unread-output reasons))
      (when (pane-bell-p pane) (push :bell reasons))
      (when (pane-process-exited-p pane) (push :process-exited reasons))
      (when (pane-non-zero-exit-p pane) (push :non-zero-exit reasons))
      (when (pane-startup-failed-p pane) (push :startup-failed reasons))
      (when (plusp (length (pane-notification pane)))
        (push :notification reasons))
      (nreverse reasons))))

(defun pane-attention-p (pane)
  (not (null (pane-attention-reasons pane))))

(defun pane-pipe-active-p (pane)
  "Return T when PANE has any pipe-pane direction active."
  (and pane
       (or (pane-pipe-fd pane)
           (pane-pipe-output-stream pane)
           (pane-pipe-output-thread pane)
           (pane-pipe-process pane))))

(defun pane-live-p (pane)
  "Return T when PANE still has a live PTY master fd."
  (and pane (> (pane-fd pane) 0)))

;;; ── Response-queue drain helper (logic layer) ──────────────────────────────
;;;
;;; Draining pending terminal-query responses lives here as a named step so that
;;; pane-feed can express the "drain" concern independently of the "process" concern.
;;; The queue is populated by the CPS parser under the screen lock; it is drained
;;; outside the lock so pty-write never blocks while holding the screen lock.

(defun %drain-response-queue (pane screen)
  "Drain SCREEN's response queue, writing each reply to PANE's PTY fd.
   Replies are reversed from newest-first to arrival order before writing.
   Pure I/O at the orchestration boundary — no screen struct mutation.
   Returns NIL."
  (when (screen-response-queue screen)
    (let ((replies (nreverse (screen-response-queue screen))))
      (setf (screen-response-queue screen) nil)
      (when (> (pane-fd pane) 0)
        (dolist (reply replies)
          (write-pty (pane-fd pane) reply))))))

(defun pane-feed (pane bytes)
  "Feed raw PTY bytes into PANE's screen, then drain any device-report replies
   (DA1/DA2/CPR/DSR/DECRQM/XTGETTCAP/DECRQSS/OSC-color) back to the PTY.
   The response queue is populated by the CPS parser under the screen lock;
   it is drained outside the lock so write-pty never blocks while holding it."
  (let ((screen (pane-screen pane)))
    (with-lock-held ((screen-lock screen))
      (screen-process-bytes screen bytes))
    (%drain-response-queue pane screen)))

;;; Pane spawn and geometry helpers were split into:
;;;   - pane-geometry.lisp
;;;   - pane-spawn.lisp
