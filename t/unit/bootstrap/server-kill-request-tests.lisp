(in-package #:nerimux/test)

;;;; R8.1: `nerimux kill` server-side decision (%server-kill-request,
;;;; %force-kill-panes, server-multi-loop.lisp) and CLI-side exit-code mapping
;;;; (run-kill, main-startup-commands.lisp).
;;;;
;;;; NOTE for team-lead: this file does NOT exercise `nerimux kill` end to
;;;; end over a real socket. %handle-client-ui-command
;;;; (server-multi-dispatch.lisp) has no case for CMD :kill, so a `:kill`
;;;; +msg-command+ frame falls into %handle-multi-command-message's "unknown
;;;; command" branch and no +msg-reply+ is ever sent -- confirmed by grepping
;;;; src/ for "OK"/"DENIED"/+msg-reply+ senders: client.lisp's
;;;; send-kill-request (:130-176) is the only place that constructs or reads
;;;; a kill +msg-reply+, and nothing on the server side produces one.
;;;; server-multi-loop.lisp:71-84's own comment already flags this as
;;;; unfinished wiring ("out of this file's scope -- see the report to
;;;; team-lead"). A real `nerimux kill` today hangs until read-frame's own
;;;; timeout and reports "no reply from server". Per §6's requirement for a
;;;; byte-stream-driven integration test, that test cannot be written until
;;;; the :kill case is added to %handle-client-ui-command and something sends
;;;; the +msg-reply+ client.lisp expects. The tests below cover R8.1 at the
;;;; function boundary on both sides of that gap instead: %server-kill-request
;;;; (what the missing dispatch case needs to call) and run-kill (what
;;;; already correctly calls send-kill-request and maps its result to an exit
;;;; code).

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
  (it "r8-1-force-kill-panes-sighups-then-sigkills-only-panes-still-alive-after-the-grace-period"
    (let* ((still-alive (make-pane :id 1 :fd -1 :pid 424242 :screen (make-screen 10 3)))
           (already-dead (make-pane :id 2 :fd -1 :pid 424243 :screen (make-screen 10 3)))
           (closed nil)
           (kills nil))
      (with-stubbed-fdefinition
          ((nerimux::close-pane-pty
            (lambda (pane) (push pane closed) nil))
           (sb-posix:kill
            (lambda (pid signal)
              (push (list pid signal) kills)
              (when (and (= signal 0) (= pid 424243))
                (error "ESRCH: no such process (stubbed)"))
              nil)))
        (nerimux::%force-kill-panes (list still-alive already-dead)))
      (expect (= 2 (length closed))
              )
      (expect (equal (list (list 424242 0)
                           (list 424243 0)
                           (list 424242 sb-posix:sigkill))
                     (nreverse kills))
              )))

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
  ;; to retry with --force.
  (it "r8-1-run-kill-exits-one-and-lists-panes-when-denied"
    (let ((orig (fdefinition 'nerimux::send-kill-request))
          exit-code errout)
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux::send-kill-request)
                   (lambda (name force-p)
                     (declare (ignore name force-p))
                     (values :denied "pane 1 (pid 123) in /tmp/wt")))
             (setf errout
                   (with-output-to-string (*error-output*)
                     (%with-stubbed-run-kill-exit exit-code
                       (nerimux::run-kill nil)))))
        (setf (fdefinition 'nerimux::send-kill-request) orig))
      (expect (eql 1 exit-code))
      (expect (search "pane 1 (pid 123)" errout) :to-be-truthy)
      (expect (search "--force" errout) :to-be-truthy)))

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
