(in-package #:nerimux/test)

(defun %host-mode-sequence (enable-p)
  (if enable-p
      (format nil "~C[?1049h~C[?2004h~C[?1004h" #\Escape #\Escape #\Escape)
      (format nil "~C[?1004l~C[?2004l~C[?1049l" #\Escape #\Escape #\Escape)))

(defun %expected-client-host-output ()
  (concatenate 'string
               (%host-mode-sequence t)
               (format nil "~C[2J~C[H" #\Escape #\Escape)
               "nerimux: connecting..."
               (%host-mode-sequence nil)
               (format nil "~%")))

(defmacro %with-stubbed-client-host-output-to (stream &body attach-body)
  `(let ((*standard-output* ,stream)
         (*error-output* (make-string-output-stream))
         (events nil))
     (let ((result
             (with-stubbed-fdefinition
                 ((nerimux::socket-path
                   (lambda (name)
                     (declare (ignore name))
                     "/tmp/nerimux-test-client.sock"))
                  (nerimux/net:connect-to
                   (lambda (path)
                     (declare (ignore path))
                     :socket))
                  (nerimux/net:socket-fd
                   (lambda (socket)
                     (declare (ignore socket))
                     99))
                  (nerimux/pty:terminal-size
                   (lambda ()
                     (values 24 80)))
                  (nerimux::install-sigwinch-handler
                   (lambda () nil))
                  (nerimux/pty:enable-raw-mode!
                   (lambda (fd)
                     (declare (ignore fd))
                     (push :raw-enabled events)
                     nil))
                  (nerimux/pty:disable-raw-mode!
                   (lambda (fd)
                     (declare (ignore fd))
                     (push :raw-disabled events)
                     nil))
                  (nerimux::%client-fd-flags
                   (lambda (fd)
                     (declare (ignore fd))
                     0))
                  (nerimux::%client-set-nonblocking
                   (lambda (fd)
                     (declare (ignore fd))
                     nil))
                  (nerimux::%client-restore-fd-flags
                   (lambda (fd flags)
                     (declare (ignore fd flags))
                     nil))
                  (nerimux/pty:select-fds
                   (lambda (read-fds timeout-us &key write-fds)
                     (declare (ignore read-fds timeout-us))
                     (values nil write-fds)))
                  (nerimux::%client-write-fd
                   (lambda (fd bytes start length)
                     (declare (ignore fd))
                     (let ((chunk (subseq bytes start (+ start length))))
                       (push (list :output chunk) events)
                       (write-string (nerimux/protocol:decode-text chunk) ,stream)
                       length)))
                  (nerimux/net:close-socket
                   (lambda (&rest args)
                     (declare (ignore args))
                     nil))
                  (nerimux::%run-attach-session
                   (lambda (socket fd target queue &optional input-fd output-fd)
                     (declare (ignore socket fd target input-fd output-fd))
                     ,@attach-body)))
               (nerimux::run-client "7"))))
       (values result (nreverse events)))))

(defmacro with-stubbed-client-host-output (&body attach-body)
  `(with-output-to-string (output)
     (%with-stubbed-client-host-output-to output ,@attach-body)))

(defmacro with-connected-client-host-output (setup &body body)
  `(with-guarded-socket-test/fd
       (:server-sock server-sock
        :client-sock client-sock
        :server-stream server-stream)
     ,@setup
     (with-output-to-string (*standard-output*)
       (let ((*error-output* (make-string-output-stream)))
         (with-stubbed-fdefinition
             ((nerimux/net:connect-to
               (lambda (path)
                 (declare (ignore path))
                 client-sock))
              (nerimux/pty:terminal-size
               (lambda () (values 24 80)))
              (nerimux::install-sigwinch-handler
               (lambda () nil))
              (nerimux/pty:enable-raw-mode!
               (lambda (fd)
                 (declare (ignore fd))
                 nil))
              (nerimux/pty:disable-raw-mode!
               (lambda (fd)
                 (declare (ignore fd))
                 nil))
              (nerimux::%client-fd-flags
               (lambda (fd)
                 (declare (ignore fd))
                 0))
              (nerimux::%client-set-nonblocking
               (lambda (fd)
                 (declare (ignore fd))
                 0))
              (nerimux::%client-restore-fd-flags
               (lambda (fd flags)
                 (declare (ignore fd flags))
                 nil))
              (nerimux::%client-write-fd
               (lambda (fd bytes start length)
                 (declare (ignore fd))
                 (write-string
                  (nerimux/protocol:decode-text
                   (subseq bytes start (+ start length)))
                  *standard-output*)
                 length))
              (nerimux/net:close-socket
               (lambda (&rest args)
                 (declare (ignore args))
                 nil)))
           ,@body)))))

(describe "client-command-suite"

  (it "renderer-enable-host-modes-emits-1049-2004-1004"
    (let ((output
            (with-output-to-string (*standard-output*)
              (nerimux/renderer:enable-host-modes))))
      (expect (string= (%host-mode-sequence t) output))))

  (it "renderer-disable-host-modes-emits-1004-2004-1049"
    (let ((output
            (with-output-to-string (*standard-output*)
              (nerimux/renderer:disable-host-modes))))
      (expect (string= (%host-mode-sequence nil) output))))

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
        (expect (string= (format nil "~C[?2026hrendered~C[?2026l"
                                  #\Escape
                                  #\Escape)
                           decoded))))
    (with-stubbed-fdefinition
        ((nerimux::%decode-server-frame
          (lambda (stream)
            (declare (ignore stream))
            (values :exit nil))))
      (expect (eq :exit (nerimux::%receive-server-frame :stream)))))

  (it "receive-server-frame-keeps-notifications-outside-synchronized-frames"
    (let (written)
      (with-stubbed-fdefinition
          ((nerimux::%decode-server-frame
            (lambda (stream)
              (declare (ignore stream))
              (values :notification #(27 91 57 57 57 126))))
           (nerimux::%write-notification-bytes
            (lambda (bytes)
              (setf written (copy-seq bytes)))))
        (expect (null (nerimux::%receive-server-frame :stream))))
      (expect (equalp #(27 91 57 57 57 126) written))))

  (it "receive-server-frame-closes-synchronized-output-when-frame-writing-signals"
    (let ((stream (make-string-output-stream))
          (condition nil))
      (handler-case
          (with-stubbed-fdefinition
              ((nerimux::%decode-server-frame
                (lambda (value)
                  (declare (ignore value))
                  (values :frame nil))))
            (let ((*standard-output* stream))
              (nerimux::%receive-server-frame :stream)))
        (error (caught)
          (setf condition caught)))
      (let ((output (get-output-stream-string stream)))
        (expect condition :to-be-truthy)
        (expect (string= (format nil "~C[?2026h~C[?2026l"
                                  #\Escape
                                  #\Escape)
                           output)))))

  (it "receive-if-ready-dispatches-only-when-fd-is-ready"
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
      (let ((nerimux::*resize-pending* t)
            (nerimux::*term-rows*      24)
            (nerimux::*term-cols*      80))
        (nerimux::%maybe-send-resize server-side)
        (force-output server-side)
        (expect nerimux::*resize-pending* :to-be-falsy)
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
      (expect (eq :stream (first sent)))))

  (it "forward-stdin-byte-returns-nil-when-nothing-is-ready"
    (let ((sends 0))
      (with-stubbed-fdefinition
          ((nerimux::read-available-octets
             (lambda (timeout-us max-octets)
               (declare (ignore timeout-us max-octets))
               nil))
           (nerimux/transport:send-frame
             (lambda (stream frame)
               (declare (ignore stream frame))
               (incf sends))))
        (expect (null (nerimux::%forward-stdin-byte :stream))))
      (expect (= 0 sends))))

  (it "forward-stdin-byte-sends-one-available-octet"
    (let (sent read-arguments)
      (with-stubbed-fdefinition
          ((nerimux::read-available-octets
             (lambda (timeout-us max-octets)
               (setf read-arguments (list timeout-us max-octets))
               #(65)))
           (nerimux/transport:send-frame
             (lambda (stream frame)
               (setf sent (list stream frame)))))
        (expect (nerimux::%forward-stdin-byte :stream)))
      (expect (equal (list 0 nerimux/ports:+pty-buf-size+) read-arguments))
      (expect (eq :stream (first sent)))
      (multiple-value-bind (type payload next)
          (decode-frame (second sent))
        (declare (ignore next))
        (expect (= +msg-key+ type))
        (expect (equalp #(65) payload)))))

  (it "forward-stdin-byte-sends-a-multi-octet-burst-as-one-frame"
    (let ((frames nil))
      (with-stubbed-fdefinition
          ((nerimux::read-available-octets
             (lambda (timeout-us max-octets)
               (declare (ignore timeout-us max-octets))
               #(65 66 67 68)))
           (nerimux/transport:send-frame
             (lambda (stream frame)
               (push (list stream frame) frames))))
        (expect (nerimux::%forward-stdin-byte :stream)))
      (expect (= 1 (length frames)))
      (multiple-value-bind (type payload next)
          (decode-frame (second (first frames)))
        (declare (ignore next))
        (expect (= +msg-key+ type))
        (expect (equalp #(65 66 67 68) payload)))))

  (it "client-working-directory-returns-a-string"
    (expect (stringp (nerimux::%client-working-directory)))) (it "client-working-directory-falls-back-when-default-directory-is-unresolvable"
    (let ((fallback (make-pathname :directory '(:absolute "path-that-does-not-exist"))))
      (let ((nerimux::*default-pathname-defaults* fallback))
        (expect (equal "/path-that-does-not-exist/"
                       (nerimux::%client-working-directory)))))) (it "run-client-owns-terminal-and-socket-lifecycle"
  (let ((stream (make-string-output-stream)))
    (multiple-value-bind (result events)
        (%with-stubbed-client-host-output-to stream nil)
      (declare (ignore result))
      (let* ((output (get-output-stream-string stream))
             (output-events
               (remove-if-not
                (lambda (event)
                  (and (consp event) (eq :output (first event))))
                events))
             (setup
               (cl-codec-kit:string-to-octets
                (concatenate
                 'string (%host-mode-sequence t)
                 (format nil "~C[2J~C[H" #\Escape #\Escape)
                 "nerimux: connecting...")
                :encoding :utf-8))
             (last-output (position-if
                           (lambda (event)
                             (and (consp event) (eq :output (first event))))
                           events :from-end t))
             (raw-enabled (position :raw-enabled events))
             (raw-disabled (position :raw-disabled events)))
        (expect (string= (%expected-client-host-output) output))
        (expect (equalp setup (second (first output-events))))
        (expect raw-enabled :to-be-truthy)
        (expect raw-disabled :to-be-truthy)
        (expect last-output :to-be-truthy)
        (expect (< raw-enabled last-output raw-disabled))
        (expect (= raw-disabled (1- (length events))))))))


  (it "run-client-detach-server-drop-cleans-up-host-modes"
  (let ((stream (make-string-output-stream)))
    (multiple-value-bind (result events)
        (%with-stubbed-client-host-output-to stream
          (push :detach-sent events))
      (declare (ignore result))
      (let ((output (get-output-stream-string stream))
            (detach-index (position :detach-sent events))
            (disable-index (position :raw-disabled events))
            (last-output
              (position-if
               (lambda (event)
                 (and (consp event) (eq :output (first event))))
               events :from-end t)))
        (expect (string= (%expected-client-host-output) output))
        (expect detach-index :to-be-truthy)
        (expect last-output :to-be-truthy)
        (expect disable-index :to-be-truthy)
        (expect (< detach-index last-output disable-index))
        (expect (= disable-index (1- (length events))))))))


  (it "run-client-peer-io-failure-cleans-up-host-modes"
  (let ((stream (make-string-output-stream))
        (condition nil))
    (handler-case
        (%with-stubbed-client-host-output-to stream
          (error "peer write failed"))
      (error (caught) (setf condition caught)))
    (let ((output (get-output-stream-string stream)))
      (expect condition :to-be-truthy)
      (expect (string= (%expected-client-host-output) output))
      (expect (search (%host-mode-sequence nil) output)))))


  (it "run-client-server-eof-cleans-up-host-modes"
  (let ((stream (make-string-output-stream)))
    (multiple-value-bind (result events)
        (%with-stubbed-client-host-output-to stream
          (push :server-eof events))
      (declare (ignore result))
      (let ((output (get-output-stream-string stream)))
        (expect (string= (%expected-client-host-output) output))
        (expect (position :server-eof events) :to-be-truthy)
        (expect (search (%host-mode-sequence nil) output))
        (expect (= (position :raw-disabled events) (1- (length events))))))))


  (it "run-client-attach-exception-cleans-up-host-modes"
    (let ((stream (make-string-output-stream))
          (condition nil))
      (handler-case
          (%with-stubbed-client-host-output-to stream
            (error "attach session failed"))
        (error (caught)
          (setf condition caught)))
      (let ((output (get-output-stream-string stream)))
        (expect condition :to-be-truthy)
        (expect (search (%host-mode-sequence t) output))
        (expect (search (%host-mode-sequence nil) output))
        (expect (< (search (%host-mode-sequence t) output)
                   (search (%host-mode-sequence nil) output))))))

  (it "run-client-attach-non-local-exit-cleans-up-host-modes"
    (let* ((stream (make-string-output-stream))
           (result
             (catch 'client-attach-non-local-exit
               (%with-stubbed-client-host-output-to stream
                 (throw 'client-attach-non-local-exit :stopped)))))
      (expect (eq :stopped result))
      (let ((output (get-output-stream-string stream)))
        (expect (search (%host-mode-sequence t) output))
        (expect (search (%host-mode-sequence nil) output))
        (expect (< (search (%host-mode-sequence t) output)
                   (search (%host-mode-sequence nil) output))))))

  (it "run-client-connect-failure-emits-no-host-modes"
    (let ((output
            (with-output-to-string (*standard-output*)
              (with-stubbed-fdefinition
                  ((nerimux::socket-path
                    (lambda (name)
                      (declare (ignore name))
                      "/tmp/nerimux-test-client.sock"))
                   (nerimux/net:connect-to
                    (lambda (path)
                      (declare (ignore path))
                      (error "connect failed"))))
                (handler-case (nerimux::run-client "7")
                  (error () nil))))))
      (expect (string= "" output))))

  (it "send-client-attach-target-sends-command"
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

  (it "client-terminal-identity-forwards-only-allow-listed-variables"
  (with-temporary-posix-environment-variable ("TERM_PROGRAM" "kitty")
    (with-temporary-posix-environment-variable ("TERM_PROGRAM_VERSION" "1.2")
      (with-temporary-posix-environment-variable ("KITTY_WINDOW_ID" "42")
        (with-temporary-posix-environment-variable ("PATH" "not-forwarded")
          (with-temporary-posix-environment-variable ("TERM" "not-forwarded")
            (let ((identity (nerimux::%client-terminal-identity)))
              (expect (equal "kitty" (cdr (assoc "TERM_PROGRAM" identity :test #'string=))))
              (expect (equal "1.2" (cdr (assoc "TERM_PROGRAM_VERSION" identity :test #'string=))))
              (expect (equal "42" (cdr (assoc "KITTY_WINDOW_ID" identity :test #'string=))))
              (expect (null (assoc "PATH" identity :test #'string=)))
              (expect (null (assoc "TERM" identity :test #'string=)))))))))
)


  (it "run-attach-session-contains-a-genuine-timeout-from-write-frame-ready"
  (with-stubbed-fdefinition
      ((nerimux/transport:write-frame-ready
        (lambda (writer socket)
          (declare (ignore writer socket))
          (sb-ext:with-timeout 0.05 (sleep 5))))
       (nerimux/pty:select-fds
        (lambda (read-fds timeout-us &key write-fds)
          (declare (ignore read-fds timeout-us))
          (values nil write-fds))))
    (let (result reported)
      (setf reported
            (with-output-to-string (*error-output*)
              (setf result
                    (nerimux::%run-attach-session
                     nil 99 nil (nerimux::%make-client-output-queue)))))
      (expect (null result))
      (expect (search "connection lost" reported)))))


  (it "run-attach-session-contains-an-ordinary-error-from-write-frame-ready"
  (with-stubbed-fdefinition
      ((nerimux/transport:write-frame-ready
        (lambda (writer socket)
          (declare (ignore writer socket))
          (error "socket write failed")))
       (nerimux/pty:select-fds
        (lambda (read-fds timeout-us &key write-fds)
          (declare (ignore read-fds timeout-us))
          (values nil write-fds))))
    (let (result reported)
      (setf reported
            (with-output-to-string (*error-output*)
              (setf result
                    (nerimux::%run-attach-session
                     nil 99 nil (nerimux::%make-client-output-queue)))))
      (expect (null result))
      (expect (search "socket write failed" reported)))))


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
(describe "client-readiness-suite"
  (it "readiness-loop-pauses-at-output-cap-and-keeps-frame-notification-fifo"
    (with-guarded-socket-test/fd
        (:server-sock server-sock :server-stream server-stream
         :client-sock client-sock :client-fd client-fd)
      (with-pipe-fds (input-read input-write)
        (with-pipe-fds (output-read output-write)
          (let* ((queue (nerimux::%make-client-output-queue))
                 (frame-payload
                   (make-array 512 :element-type '(unsigned-byte 8)
                               :initial-contents
                               (loop for index below 512
                                     collect (+ 65 (mod index 26)))))
                 (frame-output
                   (concatenate '(simple-array (unsigned-byte 8) (*))
                                nerimux::+client-sync-begin+
                                frame-payload
                                nerimux::+client-sync-end+))
                 (prefix (make-array 3 :element-type (quote (unsigned-byte 8)) :initial-contents (quote (33 34 35))))
                 (notification (make-array 2 :element-type (quote (unsigned-byte 8)) :initial-contents (quote (110 111))))
                 (expected-output
                   (concatenate '(simple-array (unsigned-byte 8) (*))
                                prefix frame-output notification))
                 (pipe-count 0)
                 (original-select #'nerimux/pty:select-fds)
                 (select-lock (sb-thread:make-mutex :name "client select records"))
                 (select-sequence 0)
                 (select-records nil)
                 (input-flags (nerimux::%client-set-nonblocking input-read))
                 (output-read-flags
                   (nerimux::%client-set-nonblocking output-read))
                 (output-write-flags
                   (nerimux::%client-set-nonblocking output-write))
                 (thread nil)
                 (loop-condition nil))
            (labels ((read-exact (fd count)
                       (let ((result
                               (make-array count
                                           :element-type '(unsigned-byte 8)))
                             (position 0))
                         (loop while (< position count) do
                           (multiple-value-bind (ready write-ready)
                               (nerimux/pty:select-fds (list fd) 100000)
                             (declare (ignore write-ready))
                             (when (member fd ready)
                               (let ((chunk
                                       (read-octets-from-fd
                                        fd (min 4096 (- count position)))))
                                 (when chunk
                                   (replace result chunk :start1 position)
                                   (incf position (length chunk)))))))
                         result))
                     (wait-for-paused-read-set ()
                       (loop repeat 200
                             for record =
                               (sb-thread:with-mutex (select-lock)
                                 (find-if
                                  (lambda (entry)
                                    (and (member input-read (cdr entry))
                                         (not (member client-fd (cdr entry)))))
                                  select-records))
                             when record do (return record)
                             do (sleep 0.01)))
                     (wait-for-queue-empty ()
                       (loop repeat 200
                             when (and (zerop
                                        (nerimux::%client-output-queue-bytes
                                         queue))
                                       (zerop
                                        (nerimux::%client-output-queue-reserved
                                         queue)))
                               do (return t)
                             do (sleep 0.01))))
              (unwind-protect
                   (progn
                     (expect
                      (= nerimux::+client-output-limit+
                         (+ (* 64 1024 1024) 32)))
                     (setf (nerimux::%client-output-queue-limit queue)
                           (length frame-output))
                     (expect (nerimux::%client-enqueue-output queue prefix))
                     (let ((filler
                             (make-array 4096
                                         :element-type '(unsigned-byte 8)
                                         :initial-element #x5a)))
                       (loop for count =
                               (nerimux::%client-write-fd
                                output-write filler 0 (length filler))
                             while count do (incf pipe-count count)))
                     (expect (> pipe-count 5))
                     (with-stubbed-fdefinition
                         ((nerimux/pty:select-fds
                           (lambda (read-fds timeout-us &key write-fds)
                             (sb-thread:with-mutex (select-lock)
                               (incf select-sequence)
                               (push (cons select-sequence (copy-list read-fds))
                                     select-records))
                             (funcall original-select read-fds timeout-us
                                      :write-fds write-fds)))
                          (nerimux/pty:terminal-size
                           (lambda () (values 30 100)))
                          (nerimux::%client-terminal-identity
                           (lambda ()
                             (list (cons "TERM_PROGRAM" "kitty")
                                   (cons "KITTY_WINDOW_ID" "42")))))
                       (setf thread
                             (sb-thread:make-thread
                              (lambda ()
                                (let ((nerimux::*term-rows* 24)
                                      (nerimux::*term-cols* 80)
                                      (nerimux::*resize-pending* t))
                                  (handler-case
                                    (nerimux::%run-attach-session
                                     client-sock client-fd nil queue
                                     input-read output-write)
                                  (error (condition)
                                    (setf loop-condition condition)))))))
                       (multiple-value-bind (type payload)
                           (nerimux/transport:read-frame server-stream)
                         (expect (= +msg-attach+ type))
                         (multiple-value-bind (rows cols environment)
                             (nerimux/protocol:decode-attach payload)
                           (expect (= 24 rows))
                           (expect (= 80 cols))
                           (expect (equal (list (cons "TERM_PROGRAM" "kitty")
                                                (cons "KITTY_WINDOW_ID" "42"))
                                          environment))
                           (expect (null (assoc "PATH" environment
                                                :test (function string=))))
                           (expect (null (assoc "TERM" environment
                                                :test (function string=))))))
                       (multiple-value-bind (type payload)
                           (nerimux/transport:read-frame server-stream)
                         (expect (= +msg-command+ type))
                         (multiple-value-bind (command target args)
                             (nerimux/protocol:decode-command-payload payload)
                           (expect (eq :attach-target command))
                           (expect (null target))
                           (expect (stringp (first args))))
                       (multiple-value-bind (type payload)
                           (nerimux/transport:read-frame server-stream)
                         (declare (ignore payload))
                         (expect (= +msg-resize+ type)))
                       (nerimux/transport:send-frame
                        server-stream
                        (nerimux/protocol:encode-frame +msg-frame+
                                                       frame-payload))
                       (nerimux/transport:send-frame
                        server-stream
                        (nerimux/protocol:msg-notification notification))
                       (write-byte-to-fd input-write 97)
                       (multiple-value-bind (type payload)
                           (nerimux/transport:read-frame server-stream)
                         (expect (= +msg-key+ type))
                         (expect (equalp #(97) payload)))
                       (let ((paused (wait-for-paused-read-set)))
                         (expect paused :to-be-truthy)
                         (let ((pause-sequence (car paused)))
                           (multiple-value-bind (ready write-ready)
                               (nerimux/pty:select-fds (list client-fd) 0)
                             (declare (ignore write-ready))
                             (expect (member client-fd ready)))
                           (sb-posix:close input-write)
                           (multiple-value-bind (type payload)
                               (nerimux/transport:read-frame server-stream)
                             (declare (ignore payload))
                             (expect (= +msg-detach+ type)))
                           (let ((filler-bytes (read-exact output-read pipe-count)))
                             (expect
                              (every (lambda (byte) (= #x5a byte)) filler-bytes)))
                           (expect (equalp expected-output
                (read-exact output-read (length expected-output))))

                           (expect (wait-for-queue-empty))
                           (expect
                            (sb-thread:with-mutex (select-lock)
                              (some (lambda (entry)
                                      (and (> (car entry) pause-sequence)
                                           (member client-fd (cdr entry))))
                                    select-records)))
                           (nerimux/transport:send-frame
                            server-stream (nerimux/protocol:msg-bye))
                           (sb-thread:join-thread thread)
                           (setf thread nil)
                           (expect (null loop-condition))
                           (expect (zerop
                                    (nerimux::%client-output-queue-bytes queue))))))
                (when (and thread (sb-thread:thread-alive-p thread))
                  (ignore-errors (sb-posix:close input-write))
                  (ignore-errors (nerimux/net:close-socket client-sock))
                  (sb-thread:join-thread thread))
                (nerimux::%client-restore-fd-flags
                 input-read input-flags)
                (nerimux::%client-restore-fd-flags
                 output-read output-read-flags)
                (nerimux::%client-restore-fd-flags
                 output-write output-write-flags)))))))
))))
(describe "client-stdout-readiness-suite"
  (it "client-output-short-write-eagain-resumes-same-item-offset"
    (let* ((queue (nerimux::%make-client-output-queue))
           (bytes (make-array 6
                              :element-type (quote (unsigned-byte 8))
                              :initial-contents (list 97 98 99 100 101 102)))
           (item nil)
           (remaining-counts (list 3 nil 3))
           (writes nil)
           (output
             (make-array 0 :element-type (quote (unsigned-byte 8)))))
      (nerimux::%client-enqueue-output queue bytes)
      (setf item (car (nerimux::%client-output-queue-head queue)))
      (with-stubbed-fdefinition
          ((nerimux::%client-write-fd
            (lambda (fd buffer start length)
              (declare (ignore fd))
              (push (list start length) writes)
              (let ((count (pop remaining-counts)))
                (when count
                  (setf output
                        (concatenate
                         (quote (simple-array (unsigned-byte 8) (*)))
                         output
                         (subseq buffer start (+ start count)))))
                count))))
        (nerimux::%client-write-output-ready queue 71)
        (expect (= 3 (nerimux::%client-output-item-offset item)))
        (expect (= 3 (nerimux::%client-output-queue-bytes queue)))
        (nerimux::%client-write-output-ready queue 71)
        (expect (= 3 (nerimux::%client-output-item-offset item)))
        (expect (= 3 (nerimux::%client-output-queue-bytes queue)))
        (nerimux::%client-write-output-ready queue 71)
        (expect (equalp #(97 98 99 100 101 102) output))
        (expect (equal (quote ((0 6) (3 3) (3 3)))
                       (nreverse writes)))
        (expect (= 6 (nerimux::%client-output-item-offset item)))
        (expect (null (nerimux::%client-output-queue-head queue)))
        (expect (zerop (nerimux::%client-output-queue-bytes queue))))))
  (it "run-client-detach-with-unwritable-stdout-restores-terminal-and-fds"
    (let ((events nil)
          (timed-out nil))
      (handler-case
          (sb-ext:with-timeout 0.2
            (with-stubbed-fdefinition
                ((nerimux::socket-path
                  (lambda (name)
                    (declare (ignore name))
                    "/tmp/nerimux-test-client.sock"))
                 (nerimux/net:connect-to
                  (lambda (path)
                    (declare (ignore path))
                    :socket))
                 (nerimux/net:socket-fd
                  (lambda (socket)
                    (declare (ignore socket))
                    99))
                 (nerimux/pty:terminal-size
                  (lambda () (values 24 80)))
                 (nerimux::install-sigwinch-handler (lambda () nil))
                 (nerimux/pty:enable-raw-mode!
                  (lambda (fd)
                    (declare (ignore fd))
                    (push :raw-enabled events)))
                 (nerimux/pty:disable-raw-mode!
                  (lambda (fd)
                    (declare (ignore fd))
                    (push :raw-disabled events)))
                 (nerimux::%client-fd-flags
                  (lambda (fd)
                    (if (= fd 0) 10 20)))
                 (nerimux::%client-set-nonblocking
                  (lambda (fd)
                    (declare (ignore fd))
                    nil))
                 (nerimux::%client-restore-fd-flags
                  (lambda (fd flags)
                    (push (list :fd-restored fd flags) events)))
                 (nerimux/pty:select-fds
                  (lambda (read-fds timeout-us &key write-fds)
                    (declare (ignore read-fds timeout-us))
                    (push (list :write-fd-waited write-fds) events)
                    (values nil nil)))
                 (nerimux::%client-write-fd
                  (lambda (fd bytes start length)
                    (declare (ignore fd bytes start length))
                    (push :stdout-blocked events)
                    nil))
                 (nerimux::%run-attach-session
                  (lambda (socket fd target queue &optional input-fd output-fd)
                    (declare (ignore socket fd target queue input-fd output-fd))
                    (push :detached events)
                    nil))
                 (nerimux/net:close-socket
                  (lambda (&rest args)
                    (declare (ignore args))
                    (push :socket-closed events))))
              (nerimux::run-client "7")))
        (sb-ext:timeout () (setf timed-out t)))
      (expect (not timed-out))
      (expect (member (list :write-fd-waited (list 1)) events
                       :test (function equal))
              :to-be-truthy)
      (expect (member :detached events) :to-be-truthy)
      (expect (member :raw-enabled events) :to-be-truthy)
      (expect (member :raw-disabled events) :to-be-truthy)
      (expect (member (list :fd-restored 0 10) events :test (function equal))
              :to-be-truthy)
      (expect (member (list :fd-restored 1 20) events :test (function equal))
              :to-be-truthy)
      (expect (member :socket-closed events) :to-be-truthy))))
