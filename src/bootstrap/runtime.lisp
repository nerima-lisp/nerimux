(in-package #:nerimux)

;;;; Runtime state and per-pane I/O threading.
;;;;
;;;; Threading model:
;;;;   * One reader thread per pane: blocking read(PTY fd) -> pane-feed ->
;;;;     screen update -> sets *dirty* T.
;;;;   * Main thread (see events.lisp): select(stdin, 50 ms) -> key dispatch or
;;;;     PTY forward -> render when *dirty*.
;;;;
;;;; PTY children may be spawned while reader/status threads are active, so
;;;; teardown must reliably join background threads and close pane processes.

;;; -- Peer I/O failure type --------------------------------------------------

(deftype peer-io-failure ()
  "Everything a read or write against a peer can signal that a caller is
   expected to contain rather than die on.

   This exists as ONE name because the knowledge it encodes is easy to get
   wrong in the same way twice: SB-EXT:TIMEOUT is a SERIOUS-CONDITION and is
   deliberately NOT an ERROR, so the obvious (ERROR ...) clause reads as if
   it catches everything and silently does not.  SEND-FRAME
   (infrastructure/net/transport.lisp) documents itself as signalling exactly
   that when a peer is too slow, and PTY-WRITE does the same for a stuck
   pane, so every handler around either one needs both.

   Naming it once means a site that gets this wrong is missing a name a
   reader can look up, rather than silently under-matching a hand-written
   clause list.  WITH-LOOP-SAFE-ERROR already had the ERROR-only version of
   this bug, and its own comment records that the correct clause was
   accidentally disabled once before.

   Lives HERE, in the first file of the BOOTSTRAP-RUNTIME module, rather
   than in server.lisp where it started: nerimux.asd loads BOOTSTRAP-RUNTIME
   before BOOTSTRAP-SERVER, so a definition in server.lisp is not available
   to runtime-reader.lisp -- and the reader thread is precisely where an
   escaping SB-EXT:TIMEOUT is most dangerous, because an unhandled condition
   on a non-main thread takes the whole process down under
   --disable-debugger, not just that thread.

   Deliberately does NOT include STORAGE-CONDITION: heap exhaustion must stay
   fatal, not become a per-client, per-frame retry."
  '(or error sb-ext:timeout))

;;; -- Shared state -----------------------------------------------------------

(defvar *dirty*   t   "Set by reader threads; cleared by the main render step.")
(defvar *running* t   "Loop sentinel; set nil by :detach command.")
(defvar *resize-pending* nil
  "Set by the SIGWINCH handler; the event loop relayouts once and clears it.")
(defvar *term-rows* 24
  "Current terminal height in rows; updated on SIGWINCH and at startup.
   Used by the renderer, pane-split, and resize logic throughout the codebase.")
(defvar *term-cols* 80
  "Current terminal width in columns; updated on SIGWINCH and at startup.
   Used by the renderer, pane-split, and resize logic throughout the codebase.")
(defvar *server-sessions* nil
  "Alist mapping session-name (string) to session object for the running server.")
(defun %mark-dirty ()
  "Set the shared redraw flag."
  (setf *dirty* t))

;;; -- Named constants --------------------------------------------------------

(defconstant +reader-thread-join-timeout+ 10
  "Seconds (real number) to wait for a PTY reader thread to terminate before
   giving up.")

(defun %join-thread-with-timeout (thread &optional (timeout +reader-thread-join-timeout+))
  "Join THREAD, waiting at most TIMEOUT seconds.

   SB-THREAD:JOIN-THREAD is called directly rather than through
   CL-CONCURRENT-KIT:JOIN-THREAD only because there is nothing to gain from the
   wrapper here: it forwards :TIMEOUT to this same call.  Signals
   SB-THREAD:JOIN-THREAD-ERROR when the deadline passes or THREAD aborted;
   callers that treat a stuck reader as survivable wrap this in IGNORE-ERRORS.

   This used to carry a #-SBCL polling fallback for implementations whose
   JOIN-THREAD takes no timeout.  It was already incoherent — the #+SBCL branch
   above it made the function SBCL-only in practice — and ADR-0048 makes the
   whole org SBCL-only, so the dead branch is gone rather than conditionalized."
  (sb-thread:join-thread thread :timeout timeout))

(defconstant +wait-for-channel-timeout+ 30
  "Seconds before wait-for-channel gives up waiting for a signal.
   A bounded wait prevents indefinite blocking when signal-channel is
   never called (e.g., after an unexpected server shutdown).")

;;; -- Wait-for channel synchronization ----------------------------------------

(defparameter *wait-channels* (make-hash-table :test #'equal)
  "Maps channel-name string to a plist (:lock lock :cv cv :locked bool).")

(defmacro with-channel-plist ((lk cv ch) &body body)
  "Bind LK and CV to the :lock and :cv fields of the channel plist CH."
  (let ((ch-var (gensym "CH")))
    `(let* ((,ch-var ,ch)
            (,lk (getf ,ch-var :lock))
            (,cv (getf ,ch-var :cv)))
       ,@body)))

(defun %ensure-channel (name)
  "Return the plist for channel NAME, creating it if absent."
  (or (gethash name *wait-channels*)
      (let* ((lk (make-lock :name (format nil "wf-~A" name)))
             (cv (make-condition-variable :name (format nil "wf-cv-~A" name)))
             (ch (list :lock lk :cv cv :locked nil)))
        (setf (gethash name *wait-channels*) ch)
        ch)))

(defun wait-for-channel (name)
  "Block the calling thread until channel NAME is signaled, or until
   +wait-for-channel-timeout+ seconds elapse.  Returns T if signaled, NIL
   on timeout.  A bounded wait prevents indefinite blocking when the
   corresponding signal-channel is never called."
  (with-channel-plist (lk cv (%ensure-channel name))
    (with-lock-held (lk)
      (condition-wait cv lk :timeout +wait-for-channel-timeout+))))

(defun signal-channel (name)
  "Signal all threads blocked on channel NAME."
  (let ((ch (%ensure-channel name)))
    (unless (getf ch :locked)
      (with-channel-plist (lk cv ch)
        (with-lock-held (lk)
          (condition-notify cv))))))

(defun %set-channel-locked (name locked-p)
  "Set the :locked flag on channel NAME."
  (let ((ch (%ensure-channel name)))
    (setf (getf ch :locked) locked-p)))

(defun lock-channel (name)
  "Lock channel NAME so signal-channel is suppressed (a no-op) until unlocked.
   While a channel is locked, any call to signal-channel for the same NAME
   checks the :locked flag and skips the condition-notify entirely.  This
   allows callers to temporarily block notifications without losing them
   permanently — the channel is not destroyed, only silenced."
  (%set-channel-locked name t))

(defun unlock-channel (name)
  "Unlock channel NAME, allowing subsequent signal-channel calls to notify waiters.
   Paired with lock-channel: once unlocked, signal-channel will again call
   condition-notify on the channel's condition variable.  Does not retroactively
   deliver signals that were suppressed while the channel was locked."
  (%set-channel-locked name nil))

(defun %cap-list (list limit)
  "Return LIST truncated to at most LIMIT elements; returns LIST unchanged when
   it already fits."
  (if (> (length list) limit) (subseq list 0 limit) list))

;;; -- SIGWINCH ---------------------------------------------------------------

(defun install-sigwinch-handler ()
  "Arm SIGWINCH so terminal resizes flag a one-shot relayout."
  (sb-sys:enable-interrupt
   sb-unix:sigwinch
   (lambda (&rest ignored)
     (declare (ignore ignored))
     (setf *resize-pending* t
           *dirty*           t))))
