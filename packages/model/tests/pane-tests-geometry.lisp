(in-package #:nerimux/test/model)

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

  ;; pane-border-status and the row it used to reserve for a title bar are
  ;; gone (R6.6: border is a plain line, never a status row — see
  ;; pane-geometry.lisp's pane-reposition docstring).  pane-reposition's
  ;; geometry is now always the full allocated rectangle; that is exercised
  ;; by pane-reposition-updates-geometry-and-screen and
  ;; pane-reposition-zero-origin above.

  ;; ── pane-reposition degenerate-layout guard ─────────────────────────────────
  ;;
  ;; A zero dimension must not reach the PTY resize.  set-pty-size now delegates
  ;; to cl-tty-kit:set-terminal-size, whose %assert-terminal-dimension demands
  ;; POSITIVE integers and signals ("Terminal columns must be a positive integer,
  ;; got 0.") BEFORE attempting the ioctl — where the cffi path it replaced sent a
  ;; 0x0 winsize to the kernel and dropped the -1 return.  pane-reposition's
  ;; geometry is now the caller's HEIGHT/WIDTH verbatim (no border-status
  ;; reservation to compute it from), so a degenerate layout reaches the guard
  ;; whenever the caller passes a zero dimension directly.
  ;;
  ;; The fd guard alone is NOT enough and this test would pass vacuously on a
  ;; make-no-pty-pane, whose fd is -1 — so the pane is given a positive fd and
  ;; *resize-pty* is swapped for a recorder.  No real fd is ever touched.

  ;; pane-reposition skips the PTY resize when a computed dimension is zero, and
  ;; still performs it for a sane geometry.
  (it "pane-reposition-degenerate-dimensions-skip-the-pty-resize"
    (let* ((calls nil)
           (nerimux/ports:*resize-pty*
             (lambda (fd rows cols) (push (list fd rows cols) calls)))
           (pane (make-no-pty-pane 1 0 0 20 5)))
      (setf (pane-fd pane) 3)              ; positive: the fd guard passes
      ;; height 0
      (finishes (pane-reposition pane 0 0 40 0)
                "a zero height must not reach set-pty-size")
      (expect (null calls))
      ;; width 0
      (finishes (pane-reposition pane 0 0 0 10)
                "a zero width must not reach set-pty-size")
      (expect (null calls))
      ;; Positive control: a sane geometry still resizes, and still transposes
      ;; into set-pty-size's (FD ROWS COLS) order.
      (pane-reposition pane 0 0 40 10)
      (expect (equal (list (list 3 10 40)) calls))))

  ;; ── next-pane-id direct tests (pure, no PTY) ─────────────────────────────

  ;; next-pane-id returns 1 when the window has no panes (§1.4 of
  ;; docs/notes/workspace-requirements.md: pane numbering starts at 1 — fixed
  ;; via window-core.lisp's +pane-base-index+, no longer a config option).
  (it "next-pane-id-returns-one-for-empty-window"
    (let ((win (make-window :id 1 :name "w" :panes nil)))
      (expect (= 1 (nerimux/window::next-pane-id win)))))

  ;; next-pane-id returns the lowest id >= 1 not already in use.
  (it "next-pane-id-fills-lowest-gap"
    (let* ((p2  (make-no-pty-pane 2 0 0 10 5))
           (p3  (make-no-pty-pane 3 0 0 10 5))
           (win (make-window :id 1 :name "w" :panes (list p2 p3))))
      ;; id 1 is the lowest free id (below the used 2 and 3).
      (expect (= 1 (nerimux/window::next-pane-id win)))))

  ;; split-window-no-focus and split-window-size-hint-percentage (window-split
  ;; -d / -l, real PTY spawns via WITH-SESSION) moved to
  ;; tests/pty/pane-tests-geometry-pty.lisp (R9.2).
  )
