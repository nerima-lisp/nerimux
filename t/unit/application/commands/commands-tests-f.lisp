(in-package #:nerimux/test)

;;;; rename-window, kill-window, run-shell, if-shell, selection-text, swap-pane, capture-pane — part III

;;; ── run-shell ────────────────────────────────────────────────────────────────
;;;
;;; Tests use /bin/true (always exits 0) and /bin/echo (prints output) which are
;;; universally available on POSIX systems.  Background mode is verified via the
;;; T return value without inspecting the process object.

(describe "commands-suite"

  ;;; ── rename-window ────────────────────────────────────────────────────────────

  ;; rename-window sets the window name to the supplied string.
  (it "rename-window-sets-name"
    (let ((win (make-window :id 1 :name "old" :width 20 :height 5 :panes nil)))
      (nerimux/commands:rename-window win "new")
      (expect (string= "new" (window-name win)))))

  ;; rename-window with NIL window does not signal an error.
  (it "rename-window-nil-window-is-noop"
    (finishes (nerimux/commands:rename-window nil "irrelevant")))

  ;; rename-window with an empty or NIL name leaves the window name unchanged.
  (it "rename-window-invalid-name-is-noop-table"
    (dolist (c '(("" "original" "empty string → no-op")
                 (nil "keep"    "nil → no-op")))
      (destructuring-bind (new-name original desc) c
        (declare (ignore desc))
        (let ((win (make-window :id 1 :name original :width 20 :height 5 :panes nil)))
          (nerimux/commands:rename-window win new-name)
          (expect (string= original (window-name win)))))))

  ;;; ── kill-window (direct path) ────────────────────────────────────────────────

  ;; kill-window with an explicit WINDOW removes that specific window even when it
  ;; is not the active one.
  (it "kill-window-explicit-window-arg-removes-that-window"
    (let* ((p0  (%make-test-pane :id 1))
           (p1  (%make-test-pane :id 2))
           (w1  (make-window :id 1 :name "a" :width 20 :height 5
                             :tree (make-layout-leaf p0) :panes (list p0)))
           (w2  (make-window :id 2 :name "b" :width 20 :height 5
                             :tree (make-layout-leaf p1) :panes (list p1)))
           (sess (make-session :id 1 :name "0" :windows (list w1 w2))))
      (session-select-window sess w1)          ; active = w1
      ;; Kill the non-active window w2 explicitly.
      (expect (null (kill-window sess w2)))
      (expect (equal (list w1) (session-windows sess)))
      (expect (eq w1 (session-active-window sess)))))

  ;; Destroying the sole window of a session returns :quit.
  (it "kill-window-last-window-returns-quit"
    (let* ((p0  (%make-test-pane))
           (w1  (make-window :id 1 :name "w" :width 20 :height 5
                             :tree (make-layout-leaf p0) :panes (list p0)))
           (sess (make-session :id 1 :name "0" :windows (list w1))))
      (session-select-window sess w1)
      (expect (eq :quit (kill-window sess)))
      (expect (null (session-windows sess)))))

  ;; Killing the active window of two switches the active pointer to the survivor.
  (it "kill-window-active-switches-to-remaining"
    (let* ((p0  (%make-test-pane :id 1))
           (p1  (%make-test-pane :id 2))
           (w1  (make-window :id 1 :name "a" :width 20 :height 5
                             :tree (make-layout-leaf p0) :panes (list p0)))
           (w2  (make-window :id 2 :name "b" :width 20 :height 5
                             :tree (make-layout-leaf p1) :panes (list p1)))
           (sess (make-session :id 1 :name "0" :windows (list w1 w2))))
      (session-select-window sess w1)
      (expect (null (kill-window sess)))
      (expect (eq w2 (session-active-window sess)))))

  ;; End-to-end: killing the active window selects the last-used (MRU) survivor, not
  ;; the numerically-nearest one (tmux session_detach / session_last).  Timestamps
  ;; are preset (session-select-window has 1-second universal-time resolution, so
  ;; live switches would tie); killed=1 with remaining {0,2} is an id-distance tie
  ;; the OLD %nearest-window rule broke toward the higher id (w2).
  (it "kill-window-active-reselects-mru-not-nearest"
    (let* ((p0 (%make-test-pane :id 1))
           (p1 (%make-test-pane :id 2))
           (p2 (%make-test-pane :id 3))
           (w0 (make-window :id 0 :name "a" :width 20 :height 5
                            :tree (make-layout-leaf p0) :panes (list p0)
                            :last-active-time 200))   ; MRU survivor
           (w1 (make-window :id 1 :name "b" :width 20 :height 5
                            :tree (make-layout-leaf p1) :panes (list p1)))
           (w2 (make-window :id 2 :name "c" :width 20 :height 5
                            :tree (make-layout-leaf p2) :panes (list p2)
                            :last-active-time 100))
           (sess (make-session :id 1 :name "0" :windows (list w0 w1 w2))))
      ;; Make w1 active (its timestamp becomes 'now', irrelevant — it is killed).
      (session-select-window sess w1)
      (kill-window sess)
      (expect (eq w0 (session-active-window sess)))))

  ;; run-shell (background nil) returns a string containing the command's output.
  (it "run-shell-foreground-captures-stdout"
    (let ((out (nerimux/commands:run-shell "echo hello")))
      (expect (stringp out))
      (expect (search "hello" out))))

  ;; run-shell :background T returns T immediately without waiting.
  (it "run-shell-background-returns-t"
    (let ((result (nerimux/commands:run-shell "true" :background t)))
      (expect (eq t result))))

  ;; run-shell with a no-op command returns an empty or whitespace-only string.
  (it "run-shell-foreground-empty-command-returns-string"
    (let ((out (nerimux/commands:run-shell "true")))
      (expect (stringp out))))

  ;; run-shell :combine-stderr T returns stdout and stderr in one output string.
  (it "run-shell-combine-stderr-captures-stderr"
    (let ((out (nerimux/commands:run-shell "printf out; printf err >&2"
                                           :combine-stderr t)))
      (expect (stringp out))
      (expect (search "out" out))
      (expect (search "err" out))))

  ;; run-shell :start-directory runs the shell subprocess from that directory.
  (it "run-shell-start-directory-controls-working-directory"
    (let ((dir (merge-pathnames
                (format nil "nerimux-run-shell-cwd-~D/" (random 1000000))
                (host-kit:temporary-directory))))
      (unwind-protect
           (let* ((created (ensure-directories-exist dir))
                  (expected (string-right-trim '(#\/)
                                               (namestring (truename created))))
                  (out (nerimux/commands:run-shell
                        "pwd"
                        :start-directory (namestring created)))
                  (actual (string-right-trim '(#\/ #\Newline #\Return #\Space #\Tab)
                                             out)))
             (expect (stringp out))
             (expect (string= expected actual)))
        (ignore-errors (host-kit:delete-directory-tree dir :validate t)))))

  ;; run-shell :delay waits before launching the shell subprocess.
  (it "run-shell-delay-waits-before-running-command"
    (let* ((start (get-internal-real-time))
           (out (nerimux/commands:run-shell "printf delayed" :delay 1/20))
           (elapsed (/ (- (get-internal-real-time) start)
                       internal-time-units-per-second)))
      (expect (stringp out))
      (expect (search "delayed" out))
      (expect (>= elapsed 1/20))))

  ;;; ── if-shell ─────────────────────────────────────────────────────────────────

  ;; if-shell calls then-fn on zero exit; else-fn on non-zero exit.
  (it "if-shell-dispatch-table"
    (dolist (row (list (list (lambda (f) (nerimux/commands:if-shell "true" f))
                             "zero exit → then-fn called")
                       (list (lambda (f) (nerimux/commands:if-shell "false"
                                                                     (lambda () nil)
                                                                     :else-fn f))
                             "non-zero exit → else-fn called")))
      (destructuring-bind (runner desc) row
        (declare (ignore desc))
        (let ((flag nil))
          (funcall runner (lambda () (setf flag t)))
          (expect flag :to-be-truthy)))))

  ;; if-shell with no applicable callback is a no-op (no error signalled).
  (it "if-shell-no-applicable-callback-table"
    (dolist (row (list (list "false" (lambda () nil) "non-zero exit, no else-fn")
                       (list "true"  nil             "zero exit, nil then-fn")))
      (destructuring-bind (cmd then-fn desc) row
        (finishes (nerimux/commands:if-shell cmd then-fn) "~A must not error" desc))))

  ;; if-shell with a very short timeout calls ELSE-FN (timeout treated as non-zero exit).
  (it "if-shell-timeout-returns-calls-else-fn"
    (let ((else-called nil))
      (nerimux/commands:if-shell "sleep 60"
                                 (lambda () nil)
                                 :else-fn (lambda () (setf else-called t))
                                 :timeout 1/1000)
      (expect else-called :to-be-truthy)))

  ;;; ── %selection-text ──────────────────────────────────────────────────────────
  ;;;
  ;;; %selection-text is a private helper in nerimux/commands that extracts the
  ;;; selected text from a copy-mode screen.  It returns NIL when no selection is
  ;;; active, a string for a single-row selection, and a newline-joined string for
  ;;; a multi-row selection.

  ;; %selection-text returns NIL when copy-selecting is NIL (no active selection).
  (it "selection-text-returns-nil-when-no-selection"
    (let ((s (copy-mode-screen :w 20 :h 5)))
      (expect (null (nerimux/commands::%selection-text s)))))

  ;; %selection-text returns NIL when copy-selecting is T but mark is NIL.
  (it "selection-text-returns-nil-when-mark-nil"
    (let ((s (copy-mode-screen :w 20 :h 5
                               :selecting t
                               :cursor (cons 0 5))))
      (expect (null (nerimux/commands::%selection-text s)))))

  ;; %selection-text returns the correct string for a single-row selection.
  (it "selection-text-single-row-returns-correct-text"
    (let ((s (copy-mode-screen :w 20 :h 5
                               :content "hello world"
                               :mark (cons 0 0)
                               :cursor (cons 0 5)
                               :selecting t)))
      (let ((text (nerimux/commands::%selection-text s)))
        (expect (stringp text))
        (expect (string= "hello" text)))))

  ;; %selection-text returns newline-joined text for a multi-row selection.
  (it "selection-text-multi-row-returns-newline-joined-text"
    (let ((s (copy-mode-screen :w 20 :h 5
                               :content (format nil "abc~C~Cdef" #\Return #\Linefeed)
                               :mark (cons 0 0)
                               :cursor (cons 1 3)
                               :selecting t)))
      (let ((text (nerimux/commands::%selection-text s)))
        (expect (stringp text))
        (expect (find #\Newline text))
        ;; Row 0 contributes cols 0..2 = "abc"; row 1 contributes cols 0..2 = "def".
        (expect (string= (format nil "abc~%def") text)))))

  ;; %selection-text normalises selection when cursor is before mark.
  (it "selection-text-reversed-mark-cursor-order"
    (let ((s (copy-mode-screen :w 20 :h 5
                               :content "hello world"
                               :mark (cons 0 5)
                               :cursor (cons 0 0)
                               :selecting t)))
      (let ((text (nerimux/commands::%selection-text s)))
        (expect (stringp text))
        (expect (string= "hello" text))))))
