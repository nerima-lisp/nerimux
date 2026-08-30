(in-package #:nerimux/test/model)

;;;; Pane tests - pane/window operations.

(describe "model-suite"

  ;;; ── last-pane cycles ─────────────────────────────────────────────────────────

  ;; window-select-pane updates window-last-active; switching back via :last-pane
  ;; returns to the previous pane.
  (it "last-pane-cycles"
    (let* ((p0  (make-no-pty-pane 1  0 0 20 5))
           (p1  (make-no-pty-pane 2 21 0 20 5))
           (win (make-window :id 1 :name "w" :width 41 :height 5
                             :tree (make-layout-split :h
                                      (make-layout-leaf p0) (make-layout-leaf p1)
                                      1/2)
                             :panes (list p0 p1))))
      ;; Start on p0
      (window-select-pane win p0)
      (expect (eq p0 (window-active-pane win)))
      ;; Switch to p1 — this should record p0 as last-active
      (window-select-pane win p1)
      (expect (eq p1 (window-active-pane win)))
      (expect (eq p0 (window-last-active win)))
      ;; Simulate :last-pane by selecting window-last-active
      (let ((last (window-last-active win)))
        (when last (window-select-pane win last)))
      (expect (eq p0 (window-active-pane win)))))

  (it "spawn-shell-for-pane-forwards-environment-and-options"
    (let* ((call nil)
          (nerimux/ports:*spawn-pty*
            (lambda (rows cols &key start-dir default-command environment)
              (setf call (list :rows rows
                                :cols cols
                                :start-dir start-dir
                                :default-command default-command
                                :environment environment))
              (values 17 23 "/dev/pts/fake"))))
      (let ((nerimux/pane:*pane-extra-env* '(("GLOBAL" . "value"))))
        (multiple-value-bind (fd pid tty)
            (nerimux/pane::%spawn-shell-for-pane
             nil 24 80
             :start-dir "/tmp/start"
             :default-command "echo ready"
             :extra-env '(("CALL" . "value")))
          (expect (= 17 fd))
          (expect (= 23 pid))
          (expect (string= "/dev/pts/fake" tty))
          (expect (null nerimux/pane:*pane-extra-env*)))
        (expect (= 24 (getf call :rows -1)))
        (expect (= 80 (getf call :cols -1)))
        (expect (string= "/tmp/start" (getf call :start-dir)))
        (expect (string= "echo ready" (getf call :default-command)))
        (let ((environment (getf call :environment)))
          (expect (find "TERM=screen-256color" environment :test #'string=))
          (expect (find "COLORTERM=truecolor" environment :test #'string=))
          (expect (find "CALL=value" environment :test #'string=))
          (expect (find "GLOBAL=value" environment :test #'string=))))))

  (it "fork-pane-builds-a-pane-from-the-pty-result"
    (let ((nerimux/ports:*spawn-pty*
            (lambda (rows cols &key start-dir default-command environment)
              (declare (ignore rows cols start-dir default-command environment))
              (values 31 41 "/dev/pts/fork"))))
      (let ((pane (nerimux/pane::%fork-pane
                   nil 9 2 3 20 6 :start-dir "/tmp/fork")))
        (expect (= 9 (pane-id pane)))
        (expect (= 2 (pane-x pane)))
        (expect (= 3 (pane-y pane)))
        (expect (= 20 (pane-width pane)))
        (expect (= 6 (pane-height pane)))
        (expect (= 31 (pane-fd pane)))
        (expect (= 41 (pane-pid pane)))
        (expect (string= "/dev/pts/fork" (nerimux/pane:pane-tty pane)))
        (expect (string= "" (nerimux/pane:pane-start-command pane)))
        (expect (string= "/tmp/fork" (nerimux/pane:pane-start-path pane)))
        (expect (nerimux/pane:pane-screen pane)))))

  (it "fork-pane-forwards-the-default-command"
    (let ((spawn-command nil)
          (nerimux/ports:*spawn-pty*
            (lambda (rows cols &key start-dir default-command environment)
              (declare (ignore rows cols start-dir environment))
              (setf spawn-command default-command)
              (values 31 41 "/dev/pts/agent"))))
    (let ((pane (nerimux/pane::%fork-pane
                 nil 9 2 3 20 6
                 :start-dir "/tmp/workspace"
                 :default-command "claude --dangerously-skip-permissions")))
        (expect (string= "claude --dangerously-skip-permissions"
                         (nerimux/pane:pane-start-command pane))))))

  (it "make-input-pane-uses-dead-pty-sentinels"
    (let ((pane (nerimux/pane::%make-input-pane 4 5 6 30 7)))
      (expect (= 4 (pane-id pane)))
      (expect (= 5 (pane-x pane)))
      (expect (= 6 (pane-y pane)))
      (expect (= 30 (pane-width pane)))
      (expect (= 7 (pane-height pane)))
      (expect (= -1 (pane-fd pane)))
      (expect (= -1 (pane-pid pane)))
      (expect (string= "" (nerimux/pane:pane-tty pane)))
      (expect (nerimux/pane:pane-screen pane))))

  (it "respawn-pane-closes-old-pty-and-resets-pane-state"
    (let* ((screen (make-screen 40 6))
           (pane (make-pane :id 7 :x 1 :y 2 :width 40 :height 6
                            :fd 11 :pid 12 :tty "/dev/pts/old"
                            :start-command "old" :start-path "/old"
                            :screen screen
                            :unread-output-p t
                            :bell-p t
                            :process-exited-p t
                            :non-zero-exit-p t
                            :startup-failed-p t))
           (close-call nil)
           (spawn-call nil)
           (nerimux/ports:*close-pty*
             (lambda (fd pid)
               (setf close-call (list fd pid))
               :closed))
           (nerimux/ports:*spawn-pty*
             (lambda (rows cols &key start-dir default-command environment)
               (declare (ignore environment))
               (setf spawn-call (list rows cols start-dir default-command))
               (values 51 61 "/dev/pts/new"))))
      (expect (eq pane
                   (respawn-pane nil pane
                                 :start-dir "/new"
                                 :default-command "printf ok")))
      (expect (equal '(11 12) close-call))
      (expect (= 6 (first spawn-call)))
      (expect (= 40 (second spawn-call)))
      (expect (string= "/new" (third spawn-call)))
      (expect (string= "printf ok" (fourth spawn-call)))
      (expect (= 51 (pane-fd pane)))
      (expect (= 61 (pane-pid pane)))
      (expect (string= "/dev/pts/new" (nerimux/pane:pane-tty pane)))
      (expect (string= "printf ok" (nerimux/pane:pane-start-command pane)))
      (expect (string= "/new" (nerimux/pane:pane-start-path pane)))
      (expect (eq screen (nerimux/pane:pane-screen pane)))
      (expect (null (nerimux/pane:pane-unread-output-p pane)))
      (expect (null (nerimux/pane:pane-bell-p pane)))
      (expect (null (nerimux/pane:pane-process-exited-p pane)))
      (expect (null (nerimux/pane:pane-non-zero-exit-p pane)))
      (expect (null (nerimux/pane:pane-startup-failed-p pane)))))
  )
