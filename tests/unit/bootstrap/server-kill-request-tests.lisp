(in-package #:nerimux/test)

;;;; R8.1: `nerimux kill` server-side decision and client-side reply mapping.
;;;; Socket I/O stays at the transport seams here; dispatch and exit-code tests
;;;; cover the protocol contract without depending on a live daemon.

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
         (setf (fdefinition 'sb-ext:exit)
               (lambda (&rest args &key (code 0) &allow-other-keys)
                 (declare (ignore args))
                 (setf ,code-var code)
                 (throw ',tag nil)))
         (unwind-protect
              (catch ',tag ,@body)
           (setf (fdefinition 'sb-ext:exit) ,orig))))))

(describe "server-kill-request-suite"

  ;; %session-live-panes: only fd > 0 panes count, matching pane-live-p.
  (it "session-live-panes-filters-to-live-fds-only"
    (let* ((live (make-pane :id 1 :fd 9999 :pid -1 :screen (make-screen 10 3)))
           (dead (make-pane :id 2 :fd -1 :pid -1 :screen (make-screen 10 3)))
           (win (make-window :id 1 :name "w" :panes (list live dead)
                             :tree (make-layout-split :h (make-layout-leaf live)
                                                       (make-layout-leaf dead) 1/2)))
           (session (make-session :id 1 :name "0" :windows (list win))))
      (expect (equal (list live) (nerimux::%session-live-panes session)))))

  ;; R8.1: a plain (non-forced) request with a live pane is refused, listing
  ;; that pane, and never touches *running*.
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
    (let* ((worktree (nerimux/model:make-worktree
                       :id "wt" :path "/tmp/worktree" :branch "feature"))
           (pane (make-pane :id 7 :fd 9999 :pid 1234
                            :worktree worktree
                            :screen (make-screen 10 3))))
      (expect (string= "pane 7 (pid 1234) in /tmp/worktree"
                       (nerimux::%pane-kill-description pane)))))

  ;; With no live panes at all, even a non-forced request just stops.
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

  ;; --force with live panes routes them to %force-kill-panes (verified as a
  ;; declared seam, not by waiting out its own grace period here -- that
  ;; escalation is tested directly below) and then stops the server.
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

  ;; R8.1's escalation itself: close-pane-pty (the SIGHUP-equivalent teardown
  ;; every other pane-close call site already uses) runs on every pane up
  ;; front; after the grace period, only a pane still alive gets SIGKILL.
  ;; %process-alive-p and sb-posix:kill are both stubbed so no real signal is
  ;; ever sent to a real process -- the "still alive" and "already dead"
  ;; outcomes are simulated by pid rather than by racing a real process
  ;; against the grace timer.
  ;;
  ;; This test incurs the real +kill-sighup-grace-seconds+ (3s) wait:
  ;; that constant is a DEFCONSTANT (not a rebindable special), and CL/SB-EXT
  ;; is a locked package so CL:SLEEP itself cannot be stubbed the way
  ;; SB-EXT:EXIT is above. The wait is the literal behaviour under test
  ;; (grace period elapses, THEN escalation is decided), not a
  ;; synchronization device standing in for it, so measuring it directly
  ;; once is the correct call per testing-patterns' asynchrony guidance
  ;; rather than a bug to route around.
  ;; The signal sequence itself cannot be observed by redefining SB-POSIX:KILL.
  ;; sb-posix's syscall wrappers are inline, so the call sites in
  ;; %FORCE-KILL-PANES and %PROCESS-ALIVE-P were compiled to direct alien calls
  ;; and never consult the symbol's function cell -- an earlier version of this
  ;; test stubbed it, recorded nothing, and asserted on the empty list.
  ;; CLOSE-PANE-PTY is an ordinary function and does stub, so what is asserted
  ;; here is the teardown pass plus the liveness predicate the escalation reads,
  ;; each against something real.
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
    ;; Our own process is alive; a pid above the system maximum cannot be.
    (expect (nerimux::%process-alive-p (sb-posix:getpid)))
    (expect (not (nerimux::%process-alive-p 999999)))
    ;; A pid that is not a pid at all is "gone", not an error.
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

  ;;; ── run-kill: CLI exit-code / message mapping ─────────────────────────────

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

  ;; R8.1: refused (live panes, no --force) -> exit 1, panes listed, and told
  ;; to retry with --force.  The stubbed text below is the real wire shape
  ;; (server-multi-dispatch-command.lisp: (format nil "DENIED~{~%~A~}"
  ;; descriptions)), not just the pane-list tail, so this test exercises
  ;; run-kill's F5 fix: the "DENIED" status-token line %parse-kill-reply-
  ;; status already consumed must not leak into what the user sees.
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
      ;; F5: the wire status token is protocol internals, not user-facing text.
      (expect (search "DENIED" errout) :to-be-falsy)))

  ;; F5, multi-pane: the status line strip must remove only the first line,
  ;; leaving every pane in a multi-pane refusal intact.
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

  ;; F3/cycle-3 fix: no server running at all -- send-kill-request
  ;; (client.lisp) catches SB-BSD-SOCKETS:SOCKET-ERROR itself, narrowly
  ;; around its own connect-to step, and reports this as (values :no-server
  ;; nil); stubbed here at the send-kill-request seam like every other
  ;; run-kill test in this file (see r8-1-run-kill-exits-zero-... above),
  ;; rather than reaching into connect-to, to match this file's established
  ;; style of testing run-kill's status dispatch as a black box over
  ;; send-kill-request's return value.  run-kill must turn :no-server into a
  ;; clean one-line message on *error-output* and exit 1, never the raw
  ;; "Socket error in ...: 2 (No such file or directory)" report.
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

  ;; cycle-3 fix: a SOCKET-ERROR signalled by send-kill-request AFTER a
  ;; successful connect (e.g. an ECONNRESET while reading the reply) is a
  ;; mid-session failure, not "no server running" -- run-kill must not
  ;; mislabel it, and must not catch it at all. Before this fix, run-kill
  ;; wrapped its whole body in a socket-error handler that printed "no
  ;; server running" for this case too; now the condition is left to
  ;; propagate to main()'s generic top-level handler-case, so this test
  ;; asserts it escapes run-kill uncaught (catching it here only to assert
  ;; on it, not because run-kill does).
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

  ;; No reply at all (:eof) is also a non-zero exit, distinct message.
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

  ;; --force is run-kill's own argument (parsed here, not by *cli-app*'s
  ;; global flags -- 1.6/R1.17) and must reach send-kill-request as T.
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

  ;; Without --force, the session name is still "0" (R1.5: session fixed to
  ;; one) and force-p is NIL.
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
      (expect (equal (list "0" nil) captured)))))
