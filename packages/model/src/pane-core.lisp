(in-package #:nerimux/pane)

(defconstant +pane-notification-coalesce-seconds+
  1
  "The timestamp bucket used to coalesce pane notification events.")

(defstruct pane
  "One terminal pane: a PTY fd + virtual screen + position within its window."
  (id       0   :type fixnum)
  (x        0   :type fixnum)
  (y        0   :type fixnum)
  (width    80  :type fixnum)
  (height   24  :type fixnum)
  (fd       -1  :type fixnum)
  (pid      -1  :type fixnum)
  (process-lock (cl-concurrent-kit:make-lock :name "pane process"))
  (process-generation (list nil))
  (stop-requested nil)
  (screen   nil)
  (window   nil)
  (worktree nil)
  (agent-kind nil :type (member nil :codex :claude))
  (role :terminal :type (member :terminal :agent))
  (marked           nil)
  (input-disabled   nil :type boolean)
  (title    "" :type string)
  (tty      "" :type string)
  (start-command "" :type string)
  (start-path    "" :type string)
  (start-time (get-universal-time) :type integer)
  (unread-output-p nil :type boolean)
  ;; Set by PANE-MARK-FOCUSED, the same real open/switch a user does before a
  ;; pane's own first prompt can arrive. A restored pane (runtime-lifecycle.lisp)
  ;; is never focused during restore, so it starts unseen and its own first
  ;; prompt does not mark it unread.
  (seen-p nil :type boolean)
  (bell-p nil :type boolean)
  (process-exited-p nil :type boolean)
  (non-zero-exit-p nil :type boolean)
  (startup-failed-p nil :type boolean)
  (last-output-time nil)
  (last-focused-time nil)
  (last-output "" :type string)
  (notification "" :type string)
  ;; True only when NOTIFICATION came from the program in the pane (a BEL or an
  ;; OSC 9/99/777), never from nerimux's own message strip: %CLIENT-NOTIFY
  ;; copies every strip message onto the focused pane, and counting those as a
  ;; reason held a worktree in Attention from the first refresh onward.
  (notification-attention-p nil :type boolean)
  (raw-notification-queue nil :type list)
  (last-notification-time nil)
  (pending-raw-notification nil :type list)
  (local-options (make-hash-table :test #'equal) :type hash-table))

(defun worktree-add-pane (worktree pane)
  "Attach PANE to WORKTREE and return PANE."
  (when (and worktree pane)
    (when (and (pane-agent-kind pane)
               (worktree-running-agent-p worktree)
               (not (eq pane (worktree-agent-pane worktree))))
      (error "worktree already has a running agent"))
    (pushnew pane (worktree-panes worktree) :test #'eq)
    (setf (pane-worktree pane) worktree)
    (when (and (pane-agent-kind pane) (not (pane-startup-failed-p pane)))
      (setf (worktree-agent-pane worktree) pane)))
  pane)

(defun worktree-running-agent-p (worktree)
  (let ((pane (and worktree (worktree-agent-pane worktree))))
    (and pane (or (pane-live-p pane) (pane-stop-requested pane))
         (not (pane-process-exited-p pane)))))

(defun worktree-agent-state (worktree)
  (cond ((null (worktree-agent-pane worktree)) :none)
        ((worktree-running-agent-p worktree) :running)
        (t :exited)))

(defun %agent-pane-p (pane)
  (and pane (or (eq (pane-role pane) :agent)
                (pane-agent-kind pane))))

(defun %mark-agent-waiting (pane message &optional (now (get-universal-time)))
  (when (and (%agent-pane-p pane) (pane-worktree pane))
    (worktree-mark-waiting (pane-worktree pane) message now)))

(defun worktree-resume (worktree pane)
  (when (and worktree pane
             (eq (pane-worktree pane) worktree)
             (pane-live-p pane)
             (not (pane-process-exited-p pane))
             (not (pane-startup-failed-p pane)))
    (setf (worktree-completed-p worktree) nil))
  worktree)

(defconstant +pane-output-preview-length+
  256
  "Characters of PANE-LAST-OUTPUT kept for its readers (picker subtitle,
   workspace detail panel).")

(defun %pane-escape-sequence-end (bytes index)
  "Index just past the escape sequence BYTES starts at INDEX, an ESC byte.
   CSI runs to its final byte (0x40..0x7E); OSC, DCS, PM and APC run to BEL or
   ST; anything else is a two-byte escape."
  (let* ((length (length bytes))
         (introducer (when (< (1+ index) length) (elt bytes (1+ index)))))
    (cond
      ((null introducer) length)
      ((= introducer 91)
       (let ((scan (+ index 2)))
         (loop while (and (< scan length) (not (<= 64 (elt bytes scan) 126)))
               do (incf scan))
         (min length (1+ scan))))
      ((member introducer '(80 93 94 95))
       (let ((scan (+ index 2)))
         (loop while (and (< scan length)
                          (/= (elt bytes scan) 7)
                          (not (and (= (elt bytes scan) 27)
                                    (< (1+ scan) length)
                                    (= (elt bytes (1+ scan)) 92))))
               do (incf scan))
         (cond ((>= scan length) length)
               ((= (elt bytes scan) 7) (1+ scan))
               (t (+ scan 2)))))
      (t (+ index 2)))))

(defun %pane-output-preview (bytes)
  "The tail of BYTES as plain text: escape sequences dropped whole, newlines
   folded to spaces, the last +PANE-OUTPUT-PREVIEW-LENGTH+ characters kept.
   Dropping the sequence rather than only its ESC is what keeps \"[?2004h\",
   the bracketed-paste enable every shell emits at its prompt, out of the
   picker subtitle and the detail panel. Scans the whole of BYTES from index
   0 rather than a bounded tail window: BYTES is already one PTY read buffer,
   so its size bounds the scan, and a bounded lookback risked starting the
   scan inside an unterminated escape sequence longer than the lookback,
   leaking its parameter bytes into the preview as text."
  (let ((text
          (with-output-to-string (stream)
            (let ((length (length bytes))
                  (index 0))
              (loop while (< index length)
                    do (let ((code (elt bytes index)))
                         (if (= code 27)
                             (setf index
                                   (%pane-escape-sequence-end bytes index))
                             (progn
                               (write-char
                                (cond
                                  ((or (= code 10) (= code 13)) #\Space)
                                  ((= code 9) #\Tab)
                                  ((<= 32 code 126) (code-char code))
                                  (t #\.))
                                stream)
                               (incf index)))))))))
    (if (> (length text) +pane-output-preview-length+)
        (subseq text (- (length text) +pane-output-preview-length+))
        text)))

(defun pane-mark-output (pane bytes)
  (when (and pane bytes)
    (when (pane-seen-p pane)
      (setf (pane-unread-output-p pane) t))
    (setf (pane-last-output-time pane) (get-universal-time)
          (pane-last-output pane) (%pane-output-preview bytes)))
  pane)

(defun pane-mark-bell (pane)
  (when pane
    (let ((now (get-universal-time)))
      (setf (pane-bell-p pane) t
            (pane-unread-output-p pane) t
            (pane-last-output-time pane) now)
      (%mark-agent-waiting pane "BEL" now)))
  pane)

(defconstant +pane-launch-failure-seconds+
  2
  "A non-zero exit this many seconds after the pane started is a failed launch,
   not a finished job: the command never ran long enough to be doing work.")

(defun %pane-command-name (pane)
  "The program name of PANE's start command, or NIL for a plain shell pane."
  (let ((command (pane-start-command pane)))
    (when (plusp (length command))
      (subseq command 0 (or (position #\Space command) (length command))))))

(defun %pane-launch-failure-text (pane status now)
  "\"claude: exited 127 (not found?)\" when PANE's command died on launch."
  (let ((name (%pane-command-name pane)))
    (when (and name
               (integerp status)
               (not (zerop status))
               (<= (- now (pane-start-time pane)) +pane-launch-failure-seconds+))
      (format nil "~A: exited ~D~@[ ~A~]"
              name status (when (= status 127) "(not found?)")))))

(defun %pane-report-launch-failure (pane text)
  "Say it in the pane the user is looking at, in nerimux's own voice: the raw
   `sh: claude: command not found` above it names no fix and no owner."
  (pane-notify pane text)
  (when (pane-screen pane)
    (pane-feed pane
               (cl-codec-kit:string-to-octets
                (format nil "~C~Cnerimux: ~A~C~C" #\Return #\Newline text
                        #\Return #\Newline)
                :encoding :utf-8))))

(defun pane-mark-process-exit (pane &key status signal)
  (when pane
    (let* ((now (get-universal-time))
           (launch-failure (%pane-launch-failure-text pane status now)))
      (setf (pane-process-exited-p pane) t
            (pane-non-zero-exit-p pane) (or
                                         (and (integerp status)
                                              (not (zerop status)))
                                         (and (integerp signal) (plusp signal)))
            (pane-unread-output-p pane) t
            (pane-last-output-time pane) now)
      (if launch-failure
          (%pane-report-launch-failure pane launch-failure)
          (%mark-agent-waiting pane "process exited" now))))
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
  "Show MESSAGE on PANE as its latest notification text.
   This is nerimux talking, not the program in the pane, so it does not by
   itself make the pane -- or the worktree holding it -- need attention."
  (when pane
    (setf (pane-notification pane) (if (stringp message)
                                       message
                                       (princ-to-string message))
          (pane-unread-output-p pane) t
          (pane-last-output-time pane) (get-universal-time)))
  pane)

(defun pane-record-notification (pane raw-bytes text &optional (now (get-universal-time)))
  "Store the newest raw notification while enforcing PANE's one-second rate.
   A notification waiting in the queue is replaced by a newer eligible event;
   events arriving before the next eligible second are coalesced separately."
  (when pane
    (pane-notify pane text)
    (setf (pane-notification-attention-p pane) t)
    (%mark-agent-waiting
     pane
     (if (and (= (length raw-bytes) 1)
              (= (elt raw-bytes 0) #x07))
         "BEL"
         (let ((line-end (or (position #\Newline text)
                             (position #\Return text))))
           (let ((line (subseq text 0 (or line-end (length text)))))
             (if (plusp (length line)) line "OSC notification"))))
     now)
    (let ((entry (cons now
                       (coerce raw-bytes
                               '(simple-array (unsigned-byte 8) (*))))))
      (if (or (null (pane-last-notification-time pane))
              (>= (- now (pane-last-notification-time pane))
                  +pane-notification-coalesce-seconds+))
          (setf (pane-raw-notification-queue pane) (list entry)
                (pane-pending-raw-notification pane) nil)
          (setf (pane-pending-raw-notification pane) entry))))
  pane)

(defun pane-drain-notifications (pane)
  "Return PANE's raw notification sequences and clear the send queue.
   A coalesced event becomes eligible only after the one-second interval from
   the last forwarded event has elapsed."
  (when pane
    (with-lock-held ((pane-process-lock pane))
      (let ((now (get-universal-time)))
        (when (and (pane-pending-raw-notification pane)
                   (pane-last-notification-time pane)
                   (>= (- now (pane-last-notification-time pane))
                       +pane-notification-coalesce-seconds+))
          (setf (pane-raw-notification-queue pane)
                (list (pane-pending-raw-notification pane))
                (pane-pending-raw-notification pane) nil))
        (let ((entries (nreverse (pane-raw-notification-queue pane))))
          (setf (pane-raw-notification-queue pane) nil)
          (when entries
            (setf (pane-last-notification-time pane) now))
          (mapcar #'cdr entries))))))

(defun pane-clear-unread-output (pane)
  (when pane
    (setf (pane-unread-output-p pane) nil))
  pane)

(defun pane-mark-focused (pane)
  (when pane
    (setf (pane-last-focused-time pane) (get-universal-time)
          (pane-seen-p pane) t
          ;; The user is looking at the pane the notification was about, so it
          ;; is no longer something the worktree is waiting on. The text itself
          ;; stays for the detail panel.
          (pane-notification-attention-p pane) nil)
    (when (and (%agent-pane-p pane) (pane-worktree pane))
      (worktree-clear-waiting (pane-worktree pane)))
    (pane-clear-unread-output pane))
  pane)

(defun pane-attention-reasons (pane)
  (when pane
    (let ((reasons nil))
      (when (pane-unread-output-p pane)
        (push :unread-output reasons))
      (when (pane-bell-p pane)
        (push :bell reasons))
      (when (pane-process-exited-p pane)
        (push :process-exited reasons))
      (when (pane-non-zero-exit-p pane)
        (push :non-zero-exit reasons))
      (when (pane-startup-failed-p pane)
        (push :startup-failed reasons))
      (when (pane-notification-attention-p pane)
        (push :notification reasons))
      (nreverse reasons))))

(defun pane-attention-p (pane)
  (not (null (pane-attention-reasons pane))))

(defun pane-live-p (pane)
  "Return T when PANE still has a live PTY master fd."
  (and pane (> (pane-fd pane) 0)))

(defun pane-agent-p (pane)
  (and pane (or (eq (pane-role pane) :agent)
                (pane-agent-kind pane))))

(defun worktree-live-panes (worktree)
  (remove-if-not #'pane-live-p (worktree-panes worktree)))

(defun worktree-removal-blockers (worktree)
  (when worktree
    (let ((blockers nil))
      (when (worktree-locked-p worktree) (push :locked-worktree blockers))
      (when (worktree-live-panes worktree) (push :live-pane blockers))
      (nreverse blockers))))

(defun worktree-removal-candidate-p (worktree)
  (and worktree
       (not (worktree-missing-p worktree))
       (or (worktree-completed-p worktree)
           (let ((agent (worktree-agent-pane worktree)))
             (and agent (pane-process-exited-p agent))))))

;;; Drain parser replies after releasing the screen lock so PTY writes do not
;;; block screen processing.
(defun %drain-response-queue (pane screen)
  "Drain SCREEN's response queue, writing each reply to PANE's PTY fd.
   Replies are reversed from newest-first to arrival order before writing.
   Pure I/O at the orchestration boundary, no screen struct mutation.
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
  (let ((screen (pane-screen pane))
        (notifications nil))
    (with-lock-held ((screen-lock screen))
                    (screen-process-bytes screen bytes)
                    (setf notifications (screen-drain-notification-queue screen)))
    (dolist (notification notifications)
      (pane-record-notification pane (car notification) (cdr notification)))
    (%drain-response-queue pane screen)))
