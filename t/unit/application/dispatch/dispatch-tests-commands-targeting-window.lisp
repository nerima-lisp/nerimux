(in-package #:nerimux/test)

;;;; Dispatch tests - select-window target resolution.

(describe "dispatch-suite"

  ;; 'select-window -t N' selects the window whose window-id is N.
  (it "run-command-line-select-window-by-number"
    (with-fake-session (s :nwindows 3)
      (nerimux::%run-command-line s "select-window -t 2")
      (expect (= 2 (window-id (session-active-window s))))))

  ;; 'select-window -t <name>' selects the window with that (non-numeric) name.
  (it "run-command-line-select-window-by-name"
    (with-fake-session (s :nwindows 2)
      (setf (window-name (second (session-windows s))) "alpha")
      (nerimux::%run-command-line s "select-window -t alpha")
      (expect (string= "alpha" (window-name (session-active-window s))))))

  ;; 'select-window -T -t N' toggles to the last window when already on window N,
  ;; but selects N normally when not currently on it.
  (it "run-command-line-select-window-T-toggles-to-last"
    (with-fake-session (s :nwindows 2)
      (let* ((w0 (first  (nerimux/model:session-windows s)))
             (w1 (second (nerimux/model:session-windows s))))
        ;; session-last-window is recency-based (window-last-active-time, 1s
        ;; granularity); seed distinct OLD stamps so the two same-second selects
        ;; below produce an unambiguous last-window order (w0 older than w1's NOW).
        (setf (nerimux/model:window-last-active-time w0) 100
              (nerimux/model:window-last-active-time w1) 50)
        ;; From w0, -T -t 1 is NOT on the target → select w1 normally.
        (nerimux::%run-command-line s "select-window -T -t 1")
        (expect (eq w1 (session-active-window s)))
        ;; Now on w1 (w0 is last); -T -t 1 IS on the target → toggle to last (w0).
        (nerimux::%run-command-line s "select-window -T -t 1")
        (expect (eq w0 (session-active-window s))))))

  ;; select-window rejects unknown flags and positional tokens before changing windows.
  (it "run-command-line-select-window-rejects-unsupported-arguments"
    (dolist (command '("select-window -n extra"
                       "select-window -x"
                       "select-window -t 2 extra"))
      (with-fake-session (s :nwindows 2)
        (let ((initial (session-active-window s))
              (*overlay* nil))
          (expect (null (nerimux::%run-command-line s command)))
          (expect (eq initial (session-active-window s)))
          (assert-overlay-contains "unsupported argument"
                                    (overlay-lines) command))))))
