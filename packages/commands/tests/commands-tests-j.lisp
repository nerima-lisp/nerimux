(in-package #:nerimux/test/commands)

;;;; commands tests — part J: resize-pane directions,
;;;; copy-mode word/bottom noop, search helpers, scroll helpers,
;;;; extract-chars, copy-row-range, rename-session hooks.
(describe "commands-suite"

  ;;; ── copy-mode-search-backward: saves term ────────────────────────────────────

  ;; copy-mode-search-backward saves the search term for n/N repeats.
  (it "copy-mode-search-backward-saves-term"
    (let ((s (make-screen 30 5)))
      (feed s "foo bar foo")
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 11))
      (nerimux/commands::copy-mode-search-backward s "foo")
      (expect (string= "foo" (nerimux/terminal/types:screen-copy-search-term s)))))

  ;;; ── copy-mode-search-prev: positive case ─────────────────────────────────────

  ;; copy-mode-search-prev uses the saved term to repeat backward search.
  (it "copy-mode-search-prev-repeats-backward"
    ;; Use a two-row screen: row 0 = "abc", row 1 = "abc def"
    (let ((s (make-screen 30 5)))
      (feed s "abc")
      (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "abc def")
      (nerimux/commands::copy-mode-enter s)
      ;; Save term via forward search first
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 0))
      (nerimux/commands::copy-mode-search-forward s "abc")
      ;; Cursor should be on row 1 col 0 (second "abc")
      (expect (= 1 (car (nerimux/terminal/types:screen-copy-cursor s))))
      ;; Now search-prev should go back to row 0
      (nerimux/commands::copy-mode-search-prev s)
      (expect (= 0 (car (nerimux/terminal/types:screen-copy-cursor s))))))

  ;; n/N are relative to the LAST search heading, not hardcoded (audit #19): after a
  ;; backward search (?), n continues BACKWARD and N reverses to forward.
  (it "copy-mode-search-next-honors-backward-direction"
    ;; Three rows, each containing "abc".
    (let ((s (make-screen 30 5)))
      (feed s "abc")
      (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "abc")
      (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "abc")
      (nerimux/commands::copy-mode-enter s)
      ;; Backward search from row 2 finds the previous "abc" on row 1.
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 2 0))
      (nerimux/commands::copy-mode-search-backward s "abc")
      (expect (= 1 (car (nerimux/terminal/types:screen-copy-cursor s))))
      (expect (eq :backward (nerimux/terminal/types:screen-copy-search-direction s)))
      ;; n repeats in the SAME (backward) direction → row 0.
      (nerimux/commands::copy-mode-search-next s)
      (expect (= 0 (car (nerimux/terminal/types:screen-copy-cursor s))))
      (expect (eq :backward (nerimux/terminal/types:screen-copy-search-direction s)))
      ;; N reverses to forward → returns to row 1.
      (nerimux/commands::copy-mode-search-prev s)
      (expect (= 1 (car (nerimux/terminal/types:screen-copy-cursor s))))))

  ;;; ── %scroll-up-one-line direct tests ─────────────────────────────────────────

  ;; %scroll-up-one-line decrements row when cursor is not at top of viewport.
  (it "scroll-up-one-line-moves-cursor-up-within-viewport"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      ;; Place cursor at row 3 (well within viewport, no scrollback needed)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 3 2))
      (nerimux/commands::%scroll-up-one-line s 3 2 0)
      (expect (equal (cons 2 2) (nerimux/terminal/types:screen-copy-cursor s)))))

  ;; %scroll-up-one-line scrolls the viewport when cursor is at row 0 and scrollback exists.
  (it "scroll-up-one-line-scrolls-viewport-at-top-edge"
    (let ((s (%screen-with-scrollback 5)))
      ;; Place cursor at row 0 so the viewport needs to scroll
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 2))
      (let ((before-offset (screen-copy-offset s)))
        (nerimux/commands::%scroll-up-one-line s 0 2 5)
        (expect (= (1+ before-offset) (screen-copy-offset s)))
        (expect (= 0 (car (nerimux/terminal/types:screen-copy-cursor s)))))))

  ;; %scroll-up-one-line is a no-op when cursor is at row 0 and offset equals max.
  (it "scroll-up-one-line-noop-at-oldest-scrollback"
    (let ((s (%screen-with-scrollback 3)))
      (setf (nerimux/terminal/types:screen-copy-offset s) 3)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 2))
      (nerimux/commands::%scroll-up-one-line s 0 2 3)
      (expect (= 3 (screen-copy-offset s)))
      (expect (= 0 (car (nerimux/terminal/types:screen-copy-cursor s))))))

  ;;; ── %scroll-down-one-line direct tests ───────────────────────────────────────

  ;; %scroll-down-one-line increments row when cursor is not at viewport bottom.
  (it "scroll-down-one-line-moves-cursor-down-within-viewport"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      ;; Place cursor at row 1 (within viewport)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 1 2))
      (nerimux/commands::%scroll-down-one-line s 1 2 5)
      (expect (equal (cons 2 2) (nerimux/terminal/types:screen-copy-cursor s)))))

  ;; %scroll-down-one-line scrolls the viewport when cursor is at bottom and offset > 0.
  (it "scroll-down-one-line-scrolls-viewport-at-bottom-edge"
    (let ((s (%screen-with-scrollback 10)))
      ;; Set offset > 0 so we can scroll forward
      (setf (nerimux/terminal/types:screen-copy-offset s) 5)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 4 2))
      (nerimux/commands::%scroll-down-one-line s 4 2 5)
      (expect (= 4 (screen-copy-offset s)))
      (expect (= 4 (car (nerimux/terminal/types:screen-copy-cursor s))))))

  ;; %scroll-down-one-line is a no-op when cursor is at the bottom and offset is 0.
  (it "scroll-down-one-line-noop-at-live-view-bottom"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 4 2))
      (nerimux/commands::%scroll-down-one-line s 4 2 5)
      (expect (= 0 (screen-copy-offset s)))
      (expect (= 4 (car (nerimux/terminal/types:screen-copy-cursor s))))))
  )
