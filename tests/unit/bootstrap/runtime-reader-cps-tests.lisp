(in-package #:nerimux/test)

(describe "runtime-suite"

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

  (it "runtime-reader-idle-wait-allows-concurrent-pane-close"
    (let ((pane (make-pane :id 1 :fd 7 :pid 4321 :screen (make-screen 10 3)))
          (entered (sb-thread:make-semaphore))
          (release (sb-thread:make-semaphore))
          (closed (sb-thread:make-semaphore))
          (reader nil)
          (closer nil)
          (reader-error nil)
          (close-error nil)
          (next nil)
          (selected nil)
          (close-arguments nil)
          (waits 0))
      (flet ((wait-at-idle ()
               (incf waits)
               (sb-thread:signal-semaphore entered)
               (sb-thread:wait-on-semaphore release)))
        (with-stubbed-fdefinition
            ((nerimux::%reader-idle-wait #'wait-at-idle)
             (nerimux/pty:select-fds
              (lambda (fds timeout-us)
                (setf selected fds)
                (when (plusp timeout-us) (wait-at-idle))
                nil)))
          (unwind-protect
               (progn
                 (setf reader
                       (sb-thread:make-thread
                        (lambda ()
                          (handler-case
                              (setf next (nerimux::reader-idle-state pane))
                            (error (condition) (setf reader-error condition))))))
                 (expect (sb-thread:wait-on-semaphore entered :timeout 5))
                 (expect (= 1 waits))
                 (expect (equal '(7) selected))
                 (setf closer
                       (sb-thread:make-thread
                        (lambda ()
                          (handler-case
                              (let ((nerimux/ports:*close-pty*
                                      (lambda (fd pid)
                                        (setf close-arguments (list fd pid))
                                        (values 0 :exited))))
                                (nerimux/commands:close-pane-pty pane))
                            (error (condition) (setf close-error condition)))
                          (sb-thread:signal-semaphore closed))))
                 (expect (sb-thread:wait-on-semaphore closed :timeout 5))
                 (expect (null close-error))
                 (expect (equal '(7 4321) close-arguments))
                 (expect (= -1 (pane-fd pane)))
                 (expect (= -1 (pane-pid pane)))
                 (expect (nerimux/pane:pane-process-exited-p pane)))
            (sb-thread:signal-semaphore release)
            (when reader (sb-thread:join-thread reader :timeout 5))
            (when closer (sb-thread:join-thread closer :timeout 5)))
          (expect (null reader-error))
          (expect (eq #'nerimux::reader-idle-state next))))))

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
      (expect (zerop calls))))

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
                (push bytes fed)
                (when (find 7 bytes)
                  (setf (nerimux/terminal/types:screen-bell-pending
                         (nerimux/pane:pane-screen received-pane))
                        t))))
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

  (it "reader-eof-state-records-child-exit-status"
    (dolist (case '((17 :exited 17 nil)
                    (9 :signaled nil 9)))
      (destructuring-bind (code kind expected-status expected-signal) case
        (let ((pane (make-pane :id 1 :fd 7 :pid 4321
                               :screen (make-screen 10 3)))
            (observed-status :unset)
            (observed-signal :unset)
            (dirty 0))
        (with-stubbed-fdefinition
            ((nerimux/ports:close-pty
              (lambda (fd pid)
                (declare (ignore fd pid))
                (values code kind)))
             (nerimux/pane:pane-mark-process-exit
              (lambda (received-pane &key status signal)
                (declare (ignore received-pane))
                (setf (values observed-status observed-signal)
                      (values status signal))))
             (nerimux::%mark-dirty
              (lambda ()
                (incf dirty))))
          (nerimux::reader-eof-state pane))
        (expect (eql expected-status observed-status))
        (expect (eql expected-signal observed-signal))
          (expect (= 1 dirty))))))

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
      (expect (eql 7 observed-fd))
      (expect (eql 4321 observed-pid))
      (expect (eql -1 fd-at-close))
      (expect (eql -1 pid-at-close))
      (expect (eql -1 (pane-fd pane)))
      (expect (eql -1 (pane-pid pane)))))

  (it "workspace-agent-stop-close-retires-identifiers-once"
    (let ((pane (make-pane :id 1 :fd 7 :pid 4321 :agent-kind :codex
                           :screen (make-screen 10 3)))
          (worktree (nerimux/workspace-model:make-worktree :id "eof"))
          (calls 0))
      (nerimux/pane:worktree-add-pane worktree pane)
      (with-stubbed-fdefinition
          ((nerimux/ports:close-pty
            (lambda (fd pid)
              (declare (ignore fd pid))
              (incf calls)
              (expect (eq :running (nerimux/pane:worktree-agent-state worktree)))
              (expect (not (nerimux/pane:pane-process-exited-p pane)))
              (values 0 :exited))))
        (nerimux::reader-eof-state pane)
        (nerimux/commands:close-pane-pty pane))
      (expect (= 1 calls))
      (expect (eq :exited (nerimux/pane:worktree-agent-state worktree)))
      (expect (eql -1 (pane-fd pane)))
      (expect (eql -1 (pane-pid pane)))))

  (it "workspace-agent-stop-old-reader-cannot-touch-new-generation"
    (let* ((pane (make-pane :id 1 :fd 7 :pid 4321 :screen (make-screen 10 3)))
           (nerimux::*reader-process-generation*
             (nerimux/pane:pane-process-generation pane)))
      (setf (nerimux/pane:pane-process-generation pane) (list nil)
            (pane-fd pane) 8 (pane-pid pane) 4322)
      (with-stubbed-fdefinition
          ((nerimux/pty:select-fds (lambda (&rest args)
                                   (declare (ignore args)) (error "stale select")))
           (nerimux/pty:pty-read-blocking-into
             (lambda (&rest args) (declare (ignore args)) (error "stale read")))
           (nerimux/ports:close-pty
             (lambda (&rest args) (declare (ignore args)) (error "stale close"))))
        (expect (null (nerimux::reader-idle-state pane)))
        (expect (null (nerimux::reader-reading-state pane)))
        (expect (null (nerimux::reader-eof-state pane))))
      (expect (= 8 (pane-fd pane)))
      (expect (= 4322 (pane-pid pane)))
      (expect (not (nerimux/pane:pane-process-exited-p pane)))))

  (it "pane-retired-keeps-a-matching-reader-generation-live"
    (let* ((pane (make-pane :id 1 :fd 7 :pid -1 :screen (make-screen 10 3)))
           (generation (nerimux/pane:pane-process-generation pane)))
      (let ((nerimux::*reader-process-generation* generation))
        (expect (null (nerimux::%pane-retired-p pane))))))

  (it "run-reader-states-exits-when-running-nil"
    (with-dead-pane (pane)
      (let* ((nerimux::*running* nil)
             (boom (lambda (_p)
                     (declare (ignore _p))
                     (error "state function called despite *running*=NIL"))))
        (finishes (nerimux::%run-reader-states pane boom)
                  "%run-reader-states must exit immediately when *running* is NIL")))))
