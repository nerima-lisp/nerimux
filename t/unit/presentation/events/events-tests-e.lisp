(in-package #:nerimux/test)

;;;; events tests — part E: status-column, SGR-mouse NIL, copy-mode navigation,
;;;; escape/repeat timeout, mouse passthrough, and drag-state.

(defun make-mouse-passthrough-fixture (fd)
  (let* ((screen (make-screen 20 5))
         (pane   (make-pane :id 1 :fd fd :pid -1 :x 0 :y 0
                            :width 20 :height 5 :screen screen))
         (win    (make-window :id 1 :name "w" :width 20 :height 5
                              :panes (list pane)
                              :tree (make-layout-leaf pane))))
    (values screen pane win)))

(defmacro define-mouse-passthrough-cases (&body cases)
  "Define %try-mouse-passthrough mode tests from declarative rows."
  `(progn
     ,@(loop for (name doc options mode event . assertions) in cases
             for pipe-p = (getf options :pipe-p)
             for fd-form = (if pipe-p 'wfd (getf options :fd -1))
             for body = `(multiple-value-bind (screen pane win)
                             (make-mouse-passthrough-fixture ,fd-form)
                           (setf (screen-mouse-mode screen) ,mode)
                           (destructuring-bind (button column row release-p) ',event
                             (let ((result (nerimux::%try-mouse-passthrough
                                            win pane button column row release-p)))
                               ,@assertions)))
             collect `(it ,(string-downcase (symbol-name name))
                        ,(if pipe-p
                             `(with-pipe-fds (rfd wfd)
                                ,body)
                             body)))))

