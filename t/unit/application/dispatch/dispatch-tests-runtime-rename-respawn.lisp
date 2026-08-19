(in-package #:nerimux/test)

;;;; Dispatch runtime command tests: bind/unbind, rename, and respawn.

(describe "dispatch-suite"

  ;; Runtime 'bind <key> <command>' (with args) binds via the config directive path,
  ;; not the interactive prompt — so command-prompt / control-mode bind works.
  (it "run-command-line-bind-with-args-binds-key"
    (with-option-session (s)
        (with-loop-state
          (nerimux::%run-command-line s "bind y new-window")
          (expect (eq :new-window
                  (nerimux/config:key-table-command
                   (nerimux/config:key-table-lookup "prefix" #\y)))))))

  ;; Runtime 'unbind -a' clears the prefix table (arg-bearing unbind routes through
  ;; the config directive logic, including the -a whole-table form).
  (it "run-command-line-unbind-a-clears-prefix-table"
    (with-option-session (s)
        (with-loop-state
          (expect (not (null (nerimux/config:key-table-lookup "prefix" #\c))))
          (nerimux::%run-command-line s "unbind -a")
          (expect (null (nerimux/config:key-table-lookup "prefix" #\c))))))

  ;; 'set-option -ga name val' (clustered -g -a) APPENDS — regression: the cluster was
  ;; parsed as -g only, silently dropping -a and overwriting instead of appending.
  (it "cmd-set-option-clustered-ga-appends"
    (with-option-session (s)
        (nerimux/options:set-option "@opt" "A")
        (nerimux::%run-command-line s "set-option -ga @opt B")
        (expect (string= "AB" (nerimux/options:get-option "@opt")))))

  ;; 'set-option -gF name #{...}' expands the format value once at set time.
  (it "cmd-set-option-F-expands-format-value"
    (with-option-session (s)                      ; session name is "0"
      (with-loop-state
        (nerimux::%run-command-line s "set-option -gF @opt #{session_name}")
        (expect (string= "0" (nerimux/options:get-option "@opt"))))))

  ;; 'rename-window <name>' renames the active window.
  (it "run-command-line-rename-window"
    (with-fake-session (s :nwindows 1)
      (nerimux::%run-command-line s "rename-window mywin")
      (expect (string= "mywin" (window-name (session-active-window s))))))

  ;; 'rename-window -t 1 newname' renames window-id 1, NOT the active window, and
  ;; does not fold the -t flag tokens into the new name.
  (it "run-command-line-rename-window-t-targets-window"
    (with-fake-session (s :nwindows 2)
      (let ((w0 (first  (session-windows s)))    ; id 0, active
            (w1 (second (session-windows s))))   ; id 1
        (nerimux::%run-command-line s "rename-window -t 1 newname")
        (expect (string= "newname" (window-name w1)))
        (expect (not (string= "newname" (window-name w0)))))))

  ;; rename-window rejects unknown flags before changing the window name.
  (it "run-command-line-rename-window-rejects-unsupported-flags"
    (with-fake-session (s :nwindows 1)
      (let* ((win (session-active-window s))
             (before (window-name win))
             (*overlay* nil))
        (expect (null (nerimux::%run-command-line s "rename-window -x renamed")))
        (expect (string= before (window-name win)))
        (assert-overlay-contains "unsupported argument" *overlay*
                                  "rename-window -x"))))

  ;; 'rename-session <name>' renames the session.
  (it "run-command-line-rename-session"
    (with-fake-session (s)
      (nerimux::%run-command-line s "rename-session mysess")
      (expect (string= "mysess" (session-name s)))))

  ;; 'rename-session -t other newname' renames the -t target session, not the
  ;; current one, and does not fold the flag tokens into the name.
  (it "run-command-line-rename-session-t-targets-session"
    (with-fake-session (cur)
      (let ((other (make-fake-session)))
        (setf (nerimux::session-name cur)   "cur"
              (nerimux::session-name other) "other")
        (let ((nerimux::*server-sessions* (list (cons "cur" cur) (cons "other" other))))
          (nerimux::%run-command-line cur "rename-session -t other newname")
          (expect (string= "newname" (session-name other)))
          (expect (string= "cur" (session-name cur)))))))

  ;; 'rename-session -t missing newname' falls back to the current session when
  ;; the target cannot be resolved.
  (it "run-command-line-rename-session-missing-target-falls-back-to-current"
    (with-fake-session (cur)
      (setf (nerimux::session-name cur) "cur")
      (let ((nerimux::*server-sessions* (list (cons "cur" cur))))
        (nerimux::%run-command-line cur "rename-session -t missing newname")
        (expect (string= "newname" (session-name cur)))
        (expect (assoc "newname" nerimux::*server-sessions* :test #'equal))
        (expect (null (assoc "cur" nerimux::*server-sessions* :test #'equal))))))

  ;; 'rename-session' with no argument falls through to the prompt.
  (it "run-command-line-rename-session-no-arg-opens-prompt"
    (with-fake-session (s)
      (let ((nerimux::*prompt* nil))
        (nerimux::%run-command-line s "rename-session")
        (expect (prompt-active-p)))))

  ;; rename-session rejects unknown flags before changing the session registry.
  (it "run-command-line-rename-session-rejects-unsupported-flags"
    (with-fake-session (s)
      (setf (nerimux::session-name s) "old")
      (let ((nerimux::*server-sessions* (list (cons "old" s)))
            (*overlay* nil))
        (expect (null (nerimux::%run-command-line s "rename-session -x new")))
        (expect (string= "old" (session-name s)))
        (expect (assoc "old" nerimux::*server-sessions* :test #'equal))
        (expect (null (assoc "new" nerimux::*server-sessions* :test #'equal)))
        (assert-overlay-contains "unsupported argument" *overlay*
                                  "rename-session -x"))))

  ;; set-window-option -t 1 @wopt myval sets the WINDOW-LOCAL option on window-id 1, not the
  ;; active window — and -t no longer leaks into the option name.
  (it "cmd-set-window-option-t-targets-window"
    (with-fake-session (s :nwindows 2)
      (let ((w0 (first  (session-windows s)))    ; id 0, active
            (w1 (second (session-windows s))))   ; id 1
        (nerimux::%run-command-line s "set-window-option -t 1 @wopt myval")
        (expect (string= "myval" (nerimux/options:get-option-for-window "@wopt" w1)))
        (expect (null (nerimux/options:get-option-for-window "@wopt" w0))))))

  ;; respawn-pane without -k on a still-running pane (fd > 0) is an error and does
  ;; NOT respawn — matching tmux (the model would otherwise fork unconditionally).
  (it "cmd-respawn-pane-without-k-errors-on-live-pane"
    (with-fake-session (s :nwindows 1 :npanes 1)
      (let ((pane (window-active-pane (session-active-window s))))
        (setf (nerimux/model:pane-fd pane) 5)       ; simulate a live PTY
        (let ((*overlay* nil))
          (nerimux::%cmd-respawn-pane-arg s '())
          (assert-overlay-active
              "respawn-pane without -k on a live pane must show an error overlay")
          (expect (= 5 (nerimux/model:pane-fd pane)))))))

  ;; respawn-window without -k errors when ANY pane in the window is still running,
  ;; and does NOT respawn — matching tmux.
  (it "cmd-respawn-window-without-k-errors-on-live-pane"
    (with-fake-two-pane-session (s)
      (let* ((win (session-active-window s))
             (p1  (first (window-panes win))))
        (setf (nerimux/model:pane-fd p1) 5)         ; one pane is live
        (let ((*overlay* nil))
          (nerimux::%cmd-respawn-window-arg s '())
          (assert-overlay-active
              "respawn-window without -k with a live pane must show an error overlay")
          (expect (= 5 (nerimux/model:pane-fd p1)))))))

  ;; respawn-pane forwards -c, repeated -e, and positional command overrides.
  (it "cmd-respawn-pane-forwards-overrides"
    (with-fake-session (s :nwindows 1 :npanes 1)
      (let* ((pane (window-active-pane (session-active-window s)))
             (nerimux::*dirty* nil)
             (*overlay* nil))
        (with-mocked-respawn-pane (respawn-mock reader-mock)
          (expect (eql t (nerimux::%cmd-respawn-pane-arg
                      s '("-k" "-c" "/tmp" "-e" "NAME=value" "-e" "EMPTY" "printf" "hello world"))))
          (expect *overlay* :to-be-falsy)
          (expect (eql t nerimux::*dirty*))
          (let ((calls (mock-calls respawn-mock)))
            (expect (= 1 (length calls)))
            (destructuring-bind (session called-pane &key start-dir default-command extra-env)
                (first calls)
              (expect (eq s session))
              (expect (eq pane called-pane))
              (expect (string= "/tmp" start-dir))
              (expect (string= "printf hello world" default-command))
              (expect (equal '(("NAME" . "value") ("EMPTY" . "")) extra-env))))
          (let ((reader-calls (mock-calls reader-mock)))
            (expect (= 1 (length reader-calls)))
            (expect (eq pane (first (first reader-calls)))))))))

  ;; respawn-window forwards -c, repeated -e, and positional command overrides to every pane.
  (it "cmd-respawn-window-forwards-overrides"
    (with-fake-two-pane-session (s)
      (let* ((win (session-active-window s))
             (panes (window-panes win))
             (nerimux::*dirty* nil)
             (*overlay* nil))
        (with-mocked-respawn-pane (respawn-mock reader-mock)
          (expect (eql t (nerimux::%cmd-respawn-window-arg
                      s '("-k" "-c" "/tmp" "-e" "A=1" "echo" "ok"))))
          (expect *overlay* :to-be-falsy)
          (expect (eql t nerimux::*dirty*))
          (let ((calls (mock-calls respawn-mock)))
            (expect (= 2 (length calls)))
            (dolist (call calls)
              (destructuring-bind (session called-pane &key start-dir default-command extra-env) call
                (expect (eq s session))
                (expect (member called-pane panes :test #'eq))
                (expect (string= "/tmp" start-dir))
                (expect (string= "echo ok" default-command))
                (expect (equal '(("A" . "1")) extra-env)))))
          (let ((reader-calls (mapcar #'first (mock-calls reader-mock))))
            (expect (= 2 (length reader-calls)))
            (dolist (pane panes)
              (expect (member pane reader-calls :test #'eq)))))))))
