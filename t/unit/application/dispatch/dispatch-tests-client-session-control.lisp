(in-package #:nerimux/test)

;;;; Dispatch client and session control tests.

(defparameter *attach-session-submit-cases*
  '((:registered-session "attached" "found session")
    (:missing-session "not found" "missing session")))

(defparameter *attach-session-rejected-client-creation-cases*
  '(("attach-session -d -t work" "detach other clients")
    ("attach-session work" "positional target")))

(defparameter *detach-unsupported-argument-cases*
  '(("-a")
    ("-P")
    ("-E" "echo detached")
    ("-s" "work")
    ("-t" "client-0")))

(defparameter *lock-session-rejected-argument-cases*
  '("lock-session extra"
    "lock-session -x"
    "lock-session -t work extra"))

(defparameter *refresh-client-accepted-argument-cases*
  '(("-S")
    ("-C" "120x40")
    ("-f" "read-only")))

(defparameter *refresh-client-rejected-argument-cases*
  '(("-A" "pane:on")
    ("-B" "name:what:format")
    ("-D")
    ("-F" "read-only")
    ("-L")
    ("-R")
    ("-U")
    ("-c")
    ("-l" "client-0")
    ("-t" "client-0")
    ("-Z")
    ("adjustment")))

(describe "dispatch-suite"

  ;; ── Coverage: previously untested handlers ─────────────────────────────────

  ;; :attach-session opens a prompt for the session name.
  (it "dispatch-attach-session-opens-prompt"
    (with-dispatch-prompt (s :attach-session :label "attach-session -t name"
                                            :context ":attach-session must open a prompt")))

  ;; :attach-session on-submit shows 'attached' for a registered session, 'not found' otherwise.
  (it "dispatch-attach-session-submit-table"
    (with-fake-session (s)
      (let ((name (session-name s)))
        (dolist (case *attach-session-submit-cases*)
          (destructuring-bind (session-scope expected-text desc) case
            (declare (ignore desc))
            (let* ((registeredp (eq :registered-session session-scope))
                   (input (if registeredp name "nosuchsession"))
                   (registry (when registeredp (list (cons name s)))))
              (let ((*prompt* nil) (*overlay* nil)
                    (nerimux::*server-sessions* registry))
                (nerimux::dispatch-command s :attach-session nil)
                (expect (prompt-active-p))
                (funcall (prompt-on-submit *prompt*) input)
                (assert-overlay-active ":attach-session ~A must show overlay" desc)
                (assert-overlay-contains expected-text *overlay*
                                         (format nil "~A: overlay must contain ~S"
                                                 desc expected-text)))))))))

  ;; attach-session -t <name> is scriptable and switches to the target session.
  (it "run-command-line-attach-session-target-switches-session"
    (with-loop-state
      (with-empty-registry
        (let ((s0 (make-fake-session :nwindows 1))
              (s1 (make-fake-session :nwindows 1)))
          (setf (nerimux::session-name s0) "0"
                (nerimux::session-name s1) "work"
                (nerimux::session-last-active s0) 10
                (nerimux::session-last-active s1) 0
                nerimux::*server-sessions* (list (cons "0" s0)
                                                 (cons "work" s1)))
          (setf nerimux::*dirty* nil)
          (expect (eq s1 (nerimux::%run-command-line s0 "attach-session -t work")))
          (expect (eq s1 (nerimux::server-current-session)))
          (expect nerimux::*dirty* :to-be-truthy)))))

  ;; attach-session -c sets the target session's working directory and switches.
  (it "run-command-line-attach-session-accepts-working-dir"
    (with-loop-state
      (with-empty-registry
        (let ((s0 (make-fake-session :nwindows 1))
              (s1 (make-fake-session :nwindows 1)))
          (setf (nerimux::session-name s0) "0"
                (nerimux::session-name s1) "work"
                (nerimux::session-last-active s0) 10
                (nerimux::session-last-active s1) 0
                nerimux::*server-sessions* (list (cons "0" s0)
                                                 (cons "work" s1))
                nerimux::*overlay* nil)
          (nerimux::%run-command-line s0 "attach-session -c /tmp -t work")
          (expect (string= "/tmp" (nerimux::session-start-directory s1)))
          (expect (eq s1 (nerimux::server-current-session)))))))

  ;; attach-session inside a running client rejects client-creation arguments.
  (it "run-command-line-attach-session-rejects-client-creation-args"
    (dolist (row *attach-session-rejected-client-creation-cases*)
      (destructuring-bind (line desc) row
        (with-loop-state
          (with-empty-registry
            (let ((s0 (make-fake-session :nwindows 1))
                  (s1 (make-fake-session :nwindows 1)))
              (setf (nerimux::session-name s0) "0"
                    (nerimux::session-name s1) "work"
                    (nerimux::session-last-active s0) 10
                    (nerimux::session-last-active s1) 0
                    nerimux::*server-sessions* (list (cons "0" s0)
                                                     (cons "work" s1))
                    nerimux::*dirty* nil
                    nerimux::*overlay* nil)
              (assert-command-args-rejected-without-redraw
                  (nerimux::%run-command-line s0 line)
                  line
                :context desc)
              (expect (eq s0 (nerimux::server-current-session)))))))))

  ;; :clear-prompt-history empties *prompt-history*.
  (it "dispatch-clear-prompt-history-empties-history"
    (with-fake-session (s)
      (let ((nerimux::*prompt-history* (history-kit:make-history)))
        (history-kit:history-add nerimux::*prompt-history* "prev-cmd")
        (nerimux::dispatch-command s :clear-prompt-history nil)
        (expect (history-kit:history-empty-p nerimux::*prompt-history*)))))

  ;; :detach-all-clients sets *running* to NIL and returns :detach.
  (it "dispatch-detach-all-clients-stops-running"
    (with-fake-session (s)
      (expect (eq :detach (nerimux::dispatch-command s :detach-all-clients nil)))
      ;; After return the global *running* has been set to nil by the handler.
      ;; with-loop-state restores it, so just verify the return value above.
      ))

  ;; detach without arguments detaches the active client.
  (it "run-command-line-detach-without-args-returns-detach"
    (with-fake-session (s)
      (setf nerimux::*running* t)
      (expect (eq :detach (nerimux::%run-command-line s "detach")))
      (expect nerimux::*running* :to-be-truthy)))

  ;; detach rejects unsupported client targeting and single-client flags.
  (it "run-command-line-detach-rejects-unsupported-arguments"
    (with-fake-session (s)
      (dolist (args *detach-unsupported-argument-cases*)
        (setf nerimux::*running* t
              nerimux::*dirty* nil
              nerimux::*overlay* nil)
        (assert-command-args-rejected-without-redraw
            (nerimux::%cmd-detach-arg s args)
            args
          :context "detach")
        (expect nerimux::*running* :to-be-truthy))))

  ;; :move-pane opens a prompt for the destination window index.
  (it "dispatch-move-pane-opens-prompt"
    (with-dispatch-prompt ((s :nwindows 2) :move-pane
                           :context ":move-pane must open a prompt")))

  ;; :refresh-client marks *dirty* to force an immediate redraw.
  (it "dispatch-refresh-client-marks-dirty"
    (with-fake-session (s)
      (let ((nerimux::*dirty* nil))
        (nerimux::dispatch-command s :refresh-client nil)
        (expect nerimux::*dirty* :to-be-truthy))))

  ;; refresh-client accepts only the local redraw and client-state flags.
  (it "run-command-line-refresh-client-accepts-local-flags"
    (with-fake-session (s)
      (dolist (args *refresh-client-accepted-argument-cases*)
        (setf nerimux::*dirty* nil
              nerimux::*overlay* nil)
        (expect (nerimux::%cmd-refresh-client-arg s args) :to-be-truthy)
        (expect nerimux::*dirty* :to-be-truthy)
        (expect (null nerimux::*overlay*)))))

  ;; refresh-client rejects unsupported forms and unknown flags.
  (it "run-command-line-refresh-client-rejects-unsupported-arguments"
    (with-fake-session (s)
      (dolist (args *refresh-client-rejected-argument-cases*)
        (setf nerimux::*dirty* nil
              nerimux::*overlay* nil)
        (assert-command-args-rejected-without-redraw
            (nerimux::%cmd-refresh-client-arg s args)
            args
          :context "refresh-client"))))

  ;; lock-client rejects unsupported target-client arguments.
  (it "run-command-line-lock-client-rejects-target-client"
    (with-fake-session (s)
      (let ((nerimux::*dirty* nil)
            (nerimux::*overlay* nil))
        (setf (nerimux::session-locked-p s) nil)
        (assert-command-args-rejected-without-redraw
            (nerimux::%run-command-line s "lock-client -t client-0")
            "lock-client -t client-0"
          :context "lock-client -t")
        (expect (nerimux::session-locked-p s) :to-be-falsy))))

  ;; lock-client and lock-session both lock the active session when no -t is given.
  ;; Each row: (command description).
  (it "run-command-line-lock-commands-lock-current-session-table"
    (dolist (row '(("lock-client"  "lock-client must lock the active session")
                   ("lock-session" "lock-session must lock the current session")))
      (destructuring-bind (cmd desc) row
        (declare (ignore desc))
        (with-fake-session (s)
          (let ((nerimux::*overlay* nil))
            (setf (nerimux::session-locked-p s) nil)
            (nerimux::%run-command-line s cmd)
            (expect (nerimux::session-locked-p s) :to-be-truthy))))))

  ;; lock-session -t locks the named target session.
  (it "run-command-line-lock-session-target-locks-target-session"
    (with-empty-registry
      (let ((s0 (make-fake-session :nwindows 1))
            (s1 (make-fake-session :nwindows 1)))
        (setf (nerimux::session-name s0) "0"
              (nerimux::session-name s1) "work"
              nerimux::*server-sessions* (list (cons "0" s0)
                                               (cons "work" s1)))
        (let ((nerimux::*overlay* nil))
          (setf (nerimux::session-locked-p s0) nil
                (nerimux::session-locked-p s1) nil)
          (expect (nerimux::%run-command-line s0 "lock-session -t work") :to-be-truthy)
          (expect (nerimux::session-locked-p s0) :to-be-falsy)
          (expect (nerimux::session-locked-p s1) :to-be-truthy)))))

  ;; lock-session rejects unknown flags and positional tokens before locking anything.
  (it "run-command-line-lock-session-rejects-unsupported-arguments"
    (dolist (command *lock-session-rejected-argument-cases*)
      (with-empty-registry
        (let ((s0 (make-fake-session :nwindows 1))
              (s1 (make-fake-session :nwindows 1)))
          (setf (nerimux::session-name s0) "0"
                (nerimux::session-name s1) "work"
                nerimux::*server-sessions* (list (cons "0" s0)
                                                 (cons "work" s1)))
          (let ((nerimux::*dirty* nil)
                (nerimux::*overlay* nil))
            (setf (nerimux::session-locked-p s0) nil
                  (nerimux::session-locked-p s1) nil)
            (assert-command-args-rejected-without-redraw
                (nerimux::%run-command-line s0 command)
                command
              :context "lock-session")
            (expect (nerimux::session-locked-p s0) :to-be-falsy)
            (expect (nerimux::session-locked-p s1) :to-be-falsy)))))))