(describe "events-suite"

  ;; %status-col-to-window returns the correct window when the column falls in the
  ;; third window entry (verifies the multi-window traversal path).
  (it "status-col-to-window-finds-third-window"
    (let* ((p0   (make-pane :id 1 :fd -1 :pid -1 :x 0 :y 0 :width 20 :height 5
                             :screen (make-screen 20 5)))
           (p1   (make-pane :id 2 :fd -1 :pid -1 :x 0 :y 0 :width 20 :height 5
                             :screen (make-screen 20 5)))
           (p2   (make-pane :id 3 :fd -1 :pid -1 :x 0 :y 0 :width 20 :height 5
                             :screen (make-screen 20 5)))
           (win0 (make-window :id 0 :name "a" :width 20 :height 5
                              :panes (list p0) :tree (make-layout-leaf p0)))
           (win1 (make-window :id 1 :name "b" :width 20 :height 5
                              :panes (list p1) :tree (make-layout-leaf p1)))
           (win2 (make-window :id 2 :name "c" :width 20 :height 5
                              :panes (list p2) :tree (make-layout-leaf p2)))
           (sess (make-session :id 1 :name "s" :windows (list win0 win1 win2))))
      (window-select-pane win0 p0)
      (window-select-pane win1 p1)
      (window-select-pane win2 p2)
      (session-select-window sess win0)
      ;; Session prefix " s" = 2 chars.
      ;; win0 "a": 6 chars, cols 2..7
      ;; separator: column 8
      ;; win1 "b": 5 chars, cols 9..13
      ;; separator: column 14
      ;; win2 "c": 5 chars, cols 15..19
      ;; Column 15 should land in win2.
      (expect (eq win2 (nerimux::%status-col-to-window sess 15)))))

  ;;; ── %handle-escape-sgr-mouse NIL branch coverage ─────────────────────────────

  ;; %handle-escape-sgr-mouse is a no-op and returns ground-state for a malformed SGR sequence
  ;; (one that %parse-sgr-mouse cannot parse).
  (it "handle-escape-sgr-mouse-ignores-malformed-sequence"
    (with-fake-session (s)
      ;; Build a syntactically valid ESC [ < prefix but with only one field (no semicolons).
      ;; %parse-sgr-mouse will return (values nil nil nil nil) for this.
      (let* ((seq (format nil "~C[<0M" #\Escape))  ; too short, missing fields
             (buf (make-array (length seq) :element-type '(unsigned-byte 8)
                              :fill-pointer (length seq) :adjustable t
                              :initial-contents (map 'list #'char-code seq)))
             (len (length seq)))
        (expect (multiple-value-list (nerimux::%handle-escape-sgr-mouse s buf len))
          :to-return-to-ground))))

  ;;; ── copy-mode navigation bytes via process-byte (table-driven coverage) ─────
  ;;;
  ;;; Tests that all the additional byte constants (h, l, w, b, e, $, etc.) defined
  ;;; in events-core.lisp route correctly through the copy-mode dispatch in
  ;;; %ground-input-state. We drive them through process-byte to stay at the
  ;;; public API level.

  ;; All standard copy-mode navigation bytes route without error through process-byte.
  (it "copy-mode-all-nav-bytes-via-process-byte"
    (with-copy-mode-state (s screen state)
      (seed-scrollback screen 10)
      ;; Use the named constants from events-core.lisp for each byte.
      (dolist (byte (list #.nerimux::+byte-h+
                          #.nerimux::+byte-j+
                          #.nerimux::+byte-k+
                          #.nerimux::+byte-l+
                          #.nerimux::+byte-w+
                          #.nerimux::+byte-b+
                          #.nerimux::+byte-e+
                          #.nerimux::+byte-dollar+
                          #.nerimux::+byte-g+
                          #.nerimux::+byte-capital-g+
                          #.nerimux::+byte-capital-h+
                          #.nerimux::+byte-capital-m+
                          #.nerimux::+byte-capital-l+
                          #.nerimux::+byte-n+
                          #.nerimux::+byte-capital-n+
                          #.nerimux::+byte-capital-v+
                          #.nerimux::+byte-space+
                          #.nerimux::+byte-v+
                          #.nerimux::+byte-y+
                          #.nerimux::+byte-capital-y+
                          #.nerimux::+byte-capital-d+
                          #.nerimux::+byte-capital-a+
                          #.nerimux::+byte-r+))
        (nerimux::dispatch-command s :copy-mode-enter nil)
        (finishes (nerimux::process-byte s byte state)))))

  ;;; ── %flush-esc-if-timed-out behavioural tests ────────────────────────────────

  ;; %flush-esc-if-timed-out is a no-op when esc-entered-at is NIL.
  (it "flush-esc-no-op-when-no-esc-pending"
    (with-fake-session (sess)
      (let ((state (nerimux::make-input-state)))
        ;; esc-entered-at starts NIL; %flush-esc-if-timed-out must not change the state.
        (expect (null (nerimux::input-state-esc-entered-at state)))
        (nerimux::%flush-esc-if-timed-out state sess)
        (expect (null (nerimux::input-state-esc-entered-at state))))))

  ;; %flush-esc-if-timed-out does not flush when the timeout has NOT elapsed.
  (it "flush-esc-within-timeout-does-not-flush"
    (with-fake-session (sess)
      (let ((state (nerimux::make-input-state)))
        (with-isolated-config
          ;; Set a very long escape-time so the timer has definitely not expired.
          (nerimux/options:set-server-option "escape-time" 100000)
          ;; Simulate an ESC having been received: stamp esc-entered-at.
          (setf (nerimux::input-state-esc-entered-at state) (get-internal-real-time))
          (nerimux::%flush-esc-if-timed-out state sess)
          ;; Continuation must still point away from ground (timer did not fire).
          (expect (not (null (nerimux::input-state-esc-entered-at state))))))))

  ;; %flush-esc-if-timed-out resets state to ground when escape-time has elapsed.
  (it "flush-esc-after-timeout-resets-to-ground"
    (with-fake-session (sess)
      (let ((state (nerimux::make-input-state)))
        (with-isolated-config
          ;; Set escape-time to 0 ms so any elapsed time qualifies.
          (nerimux/options:set-server-option "escape-time" 0)
          ;; Stamp esc-entered-at far in the past.
          (setf (nerimux::input-state-esc-entered-at state)
                (- (get-internal-real-time) (* 2 internal-time-units-per-second)))
          (nerimux::%flush-esc-if-timed-out state sess)
          ;; After flush: esc-entered-at cleared and continuation back to ground.
          (expect (null (nerimux::input-state-esc-entered-at state)))
        (expect (eq (nerimux::input-state-continuation state)
                    #'nerimux::%ground-input-state))))))

  ;;; ── %reset-repeat-if-expired behavioural tests ───────────────────────────────

  ;; %reset-repeat-if-expired is a no-op when repeat-entered-at is NIL.
  (it "reset-repeat-no-op-when-no-repeat-pending"
    (let ((state (nerimux::make-input-state)))
      (expect (null (nerimux::input-state-repeat-entered-at state)))
      (nerimux::%reset-repeat-if-expired state)
      (expect (null (nerimux::input-state-repeat-entered-at state)))))

  ;; %reset-repeat-if-expired does not reset within the repeat-time window.
  (it "reset-repeat-within-timeout-does-not-reset"
    (let ((state (nerimux::make-input-state)))
      (with-isolated-config
        (nerimux/options:set-option "repeat-time" 100000)
        (setf (nerimux::input-state-repeat-entered-at state) (get-internal-real-time))
        (nerimux::%reset-repeat-if-expired state)
        (expect (not (null (nerimux::input-state-repeat-entered-at state)))))))

  ;; %reset-repeat-if-expired resets to ground state after repeat-time elapses.
  (it "reset-repeat-after-timeout-resets-to-ground"
    (let ((state (nerimux::make-input-state)))
      (with-isolated-config
        (nerimux/options:set-option "repeat-time" 0)
        ;; Stamp repeat-entered-at far in the past.
        (setf (nerimux::input-state-repeat-entered-at state)
              (- (get-internal-real-time) (* 2 internal-time-units-per-second)))
        (nerimux::%reset-repeat-if-expired state)
        (expect (null (nerimux::input-state-repeat-entered-at state)))
        (expect (eq (nerimux::input-state-continuation state)
                    #'nerimux::%ground-input-state)))))

  ;; initial-repeat-time is a registered option defaulting to 0 (audit #34).
  (it "initial-repeat-time-option-registered-default-zero"
    (with-isolated-config
      (expect (eql 0 (nerimux/options:get-option "initial-repeat-time")))))

  ;; %repeat-window-ms uses a non-zero initial-repeat-time for the FIRST repeat key
  ;; (count 1) and repeat-time for every other key (audit #34, tmux 3.5+).
  (it "repeat-window-ms-honors-initial-repeat-time"
    (with-isolated-config
      (nerimux/options:set-option "repeat-time" 500)
      ;; initial-repeat-time 0 → repeat-time for the first key too.
      (nerimux/options:set-option "initial-repeat-time" 0)
      (expect (= 500 (nerimux::%repeat-window-ms 1)))
      (expect (= 500 (nerimux::%repeat-window-ms 2)))
      ;; initial-repeat-time 1500 → only the first key (count 1) uses it.
      (nerimux/options:set-option "initial-repeat-time" 1500)
      (expect (= 1500 (nerimux::%repeat-window-ms 1)))
      (expect (= 500 (nerimux::%repeat-window-ms 2)))
      (expect (= 500 (nerimux::%repeat-window-ms 3)))))

  ;;; ── %try-mouse-passthrough mode tests ────────────────────────────────────────

  (define-mouse-passthrough-cases
    (try-mouse-passthrough-mode1-blocks-release
     "Mode 1 (X10/normal): release events are NOT forwarded."
     (:fd -1)
     1
     (0 0 0 t)
     (expect (null result)))
    (try-mouse-passthrough-mode2-forwards-release
     "Mode 2 (button-event): release events are forwarded."
     (:pipe-p t)
     2
     (0 0 0 t)
     (expect (eq result t))
     (expect (nerimux/pty:select-fds (list rfd) 20000) :to-be-truthy))
    (try-mouse-passthrough-mode0-returns-nil
     "When the pane has mouse mode 0 (disabled), %try-mouse-passthrough returns NIL."
     (:fd -1)
     0
     (0 0 0 nil)
     (expect (null result))))

  ;;; ── drag-state is set on border press ───────────────────────────────────────

  ;; *mouse-drag-state* is non-NIL after a left-press on the separator column.
  (it "mouse-drag-state-is-set-on-border-press"
    (with-two-pane-mouse-session (sess win p0 p1)
      (expect (not (eq p0 p1)))
      ;; Simulate a left-press on the separator column (col 40).
      (nerimux::%dispatch-mouse-event sess 0 40 5 nil)
      ;; Whether the state has 2 or 4 elements depends on the implementation;
      ;; what matters is that it is non-NIL and contains a split node.
      (expect (not (null nerimux::*mouse-drag-state*)))
      (expect (nerimux/model:layout-split-p (first nerimux::*mouse-drag-state*))))))
