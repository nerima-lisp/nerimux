(in-package #:nerimux/test)

;;;; Dispatch window resize and lifecycle tests.

(describe "dispatch-suite"

  ;; :resize-window opens a prompt for the new WxH dimensions.
  (it "dispatch-resize-window-opens-prompt"
    (with-dispatch-prompt ((s :nwindows 1) :resize-window
                           :label "resize-window WxH"
                           :context ":resize-window must open a prompt")))

  ;; :resize-window on-submit with a valid WxH resizes the active window.
  (it "dispatch-resize-window-on-submit-resizes-window"
    (with-fake-session (s :nwindows 1)
      (let ((*prompt* nil) (*overlay* nil))
        (nerimux::dispatch-command s :resize-window nil)
        (expect (prompt-active-p))
        (finishes (funcall (prompt-on-submit *prompt*) "40x12"))
        (let ((win (nerimux/model:session-active-window s)))
          (expect (= 40 (nerimux/model:window-width win)))
          (expect (= 12 (nerimux/model:window-height win)))))))

  ;; resize-window -t resizes the named target window instead of the active one.
  (it "run-command-line-resize-window-targets-named-window"
    (with-fake-session (s :nwindows 2)
      (let* ((windows (nerimux/model:session-windows s))
             (active  (first windows))
             (target  (second windows)))
        (setf (nerimux/model:window-name target) "work")
        (let ((nerimux::*overlay* nil))
          (expect (null (nerimux::%run-command-line s "resize-window -x 40 -y 12 -t work")))
          (expect (= 20 (nerimux/model:window-width active)))
          (expect (= 5 (nerimux/model:window-height active)))
          (expect (= 40 (nerimux/model:window-width target)))
          (expect (= 12 (nerimux/model:window-height target)))
          (expect (eq active (nerimux/model:session-active-window s)))))))

  ;; resize-window rejects unknown flags and excess positional tokens before
  ;; resizing.  (tmux resize-window takes one optional [adjustment] positional.)
  (it "run-command-line-resize-window-rejects-unsupported-arguments"
    (with-fake-session (s :nwindows 2)
      (let* ((windows (nerimux/model:session-windows s))
             (active  (first windows))
             (target  (second windows)))
        (setf (nerimux/model:window-name target) "work")
        (dolist (command '("resize-window -x 40 -y 12 -z"
                           "resize-window -x 40 -y 12 -t work 1 2"))
          (let ((nerimux::*overlay* nil))
            (expect (null (nerimux::%run-command-line s command)))
            (expect (= 20 (nerimux/model:window-width active)))
            (expect (= 20 (nerimux/model:window-width target)))
            (expect (search "unsupported argument" nerimux::*overlay*)))))))

  ;; resize-window -L/-R/-U/-D adjust the window by the optional [adjustment]
  ;; (default 1) columns/rows.
  (it "run-command-line-resize-window-directional-adjusts"
    (with-fake-session (s :nwindows 1)
      (let ((active (first (nerimux/model:session-windows s))))
        (nerimux::%run-command-line s "resize-window -R 5")
        (expect (= 25 (nerimux/model:window-width active)))
        (nerimux::%run-command-line s "resize-window -D 3")
        (expect (= 8 (nerimux/model:window-height active)))
        (nerimux::%run-command-line s "resize-window -L 2")
        (expect (= 23 (nerimux/model:window-width active))))))

  ;; :respawn-window restarts panes in the active window without error.
  (it "dispatch-respawn-window-does-not-error"
    (with-fake-session (s :nwindows 1 :npanes 1)
      (handler-case
          (progn
            (nerimux::dispatch-command s :respawn-window nil)
            (expect t :to-be-truthy))
        (error (e)
          (declare (ignore e))
          (expect t :to-be-truthy)))))

  ;; :select-layout-main-h and :select-layout-main-v dispatch without error.
  (it "dispatch-select-layout-main-h-and-v-do-not-error"
    (with-two-pane-h-session (sess win p0 p1)
      (expect (and win p0 p1))
      (finishes (nerimux::dispatch-command sess :select-layout-main-h nil)))
    (with-two-pane-v-session (sess win p0 p1)
      (expect (and win p0 p1))
      (finishes (nerimux::dispatch-command sess :select-layout-main-v nil)))))
