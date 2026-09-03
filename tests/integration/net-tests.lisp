(in-package #:nerimux/test)

(describe "net-suite"


  (it "make-probe-socket-path-returns-nonempty-string"
    (let ((path (nerimux/net::%make-probe-socket-path)))
      (expect (stringp path))
      (expect (plusp (length path)))))

  (it "make-probe-socket-path-is-in-temp-directory"
    (let* ((path    (nerimux/net::%make-probe-socket-path))
           (tmpdir  (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))))
      (expect (and (> (length path) (length tmpdir))
                   (string= tmpdir (subseq path 0 (length tmpdir)))))))

  (it "make-probe-socket-path-has-sock-suffix"
    (let ((path (nerimux/net::%make-probe-socket-path)))
      (expect (string= ".sock" (subseq path (- (length path) 5))))))

  (it "make-probe-socket-path-successive-calls-return-distinct-paths"
    (let ((path1 (nerimux/net::%make-probe-socket-path))
          (path2 (nerimux/net::%make-probe-socket-path)))
      (expect (not (string= path1 path2)))))


  (it "unix-socket-availability-is-boolean"
    (let ((answer (unix-socket-available-p)))
      (expect (member answer '(t nil)))))


  (it "connect-to-missing-path-signals"
    (signals error
      (connect-to "/nonexistent-nerimux-dir/does-not-exist.sock")))

  (it "connect-to-empty-path-signals"
    (signals error
      (connect-to "")))


  (it "socket-fd-returns-non-negative-integer"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (with-temp-socket-path (path)
      (let ((socket (make-listener path)))
        (unwind-protect
             (let ((fd (socket-fd socket)))
               (expect (integerp fd))
               (expect (>= fd 0)))
          (ignore-errors (close-socket socket))))))


  (it "close-socket-is-idempotent"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (with-temp-socket-path (path)
      (let ((socket (make-listener path)))
        (close-socket socket)
        (finishes (close-socket socket)
                  "second close-socket on same socket must not signal"))))

  (it "close-socket-swallow-socket-error"
    (with-stubbed-fdefinition
        ((sb-bsd-sockets:socket-close
           (lambda (&rest arguments)
             (declare (ignore arguments))
             (error 'sb-bsd-sockets:socket-error))))
      (expect (null (close-socket (list :not-a-real-socket))))))


  (it "socket-stream-is-a-stream"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (sb-ext:with-timeout 10
      (with-temp-socket-path (path)
        (with-connected-sockets (path listener client conn)
          (let ((client-stream (socket-stream client))
                (server-stream (socket-stream conn)))
            (expect (streamp client-stream))
            (expect (streamp server-stream)))))))


  (it "make-listener-accept-connection-returns-socket"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (sb-ext:with-timeout 10
      (with-temp-socket-path (path)
        (with-connected-sockets (path listener client conn)
          (expect conn :to-be-truthy)))))

  (it "accept-connection-returns-nil-on-timeout"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (with-temp-socket-path (path)
      (let* ((listener (make-listener path))
             (timeout-mock (make-mock-function
                            (lambda (l) (declare (ignore l)) (error 'sb-ext:timeout)))))
        (unwind-protect
             (with-mocked-functions
                 (((fdefinition 'sb-bsd-sockets:socket-accept) timeout-mock))
               (expect (null (nerimux/net:accept-connection listener))))
          (close-socket listener)))))


  (it "socket-frame-roundtrip"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (sb-ext:with-timeout 10
      (with-temp-socket-path (path)
        (with-connected-sockets (path listener client conn)
          (let ((client-stream (socket-stream client))
                (server-stream (socket-stream conn)))
            (send-frame client-stream (msg-key #(65 66)))
            (send-frame client-stream (msg-detach))
            (multiple-value-bind (type payload) (read-frame server-stream)
              (expect (= +msg-key+ type))
              (expect (equalp #(65 66) payload)))
            (multiple-value-bind (type payload) (read-frame server-stream)
              (declare (ignore payload))
              (expect (= +msg-detach+ type)))
            (send-frame server-stream (msg-frame "あ"))
            (multiple-value-bind (type payload) (read-frame client-stream)
              (expect (= +msg-frame+ type))
              (expect (string= "あ" (decode-text payload)))))))))

  (it "socket-multiple-frames-in-order"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (sb-ext:with-timeout 10
      (with-temp-socket-path (path)
        (with-connected-sockets (path listener client conn)
          (let ((client-stream (socket-stream client))
                (server-stream (socket-stream conn)))
            (send-frame client-stream (msg-frame "first"))
            (send-frame client-stream (msg-frame "second"))
            (send-frame client-stream (msg-frame "third"))
            (let ((results
                   (loop repeat 3
                         collect (multiple-value-bind (type payload)
                                     (read-frame server-stream)
                                   (declare (ignore type))
                                   (decode-text payload)))))
              (expect (equal '("first" "second" "third") results))))))))

  (it "socket-listener-fd-distinct-from-client-fd"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (sb-ext:with-timeout 10
      (with-temp-socket-path (path)
        (with-connected-sockets (path listener client conn)
          (expect (/= (socket-fd listener) (socket-fd client)))
          (expect (/= (socket-fd listener) (socket-fd conn)))))))


  (it "accept-timeout-constant-is-positive-integer"
    (expect (integerp nerimux/net::+accept-timeout-seconds+))
    (expect (plusp nerimux/net::+accept-timeout-seconds+)))

  (it "socket-stream-timeout-constant-is-positive-integer"
    (expect (integerp nerimux/net::+socket-stream-timeout-seconds+))
    (expect (plusp nerimux/net::+socket-stream-timeout-seconds+)))

  (it "connect-timeout-constant-is-positive-integer"
    (expect (integerp nerimux/net::+connect-timeout-seconds+))
    (expect (plusp nerimux/net::+connect-timeout-seconds+)))


  (it "socket-stream-has-binary-element-type"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (sb-ext:with-timeout 10
      (with-temp-socket-path (path)
        (with-connected-sockets (path listener client conn)
          (let ((s (socket-stream client)))
            (expect (subtypep (stream-element-type s) '(unsigned-byte 8))))))))


  (it "socket-msg-command-roundtrip"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (sb-ext:with-timeout 10
      (with-temp-socket-path (path)
        (with-connected-sockets (path listener client conn)
          (let ((client-stream (socket-stream client))
                (server-stream (socket-stream conn)))
            (send-frame client-stream
                        (msg-command :rename-window "1:alpha" '("new-name")))
            (multiple-value-bind (type payload) (read-frame server-stream)
              (expect (= +msg-command+ type))
              (multiple-value-bind (command target args)
                  (nerimux/protocol:decode-command-payload payload)
                (expect (eq :rename-window command))
                (expect (string= "1:alpha" target))
                (expect (equal '("new-name") args)))))))))


  (it "socket-bidirectional-frame-exchange"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (sb-ext:with-timeout 10
      (with-temp-socket-path (path)
        (with-connected-sockets (path listener client conn)
          (let ((client-stream (socket-stream client))
                (server-stream (socket-stream conn)))
            (send-frame client-stream (msg-attach 24 80))
            (multiple-value-bind (type payload) (read-frame server-stream)
              (expect (= +msg-attach+ type))
              (multiple-value-bind (rows cols)
                  (nerimux/protocol:decode-size payload)
                (expect (= 24 rows))
                (expect (= 80 cols))))
            (send-frame server-stream (msg-frame "rendered output"))
            (multiple-value-bind (type payload) (read-frame client-stream)
              (expect (= +msg-frame+ type))
              (expect (string= "rendered output"
                                (nerimux/protocol:decode-text payload)))))))))


  (it "make-listener-binds-at-given-path"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (sb-ext:with-timeout 10
      (with-temp-socket-path (path)
        (with-connected-sockets (path listener client conn)
          (expect listener :to-be-truthy)
          (expect client :to-be-truthy)
          (expect conn :to-be-truthy)))))


  (it "make-listener-accepts-explicit-backlog"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (sb-ext:with-timeout 10
      (with-temp-socket-path (path)
        (let ((listener (make-listener path :backlog 4)))
          (unwind-protect
               (let* ((client (connect-to path))
                      (conn   (accept-connection listener)))
                 (unwind-protect
                      (expect conn :to-be-truthy)
                   (ignore-errors (close-socket client))
                   (ignore-errors (close-socket conn))))
            (ignore-errors (close-socket listener)))))))


  (it "close-socket-on-fresh-socket-does-not-signal"
    (unless (unix-socket-available-p)
      (skip "Unix-domain socket bind unavailable (sandbox)"))
    (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (finishes (close-socket socket)
                "close-socket on a freshly created (unbound) socket must not signal"))))
