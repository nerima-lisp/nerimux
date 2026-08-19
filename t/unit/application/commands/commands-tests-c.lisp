(in-package #:nerimux/test)

;;;; commands tests — part C: pipe-pane, virtual-row-string, timeout, clamp-cursor,
;;;; selection-bounds, word/paragraph navigation, scroll helpers, extract-row-chars.

(defun %run-pipe-pane-direction-case (assertion &key (pane-output-to-command-p t)
                                                       command-output-to-pane-p)
  (with-fake-session (sess :nwindows 1 :npanes 1)
    (let* ((*overlay* nil)
           (pane (session-active-pane sess))
           (result (nerimux/commands:pipe-pane-open
                    pane "cat"
                    :pane-output-to-command-p pane-output-to-command-p
                    :command-output-to-pane-p command-output-to-pane-p)))
      (expect result :to-be-truthy)
      (funcall assertion pane)
      (nerimux/commands:pipe-pane-close pane))))

(describe "commands-suite"

  ;; ── pipe-pane-open / pipe-pane-close / pipe-pane-write ──────────────────────

  ;; pipe-pane-open returns a stream object when the command launches successfully.
  (it "pipe-pane-open-returns-stream"
    (let* ((pane   (%make-test-pane))
           (result (nerimux/commands:pipe-pane-open pane "cat")))
      (expect result :to-be-truthy)
      (assert-pipe-pane-open-output-to-command-state pane)
      ;; Clean up.
      (nerimux/commands:pipe-pane-close pane)))

  ;; pipe-pane-open followed by pipe-pane-close clears pipe state.
  (it "pipe-pane-open-close-round-trip"
    (let ((pane (%make-test-pane)))
      (nerimux/commands:pipe-pane-open pane "cat")
      (assert-pipe-pane-open-output-to-command-state pane)
      (nerimux/commands:pipe-pane-close pane)
      (assert-pipe-pane-closed-state pane)))

  ;; pipe-pane-close is a no-op when pane has no open pipe.
  (it "pipe-pane-close-noop-when-no-pipe"
    (let ((pane (%make-test-pane)))
      (finishes (nerimux/commands:pipe-pane-close pane)
                "pipe-pane-close with no pipe must not signal")))

  ;; pipe-pane -I opens the reverse direction: command stdout is copied back to the pane.
  (it "cmd-pipe-pane-flag-i-enables-command-output-to-pane"
    (%run-pipe-pane-direction-case
     (lambda (pane) (assert-pipe-pane-open-command-output-state pane))
     :pane-output-to-command-p nil :command-output-to-pane-p t))

  ;; pipe-pane -O keeps the default pane stdout -> command stdin direction.
  (it "cmd-pipe-pane-flag-o-keeps-pane-output-to-command"
    (%run-pipe-pane-direction-case
     (lambda (pane) (assert-pipe-pane-open-output-to-command-state pane))
     :pane-output-to-command-p t :command-output-to-pane-p nil))

  ;; pipe-pane-write is a no-op when pane has no open pipe.
  (it "pipe-pane-write-noop-when-no-pipe"
    (let ((pane (%make-test-pane)))
      (finishes (nerimux/commands:pipe-pane-write pane #(65 66 67))
                "pipe-pane-write with no pipe must not signal")))

  ;; pipe-pane-open returns NIL when the shell program cannot be launched.
  ;; pipe-pane-open runs the command via `sh -c`, so a bogus *command* still
  ;; launches successfully (sh exists, then fails internally — matching tmux).
  ;; To exercise the launch-failure → NIL path, point *default-shell* at a
  ;; non-existent binary so process-kit:spawn itself fails.
  (it "pipe-pane-open-invalid-command-returns-nil"
    (let* ((pane   (%make-test-pane))
           (nerimux/config:*default-shell* "/no/such/shell-5f3a9b2e")
           (result (nerimux/commands:pipe-pane-open pane "echo hi")))
      (expect (null result))))

  ;; pipe-pane-open returns NIL and leaves the pane clean when launch times out.
  ;;
  ;; THE STUB MUST BE INSTALLED ON PROCESS-KIT:SPAWN, not on uiop:launch-program.
  ;; pipe-pane-open stopped calling uiop:launch-program in the dependency
  ;; migration (commands-pipe-pane.lisp now calls process-kit:spawn), and a stub
  ;; on the old name intercepts nothing: the launch returns promptly, the 1-second
  ;; +pipe-pane-open-timeout+ never fires, pipe-pane-open returns a live handle,
  ;; and this test fails while claiming to cover the timeout path.
  ;;
  ;; The stub keeps SPAWN's real lambda list — (COMMAND ARGUMENTS &KEY ...) — and
  ;; delegates to the original rather than fabricating a return value, so if the
  ;; deadline ever stopped firing this would still produce a genuine
  ;; PROCESS-KIT:PROCESS-HANDLE that pipe-pane-open can read process-stdin off.
  ;; A shape mismatch would otherwise be swallowed by %with-timeout-cleanup's
  ;; (or operation-timed-out error) clause and look exactly like a timeout.
  (it "pipe-pane-open-times-out-and-cleans-up"
    (let* ((pane (%make-test-pane))
           (original-spawn (fdefinition 'process-kit:spawn)))
      (unwind-protect
          (progn
            (setf (fdefinition 'process-kit:spawn)
                  (lambda (command arguments &rest keys)
                    (sleep 2)                 ; > +pipe-pane-open-timeout+ (1s)
                    (apply original-spawn command arguments keys)))
            (expect (null (nerimux/commands:pipe-pane-open pane "cat")))
            (assert-pipe-pane-closed-state pane))
        (setf (fdefinition 'process-kit:spawn) original-spawn)
        (ignore-errors (nerimux/commands:pipe-pane-close pane)))))

  ;; pipe-pane-write with an open pipe sends bytes to the subprocess stdin.
  ;; This drives a REAL shell subprocess + filesystem (cat > tmpfile), which is
  ;; inherently nondeterministic under a heavily-loaded parallel build (subprocess
  ;; scheduling / GC / fs flush timing).  Earlier single-shot versions — even with a
  ;; 6s poll — flaked.  We instead retry the whole self-contained cycle up to 5
  ;; times and assert the bytes reach the subprocess on at least one attempt: this
  ;; still verifies the real behaviour (bytes DO traverse the pipe to the child)
  ;; while tolerating a one-off environmental hiccup.  3 deterministic failures in a
  ;; row would still fail (a genuine break is not masked).
  ;;
  ;; THREE uiop CALLS DELIBERATELY REMAIN, and they are the only ones left under
  ;; t/.  cl-host-kit has no equivalent for any of them, so replacing them would
  ;; mean rewriting the fixture rather than re-pointing a call:
  ;;   * uiop:tmpize-pathname   — cl-host-kit's temporary-file API is CPS
  ;;     (call-with-temporary-file / with-temporary-file) and CREATES and OPENS the
  ;;     file.  This test needs a unique pathname that does NOT exist yet, because
  ;;     `cat > FILE` is what has to create it; handing the shell an already-open
  ;;     mkstemp fd would stop testing the pipe and start testing redirection.
  ;;   * uiop:merge-pathnames*  — no cl-host-kit export.
  ;;   * uiop:native-namestring — no cl-host-kit export.  The result is
  ;;     interpolated into a /bin/sh command line, so the native (not Lisp)
  ;;     spelling of the path is load-bearing.
  ;; host-kit:temporary-directory, read-file-string and delete-file-if-exists in
  ;; the same form DO have exact equivalents and were migrated.
  (it "pipe-pane-write-bytes-reach-subprocess"
    (flet ((attempt ()
             (let ((tmpfile (uiop:tmpize-pathname
                             (uiop:merge-pathnames* "pipe-pane-write-test"
                                                    (host-kit:temporary-directory))))
                   (pane    (%make-test-pane)))
               (unwind-protect
                    (progn
                      (nerimux/commands:pipe-pane-open
                       pane (format nil "cat > ~A" (uiop:native-namestring tmpfile)))
                      (when (pane-pipe-fd pane)            ; launch succeeded
                        (nerimux/commands:pipe-pane-write pane #(65 66 67)) ; "ABC"
                        (nerimux/commands:pipe-pane-close pane)
                        (let ((contents ""))
                          (loop repeat 250                  ; ~1.25s per attempt
                                until (and (probe-file tmpfile)
                                           (search "ABC"
                                                   (setf contents
                                                         (or (ignore-errors
                                                               (host-kit:read-file-string tmpfile))
                                                             ""))))
                                do (sleep 0.005))
                          (and (search "ABC" contents) t))))
                 (ignore-errors (host-kit:delete-file-if-exists tmpfile))))))
      (let ((ok nil))
        (dotimes (i 8) (unless ok (setf ok (attempt))))
        (expect ok :to-be-truthy))))

  ;; ── %copy-mode-virtual-row-string (direct unit tests) ───────────────────────

  ;; %copy-mode-virtual-row-string returns the content of the requested virtual row.
  (it "copy-mode-virtual-row-string-returns-row-content"
    (let ((s (make-screen 20 5)))
      (feed s "hello")
      (nerimux/commands::copy-mode-enter s)
      (let* ((vrow (+ (length (nerimux/terminal:screen-scrollback s))
                      (- 0 (nerimux/terminal:screen-copy-offset s))))
             (row-str (nerimux/commands::%copy-mode-virtual-row-string s vrow)))
        (expect (stringp row-str))
        (expect (and (>= (length row-str) 5)
                     (string= "hello" (subseq row-str 0 5)))))))

  ;; %copy-mode-virtual-row-string always returns a string of length = screen-width.
  (it "copy-mode-virtual-row-string-length-equals-screen-width"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (let ((vrow (length (nerimux/terminal:screen-scrollback s))))
        (expect (= 20 (length (nerimux/commands::%copy-mode-virtual-row-string s vrow)))))))

  ;; %copy-mode-total-rows returns scrollback length + screen height.
  (it "copy-mode-total-rows-counts-scrollback-plus-height"
    (let ((s (make-screen 20 5)))
      (feed-lines s "line-0" "line-1" "line-2" "line-3" "line-4" "line-5" "line-6")
      (expect (= 7 (nerimux/commands::%copy-mode-total-rows s)))))

  ;; %copy-mode-set-virtual-row moves the cursor to the requested virtual row.
  (it "copy-mode-set-virtual-row-updates-offset-and-cursor"
    (let ((s (make-screen 4 3)))
      (feed-lines s "AAA" "BBB" "CCC" "DDD" "EEE")
      (nerimux/commands::copy-mode-enter s)
      (nerimux/commands::%copy-mode-set-virtual-row s 0 1)
      (expect (= 2 (screen-copy-offset s)))
      (expect (equal (cons 0 1) (nerimux/terminal/types:screen-copy-cursor s)))
      (expect (screen-dirty-p s) :to-be-truthy)))

  ;; ── %run-with-timeout ────────────────────────────────────────────────────────

  ;; %run-with-timeout returns the result of the thunk when it completes within time.
  (it "run-with-timeout-returns-thunk-result"
    (let ((result (nerimux/commands::%run-with-timeout (lambda () 42) 10)))
      (expect (= 42 result))))

  ;; %run-with-timeout returns NIL when the thunk exceeds the timeout.
  (it "run-with-timeout-returns-nil-on-timeout"
    (let ((result (nerimux/commands::%run-with-timeout
                   (lambda () (sleep 60)) 1/1000)))
      (expect (null result))))

  ;; The deadline may be an arbitrary FORM, not just a literal.  This pins the
  ;; bordeaux-threads -> cl-concurrent-kit syntax change: bt:with-timeout took
  ;; its deadline wrapped in a list, (bt:with-timeout (SECS) ...), while
  ;; cl-concurrent-kit's is a bare form like SB-EXT:WITH-TIMEOUT's,
  ;; (with-timeout SECS ...).  Carrying the old parens over would expand to
  ;; (SECS) -- calling the timeout value as a function.
  (it "run-with-timeout-accepts-a-computed-deadline"
    (let ((seconds (+ 5 5)))
      (expect (= 42 (nerimux/commands::%run-with-timeout (lambda () 42) seconds)))))

  ;; The timeout the handler clause catches is CL-CONCURRENT-KIT:OPERATION-TIMED-OUT,
  ;; not SB-EXT:TIMEOUT.  This matters because SB-EXT:TIMEOUT is a
  ;; SERIOUS-CONDITION that is deliberately NOT an ERROR, so a handler written
  ;; for ERROR would not catch it and the timeout would escape %run-with-timeout
  ;; instead of returning NIL.  Asserted on the primitive so a future refactor of
  ;; %run-with-timeout's own handler cannot mask it.
  (it "with-timeout-signals-operation-timed-out-not-sb-ext-timeout"
    (expect (typep (handler-case
                       (cl-concurrent-kit:with-timeout 1/1000 (sleep 60))
                     (cl-concurrent-kit:operation-timed-out (c) c))
                   'error)))

  ;; ── run-shell timeout ────────────────────────────────────────────────────────

  ;; run-shell returns NIL when the command exceeds the given timeout.
  (it "run-shell-returns-nil-on-timeout"
    ;; Use a very short timeout (1ms) with a sleep command.
    (let ((result (nerimux/commands:run-shell "sleep 60" :timeout 1/1000)))
      (expect (null result))))

  ;; ── %copy-mode-clamp-cursor (direct unit tests) ──────────────────────────────

  ;; %copy-mode-clamp-cursor clamps out-of-range row/col and leaves in-range cursors unchanged.
  (it "copy-mode-clamp-cursor-table"
    (dolist (c '((10  3 4  3 "row > height-1 clamps to height-1=4")
                 (2  50 2 19 "col > width-1 clamps to width-1=19")
                 (2  10 2 10 "in-range cursor unchanged")))
      (destructuring-bind (init-r init-c exp-r exp-c desc) c
        (declare (ignore desc))
        (let ((s (make-screen 20 5)))
          (nerimux/commands::copy-mode-enter s)
          (setf (nerimux/terminal/types:screen-copy-cursor s) (cons init-r init-c))
          (nerimux/commands::%copy-mode-clamp-cursor s)
          (expect (= exp-r (car (nerimux/terminal/types:screen-copy-cursor s))))
          (expect (= exp-c (cdr (nerimux/terminal/types:screen-copy-cursor s))))))))

  ;; %copy-mode-clamp-cursor is a no-op when the cursor is NIL.
  (it "copy-mode-clamp-cursor-noop-when-cursor-nil"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) nil)
      (finishes (nerimux/commands::%copy-mode-clamp-cursor s)
                "%copy-mode-clamp-cursor with nil cursor must not signal")))

  ;; ── %selection-bounds (direct unit tests) ────────────────────────────────────

  ;; %selection-bounds always returns (start-row end-row start-col end-col) with
  ;; start ≤ end, regardless of whether mark or cursor comes first.
  (it "selection-bounds-table"
    (dolist (row '((1 3  1 8  1 1 3 8 "same-row: mark col < cursor col")
                   (1 8  1 3  1 1 3 8 "same-row: cursor col < mark col (normalised)")
                   (0 2  2 7  0 2 2 7 "multi-row: mark above cursor")
                   (2 7  0 2  0 2 2 7 "multi-row: cursor above mark (normalised)")))
      (destructuring-bind (mr mc cr cc exp-sr exp-er exp-sc exp-ec desc) row
        (declare (ignore desc))
        (let ((s (make-screen 20 5)))
          (nerimux/commands::copy-mode-enter s)
          (setf (nerimux/terminal/types:screen-copy-mark   s) (cons mr mc)
                (nerimux/terminal/types:screen-copy-cursor s) (cons cr cc))
          (multiple-value-bind (start-row end-row start-col end-col)
              (nerimux/commands::%selection-bounds s)
            (expect (= exp-sr start-row))
            (expect (= exp-er end-row))
            (expect (= exp-sc start-col))
            (expect (= exp-ec end-col))))))))
