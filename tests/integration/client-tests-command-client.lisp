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
         (*error-output* (make-string-output-stream)))
     (with-stubbed-fdefinition
         ((nerimux::socket-path
           (lambda (name)
             (declare (ignore name))
             "/tmp/nerimux-test-client.sock"))
          (nerimux/net:connect-to
           (lambda (path)
             (declare (ignore path))
             :socket))
          (nerimux/net:socket-stream
           (lambda (socket)
             (declare (ignore socket))
             :stream))
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
             nil))
          (nerimux/pty:disable-raw-mode!
           (lambda (fd)
             (declare (ignore fd))
             nil))
          (nerimux/net:close-socket
           (lambda (socket)
             (declare (ignore socket))
             nil))
          (nerimux::%run-attach-session
           (lambda (stream fd target)
             (declare (ignore stream fd target))
             ,@attach-body)))
       (nerimux::run-client "7"))))

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
               (lambda ()
                 (values 24 80)))
              (nerimux::install-sigwinch-handler
               (lambda () nil))
              (nerimux/pty:enable-raw-mode!
               (lambda (fd)
                 (declare (ignore fd))
                 nil))
              (nerimux/pty:disable-raw-mode!
               (lambda (fd)
                 (declare (ignore fd))
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
           (nerimux/renderer:enable-host-modes
            (lambda () (push :host-mode-enable events) nil))
           (nerimux/renderer:disable-host-modes
            (lambda () (push :host-mode-disable events) nil))
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
      (expect (member :host-mode-enable events) :to-be-truthy)
      (expect (member :host-mode-disable events) :to-be-truthy)
      (expect (member '(:raw-enable 0) events :test #'equal) :to-be-truthy)
      (expect (member '(:raw-disable 0) events :test #'equal) :to-be-truthy)
      (expect (member '(:attach :stream 99 "target") events :test #'equal)
              :to-be-truthy)
      (expect (member '(:close :socket) events :test #'equal) :to-be-truthy)))

  (it "run-client-detach-server-drop-cleans-up-host-modes"
    (let ((output
            (with-connected-client-host-output
                ((let ((conn (nerimux::%make-client-conn
                               :socket server-sock
                               :stream server-stream
                               :fd (socket-fd server-sock))))
                   (let ((nerimux::*clients* (list conn)))
                     (with-stubbed-fdefinition
                         ((nerimux/net:close-socket
                           (lambda (&rest args)
                             (declare (ignore args))
                             nil)))
                       (let ((disposition
                               (nerimux::%handle-multi-client-message
                                +msg-detach+ #() :session conn)))
                         (expect (eq :drop disposition))
                         (expect (null
                                  (nerimux::%apply-client-disposition
                                   disposition conn))))))))
              (nerimux::run-client "7"))))
      (expect (string= (%expected-client-host-output) output))))

  (it "run-client-peer-io-failure-cleans-up-host-modes"
    (let ((output
            (with-stubbed-fdefinition
                ((nerimux/transport:send-frame
                  (lambda (&rest args)
                    (declare (ignore args))
                    (error "peer write failed"))))
              (with-connected-client-host-output
                  ()
                (nerimux::run-client "7")))))
      (expect (string= (%expected-client-host-output) output))))

  (it "run-client-server-eof-cleans-up-host-modes"
    (let ((output
            (with-stubbed-fdefinition
                ((nerimux/transport:send-frame
                  (lambda (&rest args)
                    (declare (ignore args))
                    nil)))
              (with-connected-client-host-output
                  ((close-socket server-sock))
                (nerimux::run-client "7")))))
      (expect (string= (%expected-client-host-output) output))
      (expect (search (%host-mode-sequence nil) output))))

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

  (it "run-attach-session-sends-only-allow-listed-terminal-identity"
    (let ((frames nil))
      (with-temporary-posix-environment-variable ("TERM_PROGRAM" "kitty")
        (with-temporary-posix-environment-variable ("TERM_PROGRAM_VERSION" "1.2")
          (with-temporary-posix-environment-variable ("KITTY_WINDOW_ID" "42")
            (with-temporary-posix-environment-variable ("PATH" "not-forwarded")
              (with-stubbed-fdefinition
                  ((nerimux/transport:send-frame
                    (lambda (stream frame)
                      (declare (ignore stream))
                      (push frame frames)))
                   (nerimux/pty:select-fds
                    (lambda (fds timeout-us)
                      (declare (ignore fds timeout-us))
                      '(99)))
                   (nerimux::%receive-if-ready
                    (lambda (stream fd ready)
                      (declare (ignore stream fd ready))
                      :exit)))
                (nerimux::%run-attach-session nil 99 nil)))))
      (let ((frames (nreverse frames)))
        (expect (= 2 (length frames)))
        (multiple-value-bind (type payload) (decode-frame (first frames))
          (expect (= +msg-attach+ type))
          (multiple-value-bind (rows cols environment) (decode-attach payload)
            (expect (= 24 rows))
            (expect (= 80 cols))
            (expect (equal "kitty" (cdr (assoc "TERM_PROGRAM" environment :test #'string=))))
            (expect (equal "1.2" (cdr (assoc "TERM_PROGRAM_VERSION" environment :test #'string=))))
            (expect (equal "42" (cdr (assoc "KITTY_WINDOW_ID" environment :test #'string=))))
            (expect (null (assoc "PATH" environment :test #'string=)))
            (expect (null (assoc "TERM" environment :test #'string=)))))))))


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
        (expect (null result))
        (expect (search "connection lost" reported)))))

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
