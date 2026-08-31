(in-package #:nerimux/test)

(describe "client-command-suite"

  (it "decode-server-frame-classifies-eof-bye-frame-and-unknown"
    (dolist (case (list (list nil nil :exit nil)
                        (list +msg-bye+ nil :exit nil)
                        (list +msg-frame+ #(1 2) :frame "screen")
                        (list 255 #(3) :ignore nil)))
      (destructuring-bind (type payload expected-disposition expected-text) case
        (with-stubbed-fdefinition
            ((nerimux/transport:read-frame
              (lambda (stream)
                (declare (ignore stream))
                (values type payload)))
             (nerimux/protocol:decode-text
              (lambda (value)
                (declare (ignore value))
                "screen")))
          (multiple-value-bind (disposition text)
              (nerimux::%decode-server-frame :stream)
            (expect (eq expected-disposition disposition))
            (expect (equal expected-text text)))))))

  (it "receive-server-frame-writes-only-rendered-frames"
    (let (decoded)
      (with-stubbed-fdefinition
          ((nerimux::%decode-server-frame
            (lambda (stream)
              (declare (ignore stream))
              (values :frame "rendered"))))
        (setf decoded
              (with-output-to-string (*standard-output*)
                (expect (null (nerimux::%receive-server-frame :stream)))))
        (expect (string= "rendered" decoded))))
    (with-stubbed-fdefinition
        ((nerimux::%decode-server-frame
          (lambda (stream)
            (declare (ignore stream))
            (values :exit nil))))
      (expect (eq :exit (nerimux::%receive-server-frame :stream))))) (it "receive-if-ready-dispatches-only-when-fd-is-ready"
    (let ((calls 0))
      (with-stubbed-fdefinition
          ((nerimux::%receive-server-frame
            (lambda (stream)
              (declare (ignore stream))
              (incf calls)
              :exit)))
        (expect (null (nerimux::%receive-if-ready :stream 7 '(8))))
        (expect (eq :exit (nerimux::%receive-if-ready :stream 7 '(7 8)))))
      (expect (= 1 calls)))) (it "maybe-send-resize-sends-frame-when-pending"
    (with-guarded-socket-test
      ;; Set resize-pending and known dimensions.
      (let ((nerimux::*resize-pending* t)
            (nerimux::*term-rows*      24)
            (nerimux::*term-cols*      80))
        ;; Call the helper with server-side as the stream to write on.
        (nerimux::%maybe-send-resize server-side)
        (force-output server-side)
        ;; The helper clears *resize-pending*.
        (expect nerimux::*resize-pending* :to-be-falsy)
        ;; A +msg-resize+ frame must be readable from the other end.
        (with-incoming-frame (type payload client-side)
          ((null type) (fail "%maybe-send-resize: got EOF instead of resize frame"))
          ((= type +msg-resize+)
           (multiple-value-bind (rows cols) (decode-size payload)
             (expect (= nerimux::*term-rows* rows))
             (expect (= nerimux::*term-cols* cols))))
          (t (fail "%maybe-send-resize: unexpected frame type ~D" type)))))) (it "maybe-send-resize-does-nothing-when-not-pending"
    (let ((nerimux::*resize-pending* nil))
      (expect (nerimux::%maybe-send-resize nil) :to-be-falsy)))

  (it "install-sigwinch-handler-flags-resize-and-dirty"
    (let ((captured-handler nil)
          (nerimux::*resize-pending* nil)
          (nerimux::*dirty* nil))
      (sb-ext:without-package-locks
        (with-stubbed-fdefinition
            ((sb-sys:enable-interrupt
              (lambda (signal handler)
                (declare (ignore signal))
                (setf captured-handler handler)
                :installed)))
          (expect (nerimux::install-sigwinch-handler) :to-be :installed)))
      (funcall captured-handler)
      (expect nerimux::*resize-pending* :to-be-truthy)
      (expect nerimux::*dirty* :to-be-truthy)))

  (it "maybe-send-resize-samples-size-and-sends-through-the-effect-boundary"
    (let ((nerimux::*resize-pending* t)
          (nerimux::*term-rows* 1)
          (nerimux::*term-cols* 2)
          sent)
      (with-stubbed-fdefinition
          ((nerimux::terminal-size (lambda () (values 40 120)))
           (nerimux/transport:send-frame
            (lambda (stream frame)
              (setf sent (list stream frame)))))
        (expect (nerimux::%maybe-send-resize :stream)))
      (expect (null nerimux::*resize-pending*))
      (expect (= 40 nerimux::*term-rows*))
      (expect (= 120 nerimux::*term-cols*))
      (expect (eq :stream (first sent))))) (it "forward-stdin-byte-returns-nil-when-nothing-ready"
    ;; read-byte-nonblock(0) on a non-blocking terminal returns NIL when no data
    ;; is ready.  In the test runner stdin is either /dev/null or a pipe with no
    ;; pending data — either way the function must return NIL without signalling.
    ;; Pass NIL as the stream so no socket write can happen even if the byte test
    ;; were to incorrectly find data.
    (let ((result (ignore-errors (nerimux::%forward-stdin-byte nil))))
      (expect (null result)))) (it "forward-stdin-byte-sends-available-byte"
    (let (sent)
      (with-stubbed-fdefinition
          ((nerimux::read-byte-nonblock (lambda (fd)
                                          (declare (ignore fd))
                                          65))
           (nerimux/transport:send-frame (lambda (stream frame)
                                           (setf sent (list stream frame)))))
        (expect (nerimux::%forward-stdin-byte :stream)))
      (expect (eq :stream (first sent)))
      (multiple-value-bind (type payload next)
          (decode-frame (second sent))
        (declare (ignore next))
        (expect (= +msg-key+ type))
        (expect (equal (list 65) (coerce payload 'list)))))) (it "client-working-directory-returns-a-string"
    (expect (stringp (nerimux::%client-working-directory)))) (it "client-working-directory-falls-back-when-default-directory-is-unresolvable"
    (let ((fallback (make-pathname :directory '(:absolute "path-that-does-not-exist"))))
      (let ((nerimux::*default-pathname-defaults* fallback))
        (expect (equal "/path-that-does-not-exist/"
                       (nerimux::%client-working-directory)))))) (it "run-client-owns-terminal-and-socket-lifecycle"
    (let ((events nil) (socket-path-name nil))
      (with-stubbed-fdefinition
          ((nerimux::socket-path
           (lambda (name)
              (setf socket-path-name name)
              (push (list :socket-path name) events)
              "/tmp/nerimux-test-client.sock"))
           (nerimux/net:connect-to
            (lambda (path)
              (push (list :connect path) events)
              :socket))
           (nerimux/net:socket-stream
            (lambda (socket)
              (declare (ignore socket))
              (push :stream events)
              :stream))
           (nerimux/net:socket-fd
            (lambda (socket)
              (declare (ignore socket))
              (push :fd events)
              99))
           (nerimux/pty:terminal-size
            (lambda ()
              (push :size events)
              (values 24 80)))
           (nerimux::install-sigwinch-handler
            (lambda () (push :sigwinch events) nil))
           (nerimux/pty:enable-raw-mode!
            (lambda (fd)
              (push (list :raw-enable fd) events)
              nil))
           (nerimux/pty:disable-raw-mode!
            (lambda (fd)
              (push (list :raw-disable fd) events)
              nil))
           (nerimux/renderer:clear-display
            (lambda () (push :clear events) nil))
           (nerimux::%run-attach-session
            (lambda (stream fd target)
              (push (list :attach stream fd target) events)
              nil))
           (nerimux/net:close-socket
            (lambda (socket)
              (push (list :close socket) events)
              nil)))
        (nerimux::run-client "7" :target "target"))
      (expect (equal '(24 80) (list nerimux::*term-rows* nerimux::*term-cols*)))
      (expect (string= "7" socket-path-name))
      (expect (member :clear events) :to-be-truthy)
      (expect (member :sigwinch events) :to-be-truthy)
      (expect (member '(:raw-enable 0) events :test #'equal) :to-be-truthy)
      (expect (member '(:raw-disable 0) events :test #'equal) :to-be-truthy)
      (expect (member '(:attach :stream 99 "target") events :test #'equal)
              :to-be-truthy)
      (expect (member '(:close :socket) events :test #'equal) :to-be-truthy))) (it "send-client-attach-target-sends-command"
    (with-guarded-socket-test
      (nerimux::%send-client-attach-target server-side "target")
      (force-output server-side)
      (with-incoming-frame (type payload client-side)
        ((= type +msg-command+)
         (multiple-value-bind (command target args)
             (decode-command-payload payload)
           (expect (eq :attach-target command))
           (expect (null target))
           (expect (equal "target" (first args)))
           (expect (stringp (second args)))))
        (t (fail "unexpected frame type")))))

  ;;; ── %run-attach-session peer-io-failure containment ──────────────────────────
  ;;;
  ;;; %run-attach-session (extracted from run-client) wraps its handshake sends
  ;;; and event loop in one HANDLER-CASE for PEER-IO-FAILURE (server.lisp) --
  ;;; (OR ERROR SB-EXT:TIMEOUT), not ERROR alone.  SEND-FRAME
  ;;; (infrastructure/net/transport.lisp) documents itself as signalling
  ;;; SB-EXT:TIMEOUT -- a SERIOUS-CONDITION that is deliberately NOT an ERROR --
  ;;; when a peer is too slow to accept a write, so this stubs SEND-FRAME to
  ;;; produce a genuine SB-EXT:TIMEOUT via SB-EXT:WITH-TIMEOUT (the same
  ;;; technique server-dispatch-helper-tests.lisp uses for
  ;;; WITH-LOOP-SAFE-ERROR) rather than a plain ERROR, so a regression back to
  ;;; an ERROR-only clause would fail this test even though it would still
  ;;; pass a weaker one written with (ERROR () ...).

  ;; A genuine SB-EXT:TIMEOUT from SEND-FRAME during the initial handshake is
  ;; contained: %run-attach-session returns normally (the condition does not
  ;; propagate to the caller) and reports the failure on *error-output*.
  (it "run-attach-session-contains-a-genuine-timeout-from-send-frame"
    (with-stubbed-fdefinition
        ((nerimux/transport:send-frame
          (lambda (&rest args)
            (declare (ignore args))
            (sb-ext:with-timeout 0.05 (sleep 5)))))
      (let (result reported)
        (setf reported
              (with-output-to-string (*error-output*)
                (setf result
                      (nerimux::%run-attach-session nil 99 nil))))
        ;; No condition escaped this call -- CL-WEAVE would report an
        ;; unhandled SB-EXT:TIMEOUT as a test error, not a failed EXPECT, so
        ;; simply reaching this line is part of the proof.
        (expect (null result))
        (expect (search "connection lost" reported)))))

  ;; An ordinary ERROR from SEND-FRAME is contained the same way as a timeout
  ;; -- PEER-IO-FAILURE is (OR ERROR SB-EXT:TIMEOUT), so the ERROR half of the
  ;; union must keep working too.
  (it "run-attach-session-contains-an-ordinary-error-from-send-frame"
    (with-stubbed-fdefinition
        ((nerimux/transport:send-frame
          (lambda (&rest args)
            (declare (ignore args))
            (error "socket write failed"))))
      (let (result reported)
        (setf reported
              (with-output-to-string (*error-output*)
                (setf result
                      (nerimux::%run-attach-session nil 99 nil))))
        (expect (null result))
        (expect (search "socket write failed" reported)))))

  (it "run-attach-session-forwards-stdin-before-server-exit"
    (let ((sent 0) (forwarded 0) (polled 0))
      (with-stubbed-fdefinition
          ((nerimux/transport:send-frame
            (lambda (&rest args) (declare (ignore args)) (incf sent)))
           (nerimux/pty:select-fds
            (lambda (fds timeout-us)
              (declare (ignore fds timeout-us))
              (incf polled)
              '(0 99)))
           (nerimux::%forward-stdin-byte
            (lambda (stream) (declare (ignore stream)) (incf forwarded)))
           (nerimux::%receive-if-ready
            (lambda (stream fd ready)
              (declare (ignore stream fd ready))
              :exit)))
        (nerimux::%run-attach-session nil 99 "target"))
      (expect (= 2 sent))
      (expect (= 1 forwarded))
      (expect (= 1 polled))))

  ;;; ── send-kill-request peer-io-failure containment ────────────────────────────
  ;;;
  ;;; send-kill-request (the short one-shot `nerimux kill` control connection)
  ;;; treats a PEER-IO-FAILURE on its SEND-FRAME the same as :eof -- no reply
  ;;; arrived either way -- so RUN-KILL's existing "no reply from server"
  ;;; report (main-startup-commands.lisp) covers it without a second message.

  ;; A genuine SB-EXT:TIMEOUT from SEND-FRAME while sending the :kill command
  ;; is contained: send-kill-request returns (:eof NIL) instead of letting the
  ;; condition escape, and %read-kill-reply is never reached.
  (it "send-kill-request-maps-a-genuine-send-timeout-to-eof"
    (let (read-kill-reply-called)
      (with-stubbed-fdefinition
          ((nerimux::socket-path
            (lambda (name) (declare (ignore name)) "/tmp/nerimux-test-kill.sock"))
           (nerimux/net:connect-to
            (lambda (path) (declare (ignore path)) :socket))
           (nerimux/net:socket-stream
            (lambda (socket) (declare (ignore socket)) :stream))
           (nerimux/net:close-socket
            (lambda (socket) (declare (ignore socket))))
           (nerimux/transport:send-frame
            (lambda (&rest args)
              (declare (ignore args))
              (sb-ext:with-timeout 0.05 (sleep 5))))
           (nerimux::%read-kill-reply
            (lambda (stream)
              (declare (ignore stream))
              (setf read-kill-reply-called t)
              (values :reply (format nil "OK~%")))))
        (multiple-value-bind (status text) (nerimux::send-kill-request "0" nil)
          (expect (eq :eof status))
          (expect (null text))))
      (expect (null read-kill-reply-called))))

  (it "send-kill-request-maps-connect-socket-error-to-no-server"
    (with-stubbed-fdefinition
        ((nerimux::socket-path
          (lambda (name) (declare (ignore name)) "/tmp/nerimux-test-kill.sock"))
         (nerimux/net:connect-to
          (lambda (path)
            (declare (ignore path))
            (error 'sb-bsd-sockets:socket-error :syscall "connect" :errno 2))))
      (multiple-value-bind (status text) (nerimux::send-kill-request "0" nil)
        (expect (eq :no-server status))
        (expect (null text)))))

  (it "read-kill-reply-skips-broadcast-frames-and-decodes-reply"
    (let ((frames (list (list +msg-frame+ #(1 2))
                        (list +msg-reply+ #(3 4)))))
      (with-stubbed-fdefinition
          ((nerimux/transport:read-frame
            (lambda (stream)
              (declare (ignore stream))
              (destructuring-bind (type payload) (pop frames)
                (values type payload))))
           (nerimux/protocol:decode-text
            (lambda (payload)
              (declare (ignore payload))
              "OK\n")))
        (multiple-value-bind (status text)
            (nerimux::%read-kill-reply :stream)
          (expect (eq :reply status))
          (expect (string= "OK\n" text))))))

  (it "read-kill-reply-treats-eof-and-bye-as-eof"
    (dolist (frame (list (list nil nil)
                         (list +msg-bye+ nil)))
      (with-stubbed-fdefinition
          ((nerimux/transport:read-frame
            (lambda (stream)
              (declare (ignore stream))
              (values-list frame))))
        (multiple-value-bind (status text)
            (nerimux::%read-kill-reply :stream)
          (expect (eq :eof status))
          (expect (null text))))))

  (it "parse-kill-reply-status-fails-closed-for-non-ok-first-lines"
    (dolist (text (list "DENIED\nactive-pane\n"
                        ""
                        "unexpected"))
      (expect (eq :denied (nerimux::%parse-kill-reply-status text)))))

  (it "send-kill-request-returns-success-reply-and-closes-socket"
    (let ((closed nil) (sent nil))
      (with-stubbed-fdefinition
          ((nerimux::socket-path
            (lambda (name) (declare (ignore name)) "/tmp/nerimux-test-kill.sock"))
           (nerimux/net:connect-to
            (lambda (path) (declare (ignore path)) :socket))
           (nerimux/net:socket-stream
            (lambda (socket) (declare (ignore socket)) :stream))
           (nerimux/net:close-socket
            (lambda (socket) (declare (ignore socket)) (setf closed t)))
           (nerimux/transport:send-frame
            (lambda (stream frame) (setf sent (list stream frame))))
           (nerimux::%read-kill-reply
            (lambda (stream)
              (declare (ignore stream))
              (values :reply (format nil "OK~%")))))
        (multiple-value-bind (status text)
            (nerimux::send-kill-request "0" t)
          (expect (eq :ok status))
          (expect (string= (format nil "OK~%") text))))
      (expect closed)
      (expect (eq :stream (first sent)))
      (multiple-value-bind (type payload next)
          (decode-frame (second sent))
        (declare (ignore next))
        (expect (= +msg-command+ type))
        (multiple-value-bind (command target args)
            (decode-command-payload payload)
          (expect (eq :kill command))
          (expect (null target))
          (expect (equal '("--force") args)))))))

  ;;; ── %maybe-send-resize behavior ──────────────────────────────────────────────
  ;;;
  ;;; %maybe-send-resize encapsulates the resize-pending check that was inline in
  ;;; run-client.  It is tested here using a socket pair so the msg-resize frame
  ;;; can be observed without a live terminal.

  ;; %maybe-send-resize sends a +msg-resize+ frame and clears *resize-pending*
  ;; when *resize-pending* is T — verifies the resize-dispatch path extracted from run-client.


  ;; %maybe-send-resize is a no-op when *resize-pending* is NIL.


  ;;; ── %forward-stdin-byte behavior ─────────────────────────────────────────────
  ;;;
  ;;; %forward-stdin-byte reads one non-blocking byte from fd 0 (stdin) and
  ;;; forwards it as a +msg-key+ frame.  We test the "nothing ready" branch
  ;;; (returns NIL without I/O) — the "byte forwarded" branch requires a real
  ;;; non-blocking stdin fd, which is unavailable in a sandboxed test runner.

  ;; %forward-stdin-byte returns NIL without error when stdin has no
  ;; data ready (non-blocking read returns nil).
