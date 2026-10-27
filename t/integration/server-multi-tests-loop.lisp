(in-package #:nerimux/test)

(defun %make-waiting-agent-fixture ()
  (multiple-value-bind (session window ignored-pane)
      (make-single-pane-session)
    (declare (ignore ignored-pane))
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo" :specification "github.com/team/repo"
              :organization organization))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt" :branch "feature/waiting" :repository repository))
           (agent (make-pane :id 99 :fd -1 :agent-kind :codex)))
      (setf (window-panes window) (list agent)
            (pane-window agent) window)
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (nerimux/pane:worktree-add-pane worktree agent)
      (values session worktree agent))))

(describe "server-multi-suite"


  (it "accept-pending-connection-registers-client-when-listener-ready"
    (progn
      (with-test-listener (listener path (%test-socket-path "accept-helper") :backlog 4)
        (let* ((listener-fd (nerimux/net:socket-fd listener))
               (nerimux::*clients* nil)
               (peer (nerimux/net:connect-to path)))
          (unwind-protect
               (progn
                 (nerimux/pty:select-fds (list listener-fd) 1000000)
                 (nerimux::%accept-pending-connection listener listener-fd (list listener-fd))
                 (expect (= 1 (length nerimux::*clients*))))
            (ignore-errors (nerimux/net:close-socket peer)))))))

  (it "accept-pending-connection-noop-when-listener-not-ready"
    (progn
      (with-test-listener (listener path (%test-socket-path "accept-helper-noop") :backlog 4)
        (let ((listener-fd (nerimux/net:socket-fd listener))
              (nerimux::*clients* nil))
          (nerimux::%accept-pending-connection listener listener-fd nil)
          (expect (null nerimux::*clients*))))))

  (it "dispatch-ready-clients-skips-clients-not-in-ready-set"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-fd conn) 4242)
        (expect (null (nerimux::%dispatch-ready-clients s nil)))
        (expect (equal (list conn) nerimux::*clients*)))))

  (it "dispatch-ready-clients-drops-client-on-eof"
    (progn
      (with-fake-session (s)
        (with-test-listener (listener path (%test-socket-path "dispatch-helper") :backlog 4)
          (let* ((client      (nerimux/net:connect-to path))
                 (server-sock (nerimux/net:accept-connection listener))
                 (nerimux::*clients* nil))
            (when server-sock
              (let ((conn (nerimux::%add-client server-sock)))
                (nerimux/net:close-socket client)
                (let ((ready (list (nerimux::client-conn-fd conn))))
                  (expect (null (nerimux::%dispatch-ready-clients s ready)))
                  (expect (null nerimux::*clients*)))))))))) (it "dispatch-buffered-client-messages-stops-on-quit"
  (let ((conn (%make-test-conn)))
    (with-stubbed-fdefinition
        ((nerimux::%read-and-dispatch-client-message
          (lambda (session client &key max-bytes)
            (declare (ignore session client max-bytes))
            (values :quit :frame 5))))
      (expect (eq :quit
                  (nerimux::%dispatch-buffered-client-messages
                   :session conn)))))) (it "dispatch-buffered-client-messages-stops-on-would-block"
    (let ((conn (%make-test-conn)))
      (with-stubbed-fdefinition
          ((nerimux::%read-and-dispatch-client-message
            (lambda (session client &key max-bytes)
              (declare (ignore session client max-bytes))
              (values nil :would-block 0))))
        (expect (null
                 (nerimux::%dispatch-buffered-client-messages
                  :session conn)))))) (it "dispatch-ready-clients-round-robins-with-frame-and-byte-quotas"
  (let* ((conn-a (%make-test-conn))
         (conn-b (%make-test-conn))
         (counts (make-hash-table :test #'eq))
         (round-first nil)
         (nerimux::*clients* (list conn-a conn-b))
         (nerimux::*client-read-round-robin-cursor* nil))
    (setf (nerimux::client-conn-fd conn-a) 8
          (nerimux::client-conn-fd conn-b) 9
          (nerimux::client-conn-socket conn-a) :a
          (nerimux::client-conn-socket conn-b) :b)
    (with-stubbed-fdefinition
        ((nerimux/transport:read-frame-ready
          (lambda (reader socket &key max-bytes)
            (declare (ignore reader max-bytes))
            (let ((count (incf (gethash socket counts 0))))
              (when (member count (list 1 17))
                (push socket round-first))
              (values 1 #() :frame))))
         (nerimux::%handle-multi-client-message
          (lambda (type payload session conn)
            (declare (ignore type payload session conn)))))
      (expect (null (nerimux::%dispatch-ready-clients :session (list 8 9))))
      (expect (= 16 (gethash :a counts 0)))
      (expect (= 16 (gethash :b counts 0)))
      (expect (equal (list :a :b) (nreverse round-first)))
      (setf round-first nil)
      (expect (null (nerimux::%dispatch-ready-clients :session (list 8 9))))
      (expect (equal (list :b :a) (nreverse round-first))))
    (let* ((conn (%make-test-conn))
           (budgets nil)
           (nerimux::*clients* (list conn))
           (nerimux::*client-read-round-robin-cursor* nil))
      (setf (nerimux::client-conn-fd conn) 10
            (nerimux::client-conn-socket conn) :byte-client)
      (with-stubbed-fdefinition
          ((nerimux/transport:read-frame-ready
            (lambda (reader socket &key max-bytes)
              (declare (ignore socket))
              (push max-bytes budgets)
              (if (= (length budgets) 1)
                  (values 1 (make-array 50000
                                        :element-type '(unsigned-byte 8))
                          :frame)
                  (progn
                    (setf (nerimux/transport::frame-reader-offset reader)
                          max-bytes)
                    (values nil nil :pending)))))
           (nerimux::%handle-multi-client-message
            (lambda (type payload session client)
              (declare (ignore type payload session client)))))
        (expect
         (null
          (nerimux::%dispatch-ready-clients :session (list 10))))
        (expect (equal (list 65536 15531) (nreverse budgets)))
        (expect
         (= 15531
            (nerimux/transport::frame-reader-offset
             (nerimux::client-conn-frame-reader conn)))))))) (it "dispatch-ready-clients-returns-quit-when-a-client-requests-shutdown"
    (let* ((conn (%make-test-conn))
           (nerimux::*clients* (list conn)))
      (setf (nerimux::client-conn-fd conn) 4242)
      (with-stubbed-fdefinition
          ((nerimux::%dispatch-buffered-client-messages
            (lambda (session client)
              (declare (ignore session client))
              :quit)))
        (expect (eq :quit
                    (nerimux::%dispatch-ready-clients :session '(4242))))))) (it "dispatch-buffered-client-messages-stops-on-pending-input"
    (let* ((conn (%make-test-conn)))
      (with-stubbed-fdefinition
          ((nerimux::%read-and-dispatch-client-message
            (lambda (session client &key max-bytes)
              (declare (ignore session client max-bytes))
              (values nil :pending 5))))
        (expect (null
                 (nerimux::%dispatch-buffered-client-messages
                  :session conn)))))) (it "multi-serve-iteration-dispatches-input-before-output"
  (let* ((conn (%make-test-conn))
         (events nil)
         (reader-calls 0)
         (nerimux::*clients* (list conn))
         (nerimux::*dirty* nil)
         (nerimux::*server-termination-requested-p* nil)
         (nerimux::*client-read-round-robin-cursor* nil)
         (nerimux::*client-write-round-robin-cursor* nil))
    (setf (nerimux::client-conn-fd conn) 8
          (nerimux::client-conn-socket conn) :client)
    (nerimux::%queue-client-control-frame
     conn (nerimux/protocol:msg-reply "pending"))
    (with-stubbed-fdefinition
        ((nerimux::%drain-main-thread-callbacks
          (lambda () (push :callbacks events)))
         (nerimux::%workspace-job-tick
          (lambda () (push :jobs events)))
         (nerimux::%persist-runtime-state
          (lambda (session) (declare (ignore session))
            (push :persist events)))
         (nerimux::%schedule-client-render-frames
          (lambda (session &optional now)
            (declare (ignore session now))
            (push :render events)))
         (nerimux::%queue-session-control-output
          (lambda (session) (declare (ignore session))
            (push :control-queue events)))
         (nerimux::%handle-multi-client-message
          (lambda (type payload session client)
            (declare (ignore type payload session client))
            (push :dispatch events)))
         (nerimux/transport:read-frame-ready
          (lambda (reader socket &key max-bytes)
            (declare (ignore reader socket max-bytes))
            (incf reader-calls)
            (if (= reader-calls 1)
                (values 1 #() :frame)
                (values nil nil :would-block))))
         (nerimux::%advance-client-output
          (lambda (client &key max-bytes)
            (declare (ignore client))
            (expect (= 65536 max-bytes))
            (push :write events)
            (values :complete 5)))
         (nerimux/net::socket-fd
          (lambda (listener) (declare (ignore listener)) 7))
         (nerimux/pty::select-fds
          (lambda (read-fds timeout-us &key write-fds)
            (push (list :select read-fds write-fds) events)
            (expect (<= 0 timeout-us 50000))
            (values (list 8) (list 8)))))
      (expect (null (nerimux::%multi-serve-iteration :listener :session)))
      (expect
       (equal '(:select :dispatch :control-queue :write
                :callbacks :jobs :persist :render)
              (mapcar (lambda (event)
                        (if (and (consp event) (eq :select (first event)))
                            :select
                            event))
                      (nreverse events))))))) (it "multi-serve-iteration-refreshes-unstarted-render-after-input"
  (let* ((conn (%make-test-conn))
         (old-frame (nerimux/protocol:msg-frame "old geometry"))
         (latest-frame nil)
         (sent (make-array 0 :element-type (quote (unsigned-byte 8))))
         (nerimux::*clients* (list conn))
         (nerimux::*dirty* nil)
         (nerimux::*server-termination-requested-p* nil)
         (nerimux::*client-read-round-robin-cursor* nil)
         (nerimux::*client-write-round-robin-cursor* nil))
    (setf (nerimux::client-conn-fd conn) 8
          (nerimux::client-conn-socket conn) :client)
    (nerimux::%queue-client-render-state conn old-frame nil)
    (with-stubbed-fdefinition
        ((nerimux::%drain-main-thread-callbacks (lambda () nil))
         (nerimux::%workspace-job-tick (lambda () nil))
         (nerimux::%persist-runtime-state
          (lambda (session) (declare (ignore session))))
         (nerimux::%queue-session-control-output
          (lambda (session) (declare (ignore session))))
         (nerimux::%dispatch-ready-clients
          (lambda (session ready)
            (declare (ignore session ready))
            (setf (nerimux::client-conn-rows conn) 40
                  (nerimux::client-conn-cols conn) 100
                  (nerimux::client-conn-render-dirty-p conn) t)
            nil))
         (nerimux::%render-client-frame
          (lambda (session client)
            (declare (ignore session))
            (setf latest-frame
                  (nerimux/protocol:msg-frame
                   (format nil "geometry ~Dx~D"
                           (nerimux::client-conn-rows client)
                           (nerimux::client-conn-cols client))))))
         (sb-bsd-sockets:socket-send
          (lambda (socket buffer length &key dontwait nosignal)
            (declare (ignore socket dontwait nosignal))
            (setf sent
                  (concatenate (quote (vector (unsigned-byte 8)))
                               sent
                               (subseq buffer 0 length)))
            length))
         (nerimux/net::socket-fd
          (lambda (listener) (declare (ignore listener)) 7))
         (nerimux/pty::select-fds
          (lambda (read-fds timeout-us &key write-fds)
            (declare (ignore read-fds timeout-us write-fds))
            (values (list 8) (list 8)))))
      (expect (null (nerimux::%multi-serve-iteration :listener :session))))
    (expect latest-frame)
    (expect (equalp latest-frame sent))
    (expect (null (nerimux::client-conn-pending-render-state conn)))
    (expect (not (nerimux::client-conn-render-dirty-p conn))))) (it "multi-serve-iteration-refreshes-pending-render-after-shared-dirty-resize"
  (with-fake-session (session)
    (let* ((conn (%make-test-conn :rows 24 :cols 80))
           (resize-frame (nerimux/protocol:msg-resize 40 100))
           (old-frame (nerimux/protocol:msg-frame "geometry 24x80"))
           (latest-frame nil)
           (sent (make-array 0 :element-type (quote (unsigned-byte 8))))
           (read-calls 0)
           (nerimux::*clients* (list conn))
           (nerimux::*dirty* nil)
           (nerimux::*server-termination-requested-p* nil)
           (nerimux::*client-read-round-robin-cursor* nil)
           (nerimux::*client-write-round-robin-cursor* nil))
      (setf (nerimux::client-conn-fd conn) 8
            (nerimux::client-conn-socket conn) :client
            (nerimux::client-conn-render-dirty-p conn) nil)
      (nerimux::%queue-client-render-state conn old-frame nil)
      (with-stubbed-fdefinition
          ((nerimux::%drain-main-thread-callbacks (lambda () nil))
           (nerimux::%workspace-job-tick (lambda () nil))
           (nerimux::%persist-runtime-state
            (lambda (ignored-session) (declare (ignore ignored-session))))
           (nerimux::%queue-session-control-output
            (lambda (ignored-session) (declare (ignore ignored-session))))
           (nerimux/transport:read-frame-ready
            (lambda (reader socket &key max-bytes)
              (declare (ignore reader socket max-bytes))
              (incf read-calls)
              (if (= read-calls 1)
                  (multiple-value-bind (type payload)
                      (nerimux/protocol:decode-frame resize-frame)
                    (values type payload :frame))
                  (values nil nil :would-block))))
           (nerimux::%render-client-frame
            (lambda (ignored-session client)
              (declare (ignore ignored-session))
              (setf latest-frame
                    (nerimux/protocol:msg-frame
                     (format nil "geometry ~Dx~D"
                             (nerimux::client-conn-rows client)
                             (nerimux::client-conn-cols client))))))
           (sb-bsd-sockets:socket-send
            (lambda (socket buffer length &key dontwait nosignal)
              (declare (ignore socket dontwait nosignal))
              (setf sent
                    (concatenate (quote (vector (unsigned-byte 8)))
                                 sent
                                 (subseq buffer 0 length)))
              length))
           (nerimux/net::socket-fd
            (lambda (listener) (declare (ignore listener)) 7))
           (nerimux/pty::select-fds
            (lambda (read-fds timeout-us &key write-fds)
              (declare (ignore timeout-us))
              (expect (member 8 read-fds))
              (expect (member 8 write-fds))
              (values (list 8) (list 8)))))
        (expect (null (nerimux::%multi-serve-iteration :listener session))))
      (expect (= 40 (nerimux::client-conn-rows conn)))
      (expect (= 100 (nerimux::client-conn-cols conn)))
      (expect (= 2 read-calls))
      (expect latest-frame)
      (expect (equalp latest-frame sent))
      (expect (not (equalp old-frame sent)))))) (it "multi-serve-iteration-selects-only-pending-write-fds"
  (let* ((conn-a (%make-test-conn))
         (conn-b (%make-test-conn))
         (selected-read-fds nil)
         (selected-write-fds nil)
         (selected-timeout nil)
         (nerimux::*clients* (list conn-a conn-b))
         (nerimux::*dirty* nil)
         (nerimux::*server-termination-requested-p* nil)
         (nerimux::*client-read-round-robin-cursor* nil)
         (nerimux::*client-write-round-robin-cursor* nil))
    (setf (nerimux::client-conn-fd conn-a) 8
          (nerimux::client-conn-fd conn-b) 9)
    (nerimux::%queue-client-control-frame
     conn-a (nerimux/protocol:msg-reply "pending"))
    (with-stubbed-fdefinition
        ((nerimux::%drain-main-thread-callbacks (lambda () nil))
         (nerimux::%workspace-job-tick (lambda () nil))
         (nerimux::%persist-runtime-state
          (lambda (session) (declare (ignore session))))
         (nerimux::%queue-session-control-output
          (lambda (session) (declare (ignore session))))
         (nerimux::%schedule-client-render-frames
          (lambda (session &optional now) (declare (ignore session now))))
         (nerimux/net::socket-fd
          (lambda (listener) (declare (ignore listener)) 7))
         (nerimux/pty::select-fds
          (lambda (read-fds timeout-us &key write-fds)
            (setf selected-read-fds read-fds
                  selected-write-fds write-fds
                  selected-timeout timeout-us)
            (values nil nil))))
      (expect (null (nerimux::%multi-serve-iteration :listener :session))))
    (expect (equal (list 7 8 9) selected-read-fds))
    (expect (equal (list 8) selected-write-fds))
    (expect (<= 0 selected-timeout 50000)))) (it "run-multi-server-loop-stops-on-quit-and-drops-all-clients"
    (let ((events nil)
          (first-call t)
          (conn-a (%make-test-conn))
          (conn-b (%make-test-conn))
          (nerimux::*running* t))
      (let ((nerimux::*clients* (list conn-a conn-b)))
        (with-stubbed-fdefinition
            ((nerimux::%multi-serve-iteration
              (lambda (listener session)
                (declare (ignore listener session))
                (push :iterate events)
                (when first-call
                  (setf first-call nil)
                  :quit)))
             (nerimux::%drop-client
              (lambda (conn &key bye)
                (push (list :drop conn bye) events)
                (setf nerimux::*clients* (remove conn nerimux::*clients*)))))
          (expect (null (nerimux::%run-multi-server-loop :listener :session)))
          (expect (null nerimux::*running*))
          (expect (= 1 (count :iterate events)))
          (expect (equal (list :drop conn-a t)
                         (find-if (lambda (event)
                                    (and (consp event)
                                         (eq :drop (first event))
                                         (eq conn-a (second event))))
                                  events)))
          (expect (equal (list :drop conn-b t)
                         (find-if (lambda (event)
                                    (and (consp event)
                                         (eq :drop (first event))
                                         (eq conn-b (second event))))
                                  events)))))))
  (it "run-multi-server-loop-clears-client-after-blocked-output-drain"
    (let* ((conn (%make-test-conn))
           (advance-calls 0)
           (nerimux::*clients* (list conn))
           (nerimux::*running* t))
      (nerimux::%queue-client-control-frame
       conn (nerimux/protocol:msg-reply "pending"))
      (with-stubbed-fdefinition
          ((nerimux::%multi-serve-iteration
            (lambda (listener session)
              (declare (ignore listener session))
              :quit))
           (nerimux::%advance-client-output
            (lambda (client &key max-bytes)
              (declare (ignore client max-bytes))
              (incf advance-calls)
              (values :would-block 0))))
        (expect (null (nerimux::%run-multi-server-loop :listener :session))))
      (expect (= 1 advance-calls))
      (expect (null nerimux::*clients*))
      (expect (zerop (nerimux::client-conn-control-frame-bytes conn)))
      (expect (null (nerimux::client-conn-control-frame-head conn)))
      (expect (null (nerimux::client-conn-pending-render-state conn)))
      (expect (null (nerimux::client-conn-active-output-frame conn)))
      (expect (not (nerimux/transport:frame-writer-pending-p
                    (nerimux::client-conn-frame-writer conn))))))
) (it "run-multi-server-loop-continues-after-nil-iteration"
    (let ((calls 0)
          (nerimux::*running* t))
      (let ((nerimux::*clients* nil))
        (with-stubbed-fdefinition
            ((nerimux::%multi-serve-iteration
              (lambda (listener session)
                (declare (ignore listener session))
                (incf calls)
                (when (= calls 2)
                  :quit))))
          (expect (null (nerimux::%run-multi-server-loop :listener :session)))
          (expect (null nerimux::*running*))
          (expect (= 2 calls))))))

(describe "server-multi-agent-waiting-notifications"
  (it "continues-waiting-host-notifications-after-one-client-write-fails"
      (multiple-value-bind (session worktree agent)
          (%make-waiting-agent-fixture)
        (declare (ignore agent))
        (let* ((conn-a (%make-test-conn))
               (conn-b (%make-test-conn))
               (notified-streams nil)
               (nerimux::*clients* (list conn-a conn-b))
               (nerimux/ports:*notify-host*
                 (lambda (stream title body)
                   (declare (ignore title body))
                   (push stream notified-streams)
                   (when (eq stream (nerimux::client-conn-stream conn-a))
                     (error 'stream-error :stream stream)))))
          (nerimux/workspace-model:worktree-mark-waiting
           worktree "approval required" 100)
          (expect (finishes (nerimux::%notify-agent-waiting-hosts session)))
          (expect (= 2 (length notified-streams)))
          (expect (member (nerimux::client-conn-stream conn-b)
                          notified-streams :test #'eq))
          (expect
           (nerimux/workspace-model:worktree-waiting-host-notified-p worktree)))))

  (it "render-scheduling-throttles-and-coalesces-dirty-state"
  (let* ((conn (%make-test-conn))
         (first-frame (nerimux/protocol:msg-frame "first"))
         (latest-frame (nerimux/protocol:msg-frame "latest"))
         (render-count 0)
         (now 10000)
         (interval (nerimux::%client-render-interval-ticks))
         (nerimux::*clients* (list conn))
         (nerimux::*dirty* t))
    (with-stubbed-fdefinition
        ((nerimux::%render-client-frame
          (lambda (session client)
            (declare (ignore session client))
            (incf render-count)
            (if (= render-count 1) first-frame latest-frame))))
      (nerimux::%schedule-client-render-frames :session now)
      (expect (= 1 render-count))
      (expect
       (eq first-frame
           (first (nerimux::client-conn-pending-render-state conn))))
      (setf nerimux::*dirty* t)
      (nerimux::%schedule-client-render-frames :session (+ now (1- interval)))
      (expect (= 1 render-count))
      (expect (nerimux::client-conn-render-dirty-p conn))
      (expect
       (eq first-frame
           (first (nerimux::client-conn-pending-render-state conn))))
      (nerimux::%schedule-client-render-frames :session (+ now interval))
      (expect (= 2 render-count))
      (expect
       (eq latest-frame
           (first (nerimux::client-conn-pending-render-state conn))))
      (expect (= (+ now interval)
                 (nerimux::client-conn-last-render-at conn)))
      (expect (null (nerimux::client-conn-active-output-frame conn))))))

  (it "client-output-writes-control-frames-in-fifo-order"
    (let* ((conn (%make-test-conn))
           (first-frame (nerimux/protocol:msg-reply "first"))
           (second-frame (nerimux/protocol:msg-reply "second"))
           (sent (make-array 0 :element-type '(unsigned-byte 8)))
           (nerimux::*clients* (list conn)))
      (expect (eq :queued
                  (nerimux::%queue-client-control-frame conn first-frame)))
      (expect (eq :queued
                  (nerimux::%queue-client-control-frame conn second-frame)))
      (with-stubbed-fdefinition
          ((sb-bsd-sockets:socket-send
            (lambda (socket buffer length &key dontwait nosignal)
              (declare (ignore socket dontwait nosignal))
              (setf sent
                    (concatenate '(vector (unsigned-byte 8))
                                 sent
                                 (subseq buffer 0 length)))
              length)))
        (multiple-value-bind (status bytes-written)
            (nerimux::%advance-client-output conn)
          (expect (eq :complete status))
          (expect (= (length first-frame) bytes-written)))
        (multiple-value-bind (status bytes-written)
            (nerimux::%advance-client-output conn)
          (expect (eq :complete status))
          (expect (= (length second-frame) bytes-written))))
      (expect (equalp (concatenate '(vector (unsigned-byte 8))
                                   first-frame second-frame)
                      sent))
      (expect (zerop (nerimux::client-conn-control-frame-bytes conn)))))
  (it "client-output-control-queue-overflow-drops-and-clears-client"
    (let* ((conn (%make-test-conn))
           (in-flight-frame (nerimux/protocol:msg-reply "in-flight"))
           (queued-frame (nerimux/protocol:msg-reply "queued"))
           (overflow-frame (nerimux/protocol:msg-reply "overflow"))
           (writer (nerimux::client-conn-frame-writer conn))
           (nerimux::*clients* (list conn)))
      (expect (eq :queued
                  (nerimux::%queue-client-control-frame conn in-flight-frame)))
      (expect (eq :queued
                  (nerimux::%queue-client-control-frame conn queued-frame)))
      (expect (eq :started
                  (nerimux::%start-client-output-frame conn)))
      (expect (nerimux/transport:frame-writer-pending-p writer))
      (expect (nerimux::client-conn-control-frame-head conn))
      (setf (nerimux::client-conn-control-frame-bytes conn)
            nerimux::+max-client-control-frame-bytes+)
      (expect (eq :overflow
                  (nerimux::%queue-client-control-frame conn overflow-frame)))
      (expect (null nerimux::*clients*))
      (expect (zerop (nerimux::client-conn-control-frame-bytes conn)))
      (expect (null (nerimux::client-conn-control-frame-head conn)))
      (expect (null (nerimux::client-conn-control-frame-tail conn)))
      (expect (null (nerimux::client-conn-active-output-kind conn)))
      (expect (null (nerimux::client-conn-active-output-frame conn)))
      (expect (not (eq writer (nerimux::client-conn-frame-writer conn))))
      (expect (not (nerimux/transport:frame-writer-pending-p
                    (nerimux::client-conn-frame-writer conn))))))

  (it "client-output-coalesces-unstarted-render-states"
    (let* ((conn (%make-test-conn))
           (first-frame (nerimux/protocol:msg-frame "first"))
           (second-frame (nerimux/protocol:msg-frame "second"))
           (latest-frame (nerimux/protocol:msg-frame "latest")))
      (expect (eq :queued
                  (nerimux::%queue-client-render-state conn first-frame nil)))
      (expect (eq :queued
                  (nerimux::%queue-client-render-state conn second-frame nil)))
      (expect (eq :queued
                  (nerimux::%queue-client-render-state conn latest-frame nil)))
      (expect (eq latest-frame
                  (first (nerimux::client-conn-pending-render-state conn))))
      (expect (null (nerimux::client-conn-active-output-kind conn)))
      (expect (= (length latest-frame)
                 (nerimux::%client-output-buffered-bytes conn)))))

  (it "client-output-advances-row-baseline-only-after-frame-completes"
    (let* ((conn (%make-test-conn))
           (first-frame (nerimux/protocol:msg-frame "first"))
           (second-frame (nerimux/protocol:msg-frame "second"))
           (key (nerimux::%client-row-frame-key conn))
           (first-candidate (list first-frame key :first-snapshot))
           (second-candidate (list second-frame key :second-snapshot))
           (sent (make-array 0 :element-type '(unsigned-byte 8)))
           (calls 0))
      (expect (eq :queued
                  (nerimux::%queue-client-render-state
                   conn first-frame first-candidate)))
      (with-stubbed-fdefinition
          ((sb-bsd-sockets:socket-send
            (lambda (socket buffer length &key dontwait nosignal)
              (declare (ignore socket dontwait nosignal))
              (incf calls)
              (setf sent
                    (concatenate '(vector (unsigned-byte 8))
                                 sent
                                 (subseq buffer 0 length)))
              (if (= calls 1) 2 length))))
        (multiple-value-bind (status bytes-written)
            (nerimux::%advance-client-output conn :max-bytes 2)
          (expect (eq :pending status))
          (expect (= 2 bytes-written))
          (expect (null (nerimux::client-conn-sent-row-frame conn))))
        (expect (eq first-frame
                    (nerimux::client-conn-active-output-frame conn)))
        (expect (eq :queued
                    (nerimux::%queue-client-render-state
                     conn second-frame second-candidate)))
        (multiple-value-bind (status bytes-written)
            (nerimux::%advance-client-output conn)
          (expect (eq :complete status))
          (expect (= (- (length first-frame) 2) bytes-written)))
        (expect (eq first-candidate
                    (nerimux::client-conn-sent-row-frame conn)))
        (expect (eq second-frame
                    (first (nerimux::client-conn-pending-render-state conn))))
        (expect (equalp first-frame sent)))))
  (it "client-close-drops-unstarted-render-and-drains-bye"
    (let* ((conn (%make-test-conn))
           (active-frame (nerimux/protocol:msg-frame "active"))
           (pending-frame (nerimux/protocol:msg-frame "pending"))
           (bye-frame (nerimux/protocol:msg-bye))
           (sent (make-array 0 :element-type '(unsigned-byte 8)))
           (calls 0)
           (nerimux::*clients* (list conn)))
      (expect (eq :queued
                  (nerimux::%queue-client-render-state conn active-frame nil)))
      (with-stubbed-fdefinition
          ((sb-bsd-sockets:socket-send
            (lambda (socket buffer length &key dontwait nosignal)
              (declare (ignore socket dontwait nosignal))
              (incf calls)
              (setf sent
                    (concatenate '(vector (unsigned-byte 8))
                                 sent
                                 (subseq buffer 0 length)))
              (if (= calls 1) 2 length))))
        (multiple-value-bind (status bytes-written)
            (nerimux::%advance-client-output conn :max-bytes 2)
          (expect (eq :pending status))
          (expect (= 2 bytes-written)))
        (expect (eq :queued
                    (nerimux::%queue-client-render-state conn pending-frame nil)))
        (expect (eq :closing (nerimux::%drop-client conn :bye t)))
        (expect (nerimux::client-conn-close-after-write-p conn))
        (expect (null (nerimux::client-conn-pending-render-state conn)))
        (multiple-value-bind (status bytes-written)
            (nerimux::%advance-client-output conn)
          (expect (eq :complete status))
          (expect (= (- (length active-frame) 2) bytes-written)))
        (multiple-value-bind (status bytes-written)
            (nerimux::%advance-client-output conn)
          (expect (eq :complete status))
          (expect (= (length bye-frame) bytes-written))))
      (expect (null nerimux::*clients*))
      (expect
       (equalp (concatenate '(vector (unsigned-byte 8))
                            active-frame bye-frame)
               sent))
      (expect (not (nerimux/transport:frame-writer-pending-p
                    (nerimux::client-conn-frame-writer conn))))))
  (it "client-close-admits-bye-after-dropping-pending-render-at-cap"
    (let* ((conn (%make-test-conn))
           (active-frame (nerimux/protocol:msg-frame "active"))
           (pending-frame (nerimux/protocol:msg-frame "pending"))
           (bye-frame (nerimux/protocol:msg-bye))
           (nerimux::*clients* (list conn)))
      (expect (eq :queued
                  (nerimux::%queue-client-render-state conn active-frame nil)))
      (with-stubbed-fdefinition
          ((sb-bsd-sockets:socket-send
            (lambda (socket buffer length &key dontwait nosignal)
              (declare (ignore socket buffer dontwait nosignal))
              2)))
        (multiple-value-bind (status bytes-written)
            (nerimux::%advance-client-output conn :max-bytes 2)
          (expect (eq :pending status))
          (expect (= 2 bytes-written))))
      (expect (eq :queued
                  (nerimux::%queue-client-render-state conn pending-frame nil)))
      (with-stubbed-fdefinition
          ((nerimux::%client-output-buffered-bytes
            (lambda (client)
              (if (nerimux::client-conn-pending-render-state client)
                  nerimux::+max-client-output-buffer-bytes+
                  (+ (nerimux::client-conn-control-frame-bytes client)
                     (if (eq :render
                             (nerimux::client-conn-active-output-kind client))
                         (length (nerimux::client-conn-active-output-frame client))
                         0))))))
        (expect (eq :closing (nerimux::%drop-client conn :bye t))))
      (expect (member conn nerimux::*clients* :test #'eq))
      (expect (nerimux::client-conn-close-after-write-p conn))
      (expect (null (nerimux::client-conn-pending-render-state conn)))
      (expect (eq :render (nerimux::client-conn-active-output-kind conn)))
      (expect (equalp active-frame
                      (nerimux::client-conn-active-output-frame conn)))
      (expect (nerimux/transport:frame-writer-pending-p
               (nerimux::client-conn-frame-writer conn)))
      (expect (= (length bye-frame)
                 (nerimux::client-conn-control-frame-bytes conn)))
      (expect (equalp bye-frame
                      (first (nerimux::client-conn-control-frame-head conn))))))
  (it "client-output-timeout-drops-and-clears-client-state"
    (let* ((conn (%make-test-conn))
           (healthy (%make-test-conn))
           (frame (nerimux/protocol:msg-reply "timeout"))
           (nerimux::*clients* (list conn healthy))
           (nerimux::*dirty* nil)
           (nerimux::*server-termination-requested-p* nil)
           (nerimux::*client-read-round-robin-cursor* nil)
           (nerimux::*client-write-round-robin-cursor* nil))
      (setf (nerimux::client-conn-fd conn) 8
            (nerimux::client-conn-fd healthy) 9)
      (expect (eq :queued
                  (nerimux::%queue-client-control-frame conn frame)))
      (with-stubbed-fdefinition
          ((sb-bsd-sockets:socket-send
            (lambda (socket buffer length &key dontwait nosignal)
              (declare (ignore socket buffer length dontwait nosignal))
              (error 'sb-ext:timeout)))
           (nerimux/net::socket-fd
            (lambda (listener)
              (declare (ignore listener))
              7))
           (nerimux/pty:select-fds
            (lambda (read-fds timeout-us &key write-fds)
              (declare (ignore read-fds timeout-us))
              (expect (equal (list 8) write-fds))
              (values nil write-fds)))
           (nerimux::%queue-session-control-output
            (lambda (session) (declare (ignore session))))
           (nerimux::%refresh-pending-client-render-frames
            (lambda (session &optional now)
              (declare (ignore session now))))
           (nerimux::%drain-main-thread-callbacks (lambda () nil))
           (nerimux::%workspace-job-tick (lambda () nil))
           (nerimux::%persist-runtime-state
            (lambda (session) (declare (ignore session))))
           (nerimux::%schedule-client-render-frames
            (lambda (session &optional now)
              (declare (ignore session now)))))
        (expect (null
                 (nerimux::%multi-serve-iteration :listener :session))))
      (expect (not (member conn nerimux::*clients* :test #'eq)))
      (expect (member healthy nerimux::*clients* :test #'eq))
      (expect (zerop (nerimux::client-conn-control-frame-bytes conn)))
      (expect (null (nerimux::client-conn-control-frame-head conn)))
      (expect (null (nerimux::client-conn-active-output-frame conn)))
      (expect (not (nerimux/transport:frame-writer-pending-p
                    (nerimux::client-conn-frame-writer conn))))))
  (it "client-output-fatal-partial-write-drops-and-clears-client-state"
  (let* ((conn (%make-test-conn))
         (first-frame (nerimux/protocol:msg-reply "first"))
         (second-frame (nerimux/protocol:msg-reply "second"))
         (calls 0)
         (nerimux::*clients* (list conn)))
    (nerimux::%queue-client-control-frame conn first-frame)
    (nerimux::%queue-client-control-frame conn second-frame)
    (with-stubbed-fdefinition
        ((sb-bsd-sockets:socket-send
          (lambda (socket buffer length &key dontwait nosignal)
            (declare (ignore socket buffer length dontwait nosignal))
            (incf calls)
            (case calls
              (1 2)
              (2 (error (make-condition 'sb-bsd-sockets:socket-error
                                        :errno sb-posix:epipe)))
              (otherwise (error "unexpected socket-send call"))))))
      (multiple-value-bind (status bytes-written)
          (nerimux::%advance-client-output conn :max-bytes 2)
        (expect (eq :pending status))
        (expect (= 2 bytes-written)))
      (expect (null (nerimux::%advance-client-output conn :max-bytes 2)))
      (expect (null nerimux::*clients*))
      (expect (zerop (nerimux::client-conn-control-frame-bytes conn)))
      (expect (null (nerimux::client-conn-control-frame-head conn)))
      (expect (null (nerimux::client-conn-pending-render-state conn)))
      (expect (null (nerimux::client-conn-active-output-frame conn)))
      (expect (not (nerimux/transport:frame-writer-pending-p
                    (nerimux::client-conn-frame-writer conn))))
      (expect (= 2 calls)))))
  (it "client-output-render-overflow-drops-and-clears-client"
    (let* ((conn (%make-test-conn))
           (frame (nerimux/protocol:msg-frame "render"))
           (nerimux::*clients* (list conn)))
      (setf (nerimux::client-conn-pending-render-state conn)
            (list #() nil))
      (with-stubbed-fdefinition
          ((nerimux::%client-output-buffered-bytes
            (lambda (client)
              (declare (ignore client))
              nerimux::+max-client-output-buffer-bytes+)))
        (expect (eq :overflow
                    (nerimux::%queue-client-render-state conn frame nil))))
      (expect (null nerimux::*clients*))
      (expect (null (nerimux::client-conn-pending-render-state conn)))
      (expect (null (nerimux::client-conn-control-frame-head conn)))
      (expect (not (nerimux/transport:frame-writer-pending-p
                    (nerimux::client-conn-frame-writer conn))))))

  (it "sends one host notification to every unfocused client"
      (multiple-value-bind (session worktree agent)
          (%make-waiting-agent-fixture)
        (declare (ignore agent))
        (let* ((conn-a (%make-test-conn))
               (conn-b (%make-test-conn))
               (notifications nil)
               (nerimux::*clients* (list conn-a conn-b))
               (nerimux::*dirty* nil)
               (nerimux/ports:*notify-host*
                 (lambda (stream title body)
                   (push (list stream title body) notifications))))
          (nerimux/workspace-model:worktree-mark-waiting
           worktree "approval required" 100)
          (nerimux::%broadcast-frame session)
          (expect (= 2 (length notifications)))
          (expect
           (every (lambda (entry)
                   (and (string= "nerimux" (second entry))
                        (search "github.com/team/repo · feature/waiting: approval required"
                                (third entry))))
                  notifications))
          (expect
           (nerimux/workspace-model:worktree-waiting-host-notified-p worktree))
          (nerimux::%broadcast-frame session)
          (expect (= 2 (length notifications))))))
  (it "suppresses the host notification while a client focuses the agent"
      (multiple-value-bind (session worktree agent)
          (%make-waiting-agent-fixture)
        (let ((notifications nil)
              (conn (%make-test-conn)))
          (setf (nerimux::client-conn-focus conn) agent)
          (nerimux/workspace-model:worktree-mark-waiting
           worktree "approval required" 100)
          (let ((nerimux::*clients* (list conn))
                (nerimux::*dirty* nil)
                (nerimux/ports:*notify-host*
                  (lambda (stream title body)
                    (declare (ignore stream title body))
                    (push t notifications))))
            (nerimux::%broadcast-frame session))
          (expect (null notifications))
          (expect
           (nerimux/workspace-model:worktree-waiting-host-notified-p worktree)))))
  (it "encodes host notifications and routes client output through its queue"
  (let* ((conn (%make-test-conn))
         (stream :client-stream)
         (nerimux::*clients* (list conn))
         (queued-frame nil))
    (setf (nerimux::client-conn-stream conn) stream)
    (nerimux::%send-host-notification stream "nerimux" "approval required")
    (setf queued-frame
          (first (nerimux::client-conn-control-frame-head conn)))
    (expect queued-frame)
    (multiple-value-bind (type payload next)
        (nerimux/protocol:decode-frame queued-frame)
      (expect (= nerimux/protocol:+msg-notification+ type))
      (expect (= (length queued-frame) next))
      (let ((text (cl-codec-kit:octets-to-string payload :encoding :utf-8)))
        (expect (search (format nil "~C]99;i=nerimux:d=0:p=title;nerimux~C\\"
                                #\Escape #\Escape)
                        text))
        (expect (search (format nil "~C]99;i=nerimux:d=1:p=body;approval required~C\\"
                                #\Escape #\Escape)
                        text))))
    (expect (= (length queued-frame)
               (nerimux::client-conn-control-frame-bytes conn))))
  (let ((frames nil))
    (with-stubbed-fdefinition
        ((nerimux/transport:send-frame
          (lambda (stream frame)
            (declare (ignore stream))
            (push frame frames))))
      (nerimux::%send-host-notification nil "nerimux" "approval required"))
    (expect (= 1 (length frames)))
    (multiple-value-bind (type payload next)
        (nerimux/protocol:decode-frame (first frames))
      (expect (= nerimux/protocol:+msg-notification+ type))
      (expect (= (length (first frames)) next))
      (let ((text (cl-codec-kit:octets-to-string payload :encoding :utf-8)))
        (expect (search (format nil "~C]99;i=nerimux:d=0:p=title;nerimux~C\\"
                                #\Escape #\Escape)
                        text))
        (expect (search (format nil "~C]99;i=nerimux:d=1:p=body;approval required~C\\"
                                #\Escape #\Escape)
                        text)))))))
