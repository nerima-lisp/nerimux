(in-package #:nerimux/test)

;;;; commands tests — part C: copy-mode virtual-row-string, timeout, clamp-cursor,
;;;; selection-bounds, word/paragraph navigation, scroll helpers, extract-row-chars.

(describe "commands-suite"

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

  ;; ── cl-concurrent-kit:with-timeout condition type ────────────────────────────

  ;; The condition CL-CONCURRENT-KIT:WITH-TIMEOUT signals on expiry is
  ;; CL-CONCURRENT-KIT:OPERATION-TIMED-OUT, not SB-EXT:TIMEOUT.  This matters
  ;; because SB-EXT:TIMEOUT is a SERIOUS-CONDITION that is deliberately NOT an
  ;; ERROR, so a handler written for ERROR would not catch it and the timeout
  ;; would escape uncaught.  The call site that depended on this went with
  ;; pipe-pane, but the assertion stays on the primitive: it pins a
  ;; cl-concurrent-kit contract that any future timeout handler in this tree
  ;; has to be written against, and an upgrade that moved OPERATION-TIMED-OUT
  ;; under ERROR would otherwise change behaviour silently.
  (it "with-timeout-signals-operation-timed-out-not-sb-ext-timeout"
    (expect (typep (handler-case
                       (cl-concurrent-kit:with-timeout 1/1000 (sleep 60))
                     (cl-concurrent-kit:operation-timed-out (c) c))
                   'error)))

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
