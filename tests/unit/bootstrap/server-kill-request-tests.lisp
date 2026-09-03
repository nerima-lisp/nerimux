(in-package #:nerimux/test)

(defmacro %with-stubbed-run-kill-exit (code-var &body body)
  "Local copy of main-entry-tests.lisp's WITH-STUBBED-EXIT idiom (not shared
   across files here -- see execution-workflow on load-order-independent
   test files): sb-ext:exit terminates the process, so it must be stubbed to
   capture :code and unwind via THROW instead of actually exiting the test
   runner. Uses WITHOUT-PACKAGE-LOCKS because SB-EXT is a locked package."
  (let ((tag (gensym "EXIT-TAG"))
        (orig (gensym "ORIG-EXIT")))
    `(sb-ext:without-package-locks
      (let ((,orig (fdefinition 'sb-ext:exit)))
        (setf (fdefinition 'sb-ext:exit) (lambda 
                                             (&rest args
                                                    &key
                                                    (code 0)
                                                    &allow-other-keys)
                                           (declare (ignore args))
                                           (setf ,code-var code)
                                           (throw ',tag
                                             nil)))
        (unwind-protect 
            (catch ',tag
              ,@body)
          (setf (fdefinition 'sb-ext:exit) ,orig))))))

(describe "server-kill-request-suite"

  (it "session-live-panes-filters-to-live-fds-only"
    (let* ((live (make-pane :id 1 :fd 9999 :pid -1 :screen (make-screen 10 3)))
           (dead (make-pane :id 2 :fd -1 :pid -1 :screen (make-screen 10 3)))
           (win (make-window :id 1 :name "w" :panes (list live dead)
                             :tree (make-layout-split :h (make-layout-leaf live)
                                                       (make-layout-leaf dead) 1/2)))
           (session (make-session :id 1 :name "0" :windows (list win))))
      (expect (equal (list live) (nerimux::%session-live-panes session)))))

  (it "r8-1-refuses-when-live-panes-exist-without-force"
    (with-global-running t
      (let* ((live (make-pane :id 3 :fd 9999 :pid -1 :screen (make-screen 10 3)))
             (win (make-window :id 1 :name "w" :panes (list live)
                               :tree (make-layout-leaf live)))
             (session (make-session :id 1 :name "0" :windows (list win))))
        (multiple-value-bind (status descriptions)
            (nerimux::%server-kill-request session nil)
          (expect (eq :denied status))
          (expect (= 1 (length descriptions)))
          (expect (search "pane 3" (first descriptions)) :to-be-truthy))
        (expect nerimux::*running* :to-be-truthy))))

  (it "r8-1-pane-kill-description-includes-worktree-path"
    (let* ((worktree (nerimux/workspace-model:make-worktree
                       :id "wt" :path "/tmp/worktree" :branch "feature"))
           (pane (make-pane :id 7 :fd 9999 :pid 1234
                            :worktree worktree
                            :screen (make-screen 10 3))))
      (expect (string= "pane 7 (pid 1234) in /tmp/worktree"
                       (nerimux::%pane-kill-description pane)))))

  (it "r8-1-stops-immediately-when-no-panes-are-live-even-without-force"
    (with-global-running t
      (let* ((dead (make-pane :id 1 :fd -1 :pid -1 :screen (make-screen 10 3)))
             (win (make-window :id 1 :name "w" :panes (list dead)
                               :tree (make-layout-leaf dead)))
             (session (make-session :id 1 :name "0" :windows (list win))))
        (multiple-value-bind (status descriptions)
            (nerimux::%server-kill-request session nil)
          (expect (eq :ok status))
          (expect (null descriptions)))
        (expect nerimux::*running* :to-be-falsy))))

  (it "r8-1-force-routes-live-panes-to-force-kill-panes-then-stops"
    (with-global-running t
      (let* ((live (make-pane :id 1 :fd 9999 :pid -1 :screen (make-screen 10 3)))
             (win (make-window :id 1 :name "w" :panes (list live)
                               :tree (make-layout-leaf live)))
             (session (make-session :id 1 :name "0" :windows (list win)))
             (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%force-kill-panes
              (lambda (panes) (push panes calls))))
          (multiple-value-bind (status descriptions)
              (nerimux::%server-kill-request session t)
            (expect (eq :ok status))
            (expect (null descriptions))))
        (expect (equal (list (list live)) calls))
        (expect nerimux::*running* :to-be-falsy))))

  (it "r8-1-force-kill-panes-hangs-up-every-pane-before-escalating"
    (let* ((one (make-pane :id 1 :fd -1 :pid 424242 :screen (make-screen 10 3)))
           (two (make-pane :id 2 :fd -1 :pid 424243 :screen (make-screen 10 3)))
           (closed nil))
      (with-stubbed-fdefinition
          ((nerimux::close-pane-pty
            (lambda (pane) (push pane closed) nil)))
        (nerimux::%force-kill-panes (list one two)))
      (expect (= 2 (length closed)))
      (expect (equal (list one two) (nreverse closed)))))

  (it "r8-1-process-alive-p-answers-for-real-pids"
    (expect (nerimux::%process-alive-p (sb-posix:getpid)))
    (expect (not (nerimux::%process-alive-p 999999)))
    (expect (not (nerimux::%process-alive-p 0)))
    (expect (not (nerimux::%process-alive-p -1)))
    (expect (not (nerimux::%process-alive-p nil))))

  (it "r8-1-read-kill-reply-skips-broadcasts-and-decodes-replies"
    (let ((frames (list (list +msg-frame+ #(1 2))
                        (list +msg-reply+ #(3 4))))
          (decoded-payload nil))
      (with-stubbed-fdefinition
          ((nerimux/transport:read-frame
            (lambda (stream)
              (declare (ignore stream))
              (destructuring-bind (type payload) (pop frames)
                (values type payload))))
           (nerimux/protocol:decode-text
            (lambda (payload)
              (setf decoded-payload payload)
              (format nil "OK~%server stopped"))))
        (multiple-value-bind (disposition text)
            (nerimux::%read-kill-reply :stream)
          (expect (eq :reply disposition))
          (expect (string= (format nil "OK~%server stopped") text))))
      (expect (equalp #(3 4) decoded-payload))))

  (it "r8-1-read-kill-reply-treats-bye-and-eof-as-no-reply"
    (dolist (terminal-frame (list (list +msg-bye+ nil)
                                  (list nil nil)))
      (let ((frames (list terminal-frame)))
        (with-stubbed-fdefinition
            ((nerimux/transport:read-frame
              (lambda (stream)
                (declare (ignore stream))
                (destructuring-bind (type payload) (pop frames)
                  (values type payload)))))
          (multiple-value-bind (disposition text)
              (nerimux::%read-kill-reply :stream)
            (expect (eq :eof disposition))
            (expect (null text)))))))

  (it "r8-1-parse-kill-reply-fails-closed"
    (dolist (case (list (cons "OK" :ok)
                        (cons (format nil "OK~%server stopped") :ok)
                        (cons (format nil "DENIED~%pane 1") :denied)
                        (cons (format nil "OKAY~%not an acknowledgement") :denied)
                        (cons "" :denied)))
      (expect (eq (cdr case)
                  (nerimux::%parse-kill-reply-status (car case))))))

  (it "r8-1-send-kill-request-encodes-force-and-closes-the-socket"
    (let ((path nil)
          (sent nil)
          (closed nil))
      (with-stubbed-fdefinition
          ((nerimux::socket-path
            (lambda (name)
              (setf path name)
              "/tmp/nerimux-test.sock"))
           (nerimux/net:connect-to
            (lambda (socket-path)
              (declare (ignore socket-path))
              :socket))
           (nerimux/net:socket-stream
            (lambda (socket)
              (declare (ignore socket))
              :stream))
           (nerimux/protocol:msg-command
            (lambda (command target args)
              (list command target args)))
           (nerimux/transport:send-frame
            (lambda (stream frame)
              (setf sent (list stream frame))))
           (nerimux::%read-kill-reply
            (lambda (stream)
              (declare (ignore stream))
              (values :reply (format nil "OK~%server stopped"))))
           (nerimux/net:close-socket
            (lambda (socket)
              (setf closed socket))))
        (multiple-value-bind (status text)
            (nerimux::send-kill-request "0" t)
          (expect (eq :ok status))
          (expect (string= (format nil "OK~%server stopped") text))))
      (expect (string= "0" path))
      (expect (equal (list :stream (list :kill nil (list "--force"))) sent))
      (expect (eq :socket closed))))

  (it "r8-1-send-kill-request-returns-eof-without-force"
    (let ((command nil))
      (with-stubbed-fdefinition
          ((nerimux::socket-path (lambda (name) (declare (ignore name)) "/tmp/test"))
           (nerimux/net:connect-to (lambda (path) (declare (ignore path)) :socket))
           (nerimux/net:socket-stream (lambda (socket) (declare (ignore socket)) :stream))
           (nerimux/protocol:msg-command
            (lambda (name target args)
              (setf command (list name target args))
              :command))
           (nerimux/transport:send-frame (lambda (stream frame)
                                           (declare (ignore stream frame))))
           (nerimux::%read-kill-reply (lambda (stream)
                                        (declare (ignore stream))
                                        (values :eof nil)))
           (nerimux/net:close-socket (lambda (socket)
                                       (declare (ignore socket)))))
        (multiple-value-bind (status text)
            (nerimux::send-kill-request "0" nil)
          (expect (eq :eof status))
          (expect (null text))))
      (expect (equal (list :kill nil nil) command))))

  (it "r8-1-send-kill-request-maps-peer-io-failure-to-eof-and-closes-socket"
    (let ((closed nil)
          (read-kill-reply-called nil))
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
            (lambda (&rest args)
              (declare (ignore args))
              (error 'nerimux::peer-io-failure)))
           (nerimux::%read-kill-reply
            (lambda (stream)
              (declare (ignore stream))
              (setf read-kill-reply-called t)
              (values :reply "OK~%"))))
        (multiple-value-bind (status text) (nerimux::send-kill-request "0" nil)
          (expect (eq :eof status))
          (expect (null text))))
      (expect closed)
      (expect (null read-kill-reply-called))))


  (it "r8-1-run-kill-exits-zero-when-send-kill-request-reports-ok"
    (let ((orig (fdefinition 'nerimux::send-kill-request))
          exit-code)
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux::send-kill-request)
                   (lambda (name force-p)
                     (declare (ignore name force-p))
                     (values :ok "")))
             (%with-stubbed-run-kill-exit exit-code
               (nerimux::run-kill nil)))
        (setf (fdefinition 'nerimux::send-kill-request) orig))
      (expect (eql 0 exit-code))))

  (it "r8-1-run-kill-exits-one-and-lists-panes-when-denied"
    (let ((orig (fdefinition 'nerimux::send-kill-request))
          exit-code errout)
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux::send-kill-request)
                   (lambda (name force-p)
                     (declare (ignore name force-p))
                     (values :denied (format nil "DENIED~%pane 1 (pid 123) in /tmp/wt"))))
             (setf errout
                   (with-output-to-string (*error-output*)
                     (%with-stubbed-run-kill-exit exit-code
                       (nerimux::run-kill nil)))))
        (setf (fdefinition 'nerimux::send-kill-request) orig))
      (expect (eql 1 exit-code))
      (expect (search "pane 1 (pid 123)" errout) :to-be-truthy)
      (expect (search "--force" errout) :to-be-truthy)
      (expect (search "DENIED" errout) :to-be-falsy)))

  (it "r8-1-run-kill-strips-only-the-status-line-with-multiple-panes-denied"
    (let ((orig (fdefinition 'nerimux::send-kill-request))
          exit-code errout)
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux::send-kill-request)
                   (lambda (name force-p)
                     (declare (ignore name force-p))
                     (values :denied (format nil "DENIED~%pane 1 (pid 123) in /tmp/wt~%pane 2 (pid 456) in /tmp/wt"))))
             (setf errout
                   (with-output-to-string (*error-output*)
                     (%with-stubbed-run-kill-exit exit-code
                       (nerimux::run-kill nil)))))
        (setf (fdefinition 'nerimux::send-kill-request) orig))
      (expect (eql 1 exit-code))
      (expect (search "pane 1 (pid 123)" errout) :to-be-truthy)
      (expect (search "pane 2 (pid 456)" errout) :to-be-truthy)
      (expect (search "DENIED" errout) :to-be-falsy)))

  (it "r8-1-run-kill-reports-a-clean-message-and-exits-one-when-no-server-is-running"
    (let ((orig (fdefinition 'nerimux::send-kill-request))
          exit-code errout)
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux::send-kill-request)
                   (lambda (name force-p)
                     (declare (ignore name force-p))
                     (values :no-server nil)))
             (setf errout
                   (with-output-to-string (*error-output*)
                     (%with-stubbed-run-kill-exit exit-code
                       (nerimux::run-kill nil)))))
        (setf (fdefinition 'nerimux::send-kill-request) orig))
      (expect (eql 1 exit-code))
      (expect (search "no server running" errout) :to-be-truthy)
      (expect (search "Socket error" errout) :to-be-falsy)))

  (it "r8-1-run-kill-does-not-mislabel-a-mid-session-socket-error-as-no-server-running"
    (let ((orig (fdefinition 'nerimux::send-kill-request))
          exit-code errout signalled)
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux::send-kill-request)
                   (lambda (name force-p)
                     (declare (ignore name force-p))
                     (error 'sb-bsd-sockets:socket-error
                            :syscall "read" :errno 104)))
             (setf errout
                   (with-output-to-string (*error-output*)
                     (handler-case
                         (%with-stubbed-run-kill-exit exit-code
                           (nerimux::run-kill nil))
                       (sb-bsd-sockets:socket-error () (setf signalled t))))))
        (setf (fdefinition 'nerimux::send-kill-request) orig))
      (expect signalled)
      (expect (null exit-code))
      (expect (search "no server running" errout) :to-be-falsy)))

  (it "r8-1-run-kill-exits-one-with-no-reply-message-on-eof"
    (let ((orig (fdefinition 'nerimux::send-kill-request))
          exit-code errout)
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux::send-kill-request)
                   (lambda (name force-p)
                     (declare (ignore name force-p))
                     (values :eof nil)))
             (setf errout
                   (with-output-to-string (*error-output*)
                     (%with-stubbed-run-kill-exit exit-code
                       (nerimux::run-kill nil)))))
        (setf (fdefinition 'nerimux::send-kill-request) orig))
      (expect (eql 1 exit-code))
      (expect (search "no reply from server" errout) :to-be-truthy)))

  (it "r8-1-run-kill-force-flag-is-parsed-and-forwarded"
    (let ((orig (fdefinition 'nerimux::send-kill-request))
          exit-code captured)
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux::send-kill-request)
                   (lambda (name force-p)
                     (setf captured (list name force-p))
                     (values :ok "")))
             (%with-stubbed-run-kill-exit exit-code
               (nerimux::run-kill (list "--force"))))
        (setf (fdefinition 'nerimux::send-kill-request) orig))
      (expect (equal (list "0" t) captured))
      (expect (eql 0 exit-code))))

  (it "r8-1-run-kill-without-force-flag-passes-nil-force-p"
    (let ((orig (fdefinition 'nerimux::send-kill-request))
          exit-code captured)
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux::send-kill-request)
                   (lambda (name force-p)
                     (setf captured (list name force-p))
                     (values :ok "")))
             (%with-stubbed-run-kill-exit exit-code
               (nerimux::run-kill nil)))
        (setf (fdefinition 'nerimux::send-kill-request) orig))
      (expect (equal (list "0" nil) captured))))

  (it "r8-3-client-dispositions-apply-quit-and-drop-actions"
    (let ((calls nil)
          (conn :connection))
      (with-stubbed-fdefinition
          ((nerimux::%drop-client
            (lambda (client reason force-p)
              (push (list client reason force-p) calls))))
        (expect (eq :quit
                    (nerimux::%apply-client-disposition :quit conn)))
        (expect (null (nerimux::%apply-client-disposition :eof conn)))
        (expect (null (nerimux::%apply-client-disposition :drop conn)))
        (expect (null (nerimux::%apply-client-disposition :unknown conn))))
      (expect (equal '(:connection :bye t) (first calls)))
      (expect (equal '(:connection :bye nil) (second calls)))
      (expect (= 2 (length calls))))))
