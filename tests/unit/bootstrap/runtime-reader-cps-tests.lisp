(in-package #:nerimux/test)

;;;; reader CPS state machine contracts
(describe "runtime-suite"

  ;; All CPS reader state machine functions are defined.  R2.6 removed the
  ;; remain-on-exit parking state (#'reader-remain-on-exit-state) along with
  ;; the option that used to select it, so idle/reading/eof are the complete
  ;; state set now.
  (it "reader-state-functions-are-all-fbound"
    (dolist (sym '(nerimux::reader-idle-state
                   nerimux::reader-reading-state
                   nerimux::reader-eof-state
                   nerimux::%run-reader-states
                   nerimux::start-reader-thread
                   nerimux::install-sigwinch-handler))
      (expect (fboundp sym))))

  (it "reader-idle-state-follows-pty-readiness"
    (let ((pane (make-pane :id 1 :fd 7 :pid -1 :screen (make-screen 10 3)))
          (calls 0))
      (with-stubbed-fdefinition
          ((nerimux/pty:select-fds
            (lambda (fds timeout-us)
              (declare (ignore timeout-us))
              (incf calls)
              (when (= 7 (first fds)) fds))))
        (expect (eq #'nerimux::reader-reading-state
                    (nerimux::reader-idle-state pane))))
      (expect (= 1 calls))))

  (it "reader-idle-state-keeps-polling-when-pty-is-not-ready"
    (let ((pane (make-pane :id 1 :fd 7 :pid -1 :screen (make-screen 10 3))))
      (with-stubbed-fdefinition
          ((nerimux/pty:select-fds
            (lambda (fds timeout-us)
              (declare (ignore fds timeout-us))
              nil)))
        (expect (eq #'nerimux::reader-idle-state
                    (nerimux::reader-idle-state pane))))))

  ;; This case previously asserted the OPPOSITE: that a pane with fd -1 still
  ;; returned #'reader-idle-state, i.e. kept polling forever.  It was pinning a
  ;; defect rather than a contract.  Nothing stops a single pane's reader
  ;; except this check -- %run-reader-states loops on the GLOBAL *running* --
  ;; so a pane closed while the server keeps serving left a thread polling a
  ;; dead fd every 50ms for the life of the process, and then acting on
  ;; whatever the OS reassigned that number to.  Flipped deliberately.
  (it "reader-idle-state-stops-when-the-pane-is-retired"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 10 3)))
          (calls 0))
      (with-stubbed-fdefinition
          ((nerimux/pty:select-fds
            (lambda (fds timeout-us)
              (declare (ignore fds timeout-us))
              (incf calls)
              nil)))
        (expect (null (nerimux::reader-idle-state pane))))
      ;; Not merely "returned NIL": it must not have touched the descriptor at
      ;; all.  select-fds maps a closed fd's EBADF to NIL, so reaching it would
      ;; look identical from the return value alone.
      (expect (zerop calls))))

  ;; The fd can be cleared between the select that reported it readable and
  ;; the read, so reading-state carries the same guard.
  (it "reader-reading-state-stops-when-the-pane-is-retired"
    (let ((pane (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 10 3)))
          (reads 0))
      (with-stubbed-fdefinition
          ((nerimux/pty:pty-read-blocking-into
            (lambda (fd buffer)
              (declare (ignore fd buffer))
              (incf reads)
              nil)))
        (expect (null (nerimux::reader-reading-state pane))))
      (expect (zerop reads))))

  (it "reader-reading-state-handles-empty-and-nonempty-pty-reads"
    (let ((pane (make-pane :id 1 :fd 7 :pid -1 :screen (make-screen 10 3)))
          (payloads (list #(65) #(65 7) nil))
          (fed nil)
          (outputs nil)
          (bells 0)
          (dirty 0))
      (let ((nerimux::*reader-scratch-buffer* (make-array 16
                                                           :element-type '(unsigned-byte 8))))
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-read-blocking-into
              (lambda (fd buffer)
                (declare (ignore fd buffer))
                (pop payloads)))
             (nerimux/pane:pane-feed
              (lambda (received-pane bytes)
                (declare (ignore received-pane))
                (push bytes fed)))
             (nerimux/pane:pane-mark-output
              (lambda (received-pane bytes)
                (declare (ignore received-pane))
                (push bytes outputs)))
             (nerimux/pane:pane-mark-bell
              (lambda (received-pane)
                (declare (ignore received-pane))
                (incf bells)))
             (nerimux::%mark-dirty
              (lambda ()
                (incf dirty))))
          (expect (eq #'nerimux::reader-idle-state
                      (nerimux::reader-reading-state pane)))
          (expect (eq #'nerimux::reader-idle-state
                      (nerimux::reader-reading-state pane)))
          (expect (eq #'nerimux::reader-eof-state
                      (nerimux::reader-reading-state pane))))
        (expect (= 2 (length fed)))
        (expect (= 2 (length outputs)))
        (expect (= 1 bells))
        (expect (= 2 dirty)))))

  (it "reader-reading-state-contains-peer-io-failure"
    (let ((pane (make-pane :id 1 :fd 7 :pid -1 :screen (make-screen 10 3)))
          (payloads (list #(65) nil))
          (feed-calls 0)
          (outputs 0)
          (dirty 0))
      (let ((nerimux::*reader-scratch-buffer* (make-array 16
                                                           :element-type '(unsigned-byte 8))))
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-read-blocking-into
              (lambda (fd buffer)
                (declare (ignore fd buffer))
                (pop payloads)))
             (nerimux/pane:pane-feed
              (lambda (received-pane bytes)
                (declare (ignore received-pane bytes))
                (incf feed-calls)
                (error 'nerimux::peer-io-failure)))
             (nerimux/pane:pane-mark-output
              (lambda (received-pane bytes)
                (declare (ignore received-pane bytes))
                (incf outputs)))
             (nerimux::%mark-dirty
              (lambda ()
                (incf dirty))))
          (expect (eq #'nerimux::reader-idle-state
                      (nerimux::reader-reading-state pane)))
          (expect (eq #'nerimux::reader-eof-state
                      (nerimux::reader-reading-state pane))))
        (expect (= 1 feed-calls))
        (expect (= 1 outputs))
        (expect (= 1 dirty)))))

  (it "run-reader-states-executes-the-current-state-before-stopping"
    (with-dead-pane (pane)
      (let ((calls 0)
            (nerimux::*running* t))
        (nerimux::%run-reader-states
         pane
         (lambda (received-pane)
           (declare (ignore received-pane))
           (incf calls)
           (setf nerimux::*running* nil)
           nil))
        (expect (= 1 calls)))))

  (it "start-reader-thread-installs-a-reader-loop"
    (with-dead-pane (pane)
      (let ((reader-function nil)
            (nerimux::*running* nil))
        (with-stubbed-fdefinition
            ((cl-concurrent-kit:make-thread
              (lambda (function &rest arguments)
                (declare (ignore arguments))
                (setf reader-function function)
                :reader-thread)))
          (expect (eq :reader-thread
                      (nerimux::start-reader-thread pane)))
          (expect (functionp reader-function))
          (finishes (funcall reader-function))))))

  (it "stop-reader-threads-ignores-a-thread-that-cannot-be-joined"
    (let ((nerimux::*running* t)
          (joined nil))
      (with-stubbed-fdefinition
          ((nerimux::%join-thread-with-timeout
            (lambda (thread timeout)
              (declare (ignore timeout))
              (setf joined thread)
              (error 'sb-thread:join-thread-error))))
        (finishes (nerimux::stop-reader-threads '(:reader-thread))))
      (expect (null nerimux::*running*))
      (expect (eq :reader-thread joined))))

  ;; ── retire-pane-pty ─────────────────────────────────────────────────────────
  ;;
  ;; The ORDER is the safety property, not just the end state.  The reader
  ;; thread re-reads (pane-fd pane) on every poll from another thread, so if
  ;; the close landed before the -1 became visible there would be a window in
  ;; which the reader sees a positive fd that is already closed -- and once
  ;; the OS reuses that number, reader-eof-state's (> (pane-fd pane) 0) guard
  ;; still passes on the stale value and closes whatever *pty-processes* now
  ;; has under it, which is a different, live pane's shell.
  ;;
  ;; Asserting the slots afterwards would pass either way.  This observes the
  ;; slot values AT THE MOMENT close-pty is called, which is the only way to
  ;; tell the two orderings apart.
  (it "retire-pane-pty-clears-the-pane-before-closing-the-descriptor"
    (let ((pane (make-pane :id 1 :fd 7 :pid 4321 :screen (make-screen 10 3)))
          (observed-fd :never-called)
          (observed-pid :never-called)
          (fd-at-close nil)
          (pid-at-close nil))
      (with-stubbed-fdefinition
          ((nerimux/ports:close-pty
            (lambda (fd pid)
              (setf observed-fd fd
                    observed-pid pid
                    fd-at-close (pane-fd pane)
                    pid-at-close (pane-pid pane)))))
        (nerimux/commands:retire-pane-pty pane))
      ;; close-pty still receives the REAL descriptor and pid -- clearing first
      ;; must not turn the close into a no-op on -1, which would leak the fd.
      (expect (eql 7 observed-fd))
      (expect (eql 4321 observed-pid))
      ;; ...while the pane already read as retired at that instant.
      (expect (eql -1 fd-at-close))
      (expect (eql -1 pid-at-close))
      (expect (eql -1 (pane-fd pane)))
      (expect (eql -1 (pane-pid pane)))))

  ;; close-pane-pty is the other half of the pair and must NOT retire: the
  ;; --force shutdown path closes every pane, waits out the SIGHUP grace
  ;; period, then reads pane-pid back to escalate to SIGKILL.  Clearing the
  ;; pid there would send that escalation at nothing and orphan the children.
  (it "close-pane-pty-leaves-the-pid-for-sigkill-escalation"
    (let ((pane (make-pane :id 1 :fd 7 :pid 4321 :screen (make-screen 10 3))))
      (with-stubbed-fdefinition
          ((nerimux/ports:close-pty
            (lambda (fd pid) (declare (ignore fd pid)) nil)))
        (nerimux/commands:close-pane-pty pane))
      (expect (eql 7 (pane-fd pane)))
      (expect (eql 4321 (pane-pid pane)))))

  ;; %run-reader-states exits immediately when *running* is NIL, even
  ;; given a non-NIL initial state (loop while *running*).
  (it "run-reader-states-exits-when-running-nil"
    (with-dead-pane (pane)
      (let* ((nerimux::*running* nil)
             (boom (lambda (_p)
                     (declare (ignore _p))
                     (error "state function called despite *running*=NIL"))))
        (finishes (nerimux::%run-reader-states pane boom)
                  "%run-reader-states must exit immediately when *running* is NIL")))))
