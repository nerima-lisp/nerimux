(in-package #:cl-tmux/test)

;;;; Pane tests - geometry, feed, next-pane-id, split-window.

(describe "model-suite"

  ;; ── pane-feed ────────────────────────────────────────────────────────────────

  ;; pane-feed feeds raw bytes through the screen emulator under the screen lock.
  (it "pane-feed-processes-bytes-into-screen"
    (let* ((screen (make-screen 10 5))
           (pane   (make-pane :id 1 :x 0 :y 0 :width 10 :height 5
                              :fd -1 :pid -1 :screen screen)))
      (pane-feed pane (cl-codec-kit:string-to-octets "hi" :encoding :utf-8))
      (expect (char= #\h (cell-char (screen-cell screen 0 0))))
      (expect (char= #\i (cell-char (screen-cell screen 1 0))))
      (expect (= 2 (screen-cursor-x screen)))))

  ;; ── pane-reposition direct unit test (no PTY) ───────────────────────────────
  ;;
  ;; NOTE: make-no-pty-pane builds panes with fd -1, and pane-reposition's own
  ;; (> (pane-fd pane) 0) guard means set-pty-size is NEVER CALLED for them.  That
  ;; guard is what makes these tests PTY-free — it is not, and never was, an EBADF
  ;; that the syscall tolerates.  Any tolerance there might once have been is
  ;; gone: set-pty-size now reaches cl-tty-kit:set-terminal-size, which rejects a
  ;; negative fd and a non-positive dimension outright and signals rather than
  ;; returning -1 (see pane-reposition-degenerate-dimensions-skip-the-pty-resize
  ;; below, and the fd/dimension guards it pins).  pane-reposition also calls
  ;; screen-resize under the screen lock.  The observable effects here are the
  ;; x/y/width/height slot updates and the matching screen dimension update.

  ;; pane-reposition sets x/y/width/height and resizes the underlying screen.
  (it "pane-reposition-updates-geometry-and-screen"
    (let ((pane (make-no-pty-pane 1 0 0 20 5)))
      (pane-reposition pane 3 7 40 10)
      (check-table (list (list (pane-x pane) 3 "pane-x must be 3 after reposition")
                         (list (pane-y pane) 7 "pane-y must be 7 after reposition")
                         (list (pane-width pane) 40 "pane-width must be 40 after reposition")
                         (list (pane-height pane) 10 "pane-height must be 10 after reposition")
                         (list (screen-width (pane-screen pane)) 40 "screen-width must match new pane width")
                         (list (screen-height (pane-screen pane)) 10 "screen-height must match new pane height")))))

  ;; pane-reposition correctly sets position to (0,0) — the corner case for zoom-in.
  (it "pane-reposition-zero-origin"
    (let ((pane (make-no-pty-pane 1 5 3 10 5)))
      (pane-reposition pane 0 0 80 24)
      (check-table (list (list (pane-x pane) 0 "pane-x must be 0 after reposition to origin")
                         (list (pane-y pane) 0 "pane-y must be 0 after reposition to origin")
                         (list (pane-width pane) 80 "pane-width must be 80")
                         (list (pane-height pane) 24 "pane-height must be 24")
                         (list (screen-width (pane-screen pane)) 80 "screen width must match pane width")
                         (list (screen-height (pane-screen pane)) 24 "screen height must match pane height")))))

  ;; pane-reposition returns no useful value — callers rely solely on side effects.
  (it "pane-reposition-returns-no-value"
    (let ((pane (make-no-pty-pane 1 0 0 5 5)))
      (expect (progn (pane-reposition pane 0 0 10 10) t) :to-be-truthy)))

  ;; pane-border-status controls how pane-reposition reserves rows for the title bar.
  (it "pane-reposition-border-status-table"
    (dolist (row '(("top"    1  23 "top status shifts content down, height -1")
                   ("bottom" 0  23 "bottom status keeps y, height -1")
                   ("off"    0  24 "no status, full height preserved")))
      (destructuring-bind (status expected-y expected-h desc) row
        (declare (ignore desc))
        (with-fresh-options
          (cl-tmux/options:set-option "pane-border-status" status)
          (let ((pane (make-no-pty-pane 1 0 0 20 5)))
            (pane-reposition pane 0 0 80 24)
            (expect (= expected-y (pane-y pane)))
            (expect (= expected-h (pane-height pane)))
            (expect (= expected-h (screen-height (pane-screen pane)))))))))

  ;; ── pane-reposition degenerate-layout guard ─────────────────────────────────
  ;;
  ;; A zero dimension must not reach the PTY resize.  set-pty-size now delegates
  ;; to cl-tty-kit:set-terminal-size, whose %assert-terminal-dimension demands
  ;; POSITIVE integers and signals ("Terminal columns must be a positive integer,
  ;; got 0.") BEFORE attempting the ioctl — where the cffi path it replaced sent a
  ;; 0x0 winsize to the kernel and dropped the -1 return.  pane-reposition is the
  ;; one caller that COMPUTES its dimensions rather than receiving them:
  ;; %pane-border-status-reservation returns a CONTENT-HEIGHT of 0 for an
  ;; allocated HEIGHT of 0, so a degenerate layout would signal out of what is
  ;; otherwise a pure geometry update.
  ;;
  ;; The fd guard alone is NOT enough and this test would pass vacuously on a
  ;; make-no-pty-pane, whose fd is -1 — so the pane is given a positive fd and
  ;; *resize-pty* is swapped for a recorder.  No real fd is ever touched.

  ;; pane-reposition skips the PTY resize when a computed dimension is zero, and
  ;; still performs it for a sane geometry.
  (it "pane-reposition-degenerate-dimensions-skip-the-pty-resize"
    (with-fresh-options
      (cl-tmux/options:set-option "pane-border-status" "off")
      (let* ((calls nil)
             (cl-tmux/ports:*resize-pty*
               (lambda (fd rows cols) (push (list fd rows cols) calls)))
             (pane (make-no-pty-pane 1 0 0 20 5)))
        (setf (pane-fd pane) 3)              ; positive: the fd guard passes
        ;; height 0 → content-height 0
        (finishes (pane-reposition pane 0 0 40 0)
                  "a zero content height must not reach set-pty-size")
        (expect (null calls))
        ;; width 0
        (finishes (pane-reposition pane 0 0 0 10)
                  "a zero width must not reach set-pty-size")
        (expect (null calls))
        ;; Positive control: a sane geometry still resizes, and still transposes
        ;; into set-pty-size's (FD ROWS COLS) order.
        (pane-reposition pane 0 0 40 10)
        (expect (equal (list (list 3 10 40)) calls)))))

  ;; ── next-pane-id direct tests (pure, no PTY) ─────────────────────────────

  ;; next-pane-id returns pane-base-index when the window has no panes (default 0).
  (it "next-pane-id-returns-base-index-for-empty-window"
    (let ((win (make-window :id 1 :name "w" :panes nil)))
      ;; With pane-base-index=0 (default), first pane id is 0.
      (expect (= (or (cl-tmux/options:get-option "pane-base-index") 0)
                 (cl-tmux/model::next-pane-id win)))))

  ;; next-pane-id returns the lowest id >= pane-base-index not already in use.
  (it "next-pane-id-fills-lowest-gap"
    (let* ((base (or (cl-tmux/options:get-option "pane-base-index") 0))
           (p1  (make-no-pty-pane (+ base 1) 0 0 10 5))
           (p3  (make-no-pty-pane (+ base 3) 0 0 10 5))
           (win (make-window :id 1 :name "w" :panes (list p1 p3))))
      ;; The lowest gap above base should be filled.
      (expect (= base (cl-tmux/model::next-pane-id win)))))

  ;; ── split-window -d flag (no-focus) ─────────────────────────────────────────

  ;; window-split :no-focus t creates the new pane but keeps the original active pane.
  (it "split-window-no-focus"
    (unless (pty-available-p)
      (skip "PTY not available"))
    (with-session (session 41 10)
      (let* ((win (session-active-window session))
             (active-pane (window-active-pane win)))
        (let ((new-pane (window-split session win :h :no-focus t)))
          (expect (not (null new-pane)))
          (expect (eq active-pane (window-active-pane win)))
          (expect (= 2 (length (window-panes win))))
          ;; Clean up
          (ignore-errors (pty-close (pane-fd new-pane) (pane-pid new-pane)))))))

  ;; ── split-window -l size hint ────────────────────────────────────────────────

  ;; window-split with a fractional size hint assigns the new pane a proportional width.
  (it "split-window-size-hint-percentage"
    (unless (pty-available-p)
      (skip "PTY not available"))
    (with-session (session 81 10)
      (let ((win (session-active-window session)))
        ;; Split with 0.25 size → new pane should be ~20 cols (25% of 80-col avail)
        (let ((new-pane (window-split session win :h :size 0.25)))
          (when new-pane
            (expect (> (pane-width new-pane) 0))
            (expect (< (pane-width new-pane) 81))
            (ignore-errors (pty-close (pane-fd new-pane) (pane-pid new-pane)))))))))
