(in-package #:nerimux/test)

;;;; copy-mode jump, mark, goto-line, incremental search, and bracket navigation

(describe "commands-suite"

  ;;; ── Jump-to-char (vi f/F/t/T/;/,) ──────────────────────────────────────────

  ;; jump-forward, jump-backward, and jump-to land the cursor at the expected column.
  ;; Each row: (fn-sym initial-col char expected-col description).
  (it "copy-mode-jump-basic-movements"
    (dolist (row '((nerimux/commands::copy-mode-jump-forward  0  #\l 2
                    "jump-forward 'l' from col 0 must land on col 2 (first 'l')")
                   (nerimux/commands::copy-mode-jump-forward  10 #\z 10
                    "no-match forward must leave cursor unchanged")
                   (nerimux/commands::copy-mode-jump-backward 10 #\l 9
                    "jump-backward 'l' from col 10 must land on col 9 ('l' in 'world')")
                   (nerimux/commands::copy-mode-jump-to       0  #\l 1
                    "jump-to 'l' from col 0 must land on col 1 (one before col 2)")))
      (destructuring-bind (fn-sym initial-col char expected-col desc) row
        (declare (ignore desc))
        (let ((s (copy-mode-screen :w 20 :h 3 :content "hello world"
                                   :cursor (cons 0 initial-col))))
          (funcall (symbol-function fn-sym) s char)
          (expect (= expected-col (cdr (nerimux/terminal/types:screen-copy-cursor s))))))))

  ;; jump-again (vi ;) repeats the last jump-forward.
  (it "copy-mode-jump-again-repeats-last"
    (let ((s (copy-mode-screen :w 20 :h 3
                               :content "hello world"
                               :cursor (cons 0 0))))
      (nerimux/commands::copy-mode-jump-forward s #\l)   ; lands col 2
      (nerimux/commands::copy-mode-jump-again s)         ; next 'l'
      (expect (= 3 (cdr (nerimux/terminal/types:screen-copy-cursor s))))))

  ;; jump-reverse (vi ,) performs the jump in the opposite direction.
  (it "copy-mode-jump-reverse-reverses-forward"
    (let ((s (copy-mode-screen :w 20 :h 3
                               :content "hello world"
                               :cursor (cons 0 0))))
      (nerimux/commands::copy-mode-jump-forward s #\l)   ; lands col 2
      (nerimux/commands::copy-mode-jump-again  s)        ; lands col 3
      (nerimux/commands::copy-mode-jump-reverse s)       ; back to col 2
      (expect (= 2 (cdr (nerimux/terminal/types:screen-copy-cursor s))))))

  ;; After t<char>, ; (jump-again) advances PAST the immediately-adjacent occurrence
  ;; instead of sticking one cell before the same char (tmux cx+2, audit #18).
  ;; 'hello world' has 'l' at cols 2, 3, 9.
  (it "copy-mode-jump-to-again-advances-past-adjacent"
    (let ((s (copy-mode-screen :w 20 :h 3 :content "hello world" :cursor (cons 0 0))))
      (nerimux/commands::copy-mode-jump-to s #\l)          ; t l → col 1 (before 'l' @2)
      (expect (= 1 (cdr (nerimux/terminal/types:screen-copy-cursor s))))
      (nerimux/commands::copy-mode-jump-again s)            ; ; must advance, not stick
      (expect (= 2 (cdr (nerimux/terminal/types:screen-copy-cursor s))))
      (nerimux/commands::copy-mode-jump-again s)            ; ; → next 'l' @9 → col 8
      (expect (= 8 (cdr (nerimux/terminal/types:screen-copy-cursor s))))))

  ;; After T<char>, ; advances PAST the adjacent occurrence backward (tmux cx-2,
  ;; audit #18).  'hello world' has 'l' at cols 2, 3.
  (it "copy-mode-jump-to-back-again-advances-past-adjacent"
    (let ((s (copy-mode-screen :w 20 :h 3 :content "hello world" :cursor (cons 0 5))))
      (nerimux/commands::copy-mode-jump-to-backward s #\l) ; T l → col 4 (after 'l' @3)
      (expect (= 4 (cdr (nerimux/terminal/types:screen-copy-cursor s))))
      (nerimux/commands::copy-mode-jump-again s)            ; ; must advance backward
      (expect (= 3 (cdr (nerimux/terminal/types:screen-copy-cursor s))))))

  ;;; ── copy-mode-set-mark ───────────────────────────────────────────────────────

  ;; copy-mode-set-mark stores the current cursor position as the mark.
  (it "copy-mode-set-mark-stores-current-cursor"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s)  t
            (screen-copy-offset s)  2
            (nerimux/terminal/types:screen-copy-cursor s) (cons 3 7)
            (nerimux/terminal/types:screen-copy-mark   s) nil
            (nerimux/terminal/types:screen-copy-mark-offset s) 0)
      (nerimux/commands::copy-mode-set-mark s)
      (expect (equal (cons 3 7) (nerimux/terminal/types:screen-copy-mark s)))
      (expect (= 2 (nerimux/terminal/types:screen-copy-mark-offset s)))))

  ;; copy-mode-set-mark must NOT begin a visual selection.
  (it "copy-mode-set-mark-does-not-start-selection"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s)  t
            (screen-copy-offset s)  0
            (nerimux/terminal/types:screen-copy-cursor s)    (cons 1 4)
            (nerimux/terminal/types:screen-copy-selecting s) nil)
      (nerimux/commands::copy-mode-set-mark s)
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-falsy)))

  ;; copy-mode-set-mark is a no-op when not in copy mode or when the cursor is NIL.
  ;; Each row: (copy-mode-p cursor description).
  (it "copy-mode-set-mark-noop-table"
    (dolist (row '((nil (0 . 0) "mark must remain NIL when not in copy mode")
                   (t   nil     "mark must remain NIL when cursor is NIL")))
      (destructuring-bind (mode-p cursor desc) row
        (declare (ignore desc))
        (let ((s (make-screen 20 5)))
          (setf (screen-copy-mode-p s)                       mode-p
                (nerimux/terminal/types:screen-copy-cursor s) cursor
                (nerimux/terminal/types:screen-copy-mark   s) nil)
          (nerimux/commands::copy-mode-set-mark s)
          (expect (nerimux/terminal/types:screen-copy-mark s) :to-be-falsy)))))

  ;;; ── copy-mode-goto-line ──────────────────────────────────────────────────────

  ;; copy-mode-goto-line N with no scrollback jumps to viewport row N-1.
  (it "copy-mode-goto-line-jumps-to-live-row"
    ;; 10-wide, 5-row screen, no scrollback: vrow = viewport-row (offset=0, sb-n=0).
    ;; goto-line 3 = vrow 2 = viewport row 2.
    (let ((s (make-screen 10 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 0))
      (nerimux/commands::copy-mode-goto-line s 3)
      (expect (= 2 (car (nerimux/terminal/types:screen-copy-cursor s))))))

  ;; copy-mode-goto-line clamps to the last valid row when N exceeds total rows.
  (it "copy-mode-goto-line-clamps-over-max"
    (let ((s (make-screen 10 3)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 0))
      ;; 999 is way past the total row count (3-row screen, no scrollback = vrows 0-2)
      (nerimux/commands::copy-mode-goto-line s 999)
      ;; After clamping, cursor row must be within [0, height-1]
      (expect (<= 0 (car (nerimux/terminal/types:screen-copy-cursor s)) 2))))

  ;; copy-mode-goto-line is a no-op when not in copy mode.
  (it "copy-mode-goto-line-noop-outside-copy-mode"
    (let ((s (make-screen 10 5)))
      (setf (screen-copy-mode-p s)  nil
            (nerimux/terminal/types:screen-copy-cursor s) (cons 0 0))
      ;; Should not signal any error, screen must stay out of copy mode.
      (nerimux/commands::copy-mode-goto-line s 1)
      (expect (nerimux/terminal/types:screen-copy-mode-p s) :to-be-falsy)))

  ;;; ── copy-mode-search-forward-incremental ─────────────────────────────────────

  ;; Neither incremental search function opens a prompt when not in copy mode.
  (it "copy-mode-search-incremental-noop-outside-copy-mode"
    (dolist (fn '(nerimux/commands::copy-mode-search-forward-incremental
                  nerimux/commands::copy-mode-search-backward-incremental))
      (let ((s (make-screen 10 5)))
        (setf (screen-copy-mode-p s) nil
              *prompt* nil
              nerimux/commands::*copy-mode-isearch-origin* nil)
        (funcall fn s)
        (expect *prompt* :to-be-falsy))))

  ;; copy-mode-search-forward/backward-incremental each open a prompt with the
  ;; correct direction label.  Each row: (fn-sym cursor label).
  (it "copy-mode-search-incremental-opens-prompt-with-correct-label"
    (dolist (row '((nerimux/commands::copy-mode-search-forward-incremental
                    (2 . 3) "search-forward")
                   (nerimux/commands::copy-mode-search-backward-incremental
                    (3 . 5) "search-backward")))
      (destructuring-bind (fn-sym cursor label) row
        (let ((s (make-screen 10 5)))
          (setf (screen-copy-mode-p s)  t
                (screen-copy-cursor  s)  cursor
                (screen-copy-offset  s)  0
                *prompt* nil
                nerimux/commands::*copy-mode-isearch-origin* nil)
          (unwind-protect
              (progn
                (funcall fn-sym s)
                (expect *prompt* :to-be-truthy)
                (expect (string= label (prompt-label *prompt*))))
            (setf *prompt* nil
                  nerimux/commands::*copy-mode-isearch-origin* nil))))))

  ;; Saves cursor+offset in *copy-mode-isearch-origin* when prompt opens.
  (it "copy-mode-search-forward-incremental-saves-origin"
    (let ((s (make-screen 10 5)))
      (setf (screen-copy-mode-p s)  t
            (screen-copy-cursor  s)  (cons 2 3)
            (screen-copy-offset  s)  5
            *prompt* nil
            nerimux/commands::*copy-mode-isearch-origin* nil)
      (unwind-protect
          (progn
            (nerimux/commands::copy-mode-search-forward-incremental s)
            (let ((origin nerimux/commands::*copy-mode-isearch-origin*))
              (expect origin :to-be-truthy)
              (expect (equal (cons 2 3) (car origin)))
              (expect (= 5 (cdr origin)))))
        (setf *prompt* nil
              nerimux/commands::*copy-mode-isearch-origin* nil))))

  ;;; ── copy-mode-search-backward-incremental ────────────────────────────────────

  ;; prompt-clear (ESC/C-g) restores cursor and offset to pre-search position for
  ;; both forward and backward incremental search.
  ;; Each row: (fn-sym init-cursor init-offset moved-cursor moved-offset).
  (it "copy-mode-search-incremental-cancel-restores-cursor"
    (dolist (row '((nerimux/commands::copy-mode-search-forward-incremental
                    (2 . 3) 0 (0 . 1) 2)
                   (nerimux/commands::copy-mode-search-backward-incremental
                    (3 . 5) 1 (1 . 0) 3)))
      (destructuring-bind (fn-sym init-cursor init-offset moved-cursor moved-offset) row
        (let ((s (make-screen 10 5)))
          (setf (screen-copy-mode-p s)  t
                (screen-copy-cursor  s)  init-cursor
                (screen-copy-offset  s)  init-offset
                *prompt* nil
                nerimux/commands::*copy-mode-isearch-origin* nil)
          (funcall fn-sym s)
          (setf (screen-copy-cursor s) moved-cursor
                (screen-copy-offset s) moved-offset)
          (prompt-clear)
          (expect (equal init-cursor (screen-copy-cursor s)))
          (expect (= init-offset (screen-copy-offset s)))
          (expect nerimux/commands::*copy-mode-isearch-origin* :to-be-falsy)))))

  ;; Submitting a non-empty term (Enter) saves it plus the DIRECTION the
  ;; incremental search was opened with, so n/N repeat relative to it.
  ;; Each row: (fn-sym direction).
  (it "copy-mode-search-incremental-submit-saves-term-and-direction"
    (dolist (row '((nerimux/commands::copy-mode-search-forward-incremental  :forward)
                   (nerimux/commands::copy-mode-search-backward-incremental :backward)))
      (destructuring-bind (fn-sym direction) row
        (let ((s (make-screen 10 5)))
          (setf (screen-copy-mode-p s)  t
                (screen-copy-cursor  s)  (cons 0 0)
                (screen-copy-offset  s)  0
                *prompt* nil
                nerimux/commands::*copy-mode-isearch-origin* nil)
          (funcall fn-sym s)
          (funcall (prompt-on-submit *prompt*) "abc")
          (expect (string= "abc" (nerimux/terminal/types:screen-copy-search-term s)))
          (expect (eq direction (nerimux/terminal/types:screen-copy-search-direction s)))
          (expect nerimux/commands::*copy-mode-isearch-origin* :to-be-falsy)))))

  ;; Submitting an empty term (bare Enter) must NOT overwrite a previously
  ;; saved search term/direction -- this is the "cancel without typing" case.
  (it "copy-mode-search-incremental-submit-empty-term-leaves-saved-term-untouched"
    (let ((s (make-screen 10 5)))
      (setf (screen-copy-mode-p s)  t
            (screen-copy-cursor  s)  (cons 0 0)
            (screen-copy-offset  s)  0
            (nerimux/terminal/types:screen-copy-search-term      s) "previous"
            (nerimux/terminal/types:screen-copy-search-direction s) :backward
            *prompt* nil
            nerimux/commands::*copy-mode-isearch-origin* nil)
      (nerimux/commands::copy-mode-search-forward-incremental s)
      (funcall (prompt-on-submit *prompt*) "")
      (expect (string= "previous" (nerimux/terminal/types:screen-copy-search-term s)))
      (expect (eq :backward (nerimux/terminal/types:screen-copy-search-direction s)))))

  ;;; ── %copy-mode-isearch-from-origin (C-s/C-r live-update jump) ────────────────

  ;; With no origin saved yet, the function saves the current cursor/offset as
  ;; the origin and then recurses to perform the actual search from there.
  (it "copy-mode-isearch-from-origin-saves-origin-when-none-and-searches"
    (let ((s (make-screen 20 5)))
      (feed s "xx abc")
      (setf (screen-copy-mode-p s) t
            (screen-copy-cursor  s) (cons 0 0)
            (screen-copy-offset  s) 0
            nerimux/commands::*copy-mode-isearch-origin* nil)
      (nerimux/commands::%copy-mode-isearch-from-origin s "abc" :forward)
      (expect nerimux/commands::*copy-mode-isearch-origin* :to-be-truthy)
      (expect (equal (cons 0 0) (car nerimux/commands::*copy-mode-isearch-origin*)))
      (expect (= 3 (cdr (screen-copy-cursor s))))))

  ;; An empty TERM restores the cursor/offset to the saved origin (the
  ;; "nothing typed yet" state) rather than searching.
  (it "copy-mode-isearch-from-origin-empty-term-restores-origin"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s) t
            (screen-copy-cursor  s) (cons 2 5)
            (screen-copy-offset  s) 3
            nerimux/commands::*copy-mode-isearch-origin*
            (cons (cons 2 5) 3))
      (setf (screen-copy-cursor s) (cons 0 0)
            (screen-copy-offset s) 0)
      (nerimux/commands::%copy-mode-isearch-from-origin s "" :forward)
      (expect (equal (cons 2 5) (screen-copy-cursor s)))
      (expect (= 3 (screen-copy-offset s)))
      (expect (screen-dirty-p s) :to-be-truthy)))

  ;; A non-empty TERM with :backward jumps from the saved origin backward to
  ;; the nearest match -- covers the isearch engine's backward branch, which
  ;; every other isearch test (all :forward) leaves untouched.
  (it "copy-mode-isearch-from-origin-nonempty-backward-jumps-from-origin"
    (let ((s (make-screen 20 5)))
      (feed s "abc xyz abc")
      (setf (screen-copy-mode-p s) t
            nerimux/commands::*copy-mode-isearch-origin* (cons (cons 0 11) 0)
            (screen-copy-cursor s) (cons 0 11)
            (screen-copy-offset s) 0)
      (nerimux/commands::%copy-mode-isearch-from-origin s "abc" :backward)
      (expect (= 8 (cdr (screen-copy-cursor s))))))

  ;;; ── copy-mode-search-next / copy-mode-search-prev: outside copy mode ────────

  ;; copy-mode-search-next and copy-mode-search-prev are no-ops when not in
  ;; copy mode, even with a saved search term.
  (it "copy-mode-search-next-and-prev-noop-outside-copy-mode-table"
    (dolist (fn '(nerimux/commands::copy-mode-search-next
                  nerimux/commands::copy-mode-search-prev))
      (let ((s (make-screen 20 5)))
        (setf (screen-copy-mode-p s) nil
              (screen-copy-cursor  s) (cons 0 3)
              (nerimux/terminal/types:screen-copy-search-term s) "abc")
        (funcall fn s)
        (expect (equal (cons 0 3) (screen-copy-cursor s))))))

  ;;; ── copy-mode-search-forward / copy-mode-search-backward: guard clause ──────

  ;; Neither search-forward nor search-backward moves the cursor or saves the
  ;; term when the screen is not in copy mode.
  (it "copy-mode-search-forward-and-backward-noop-outside-copy-mode-table"
    (dolist (fn '(nerimux/commands::copy-mode-search-forward
                  nerimux/commands::copy-mode-search-backward))
      (let ((s (make-screen 20 5)))
        (feed s "abc")
        (setf (screen-copy-mode-p s) nil
              (screen-copy-cursor  s) (cons 0 0))
        (funcall fn s "abc")
        (expect (equal (cons 0 0) (screen-copy-cursor s)))
        (expect (null (nerimux/terminal/types:screen-copy-search-term s))))))

  ;; An empty TERM is also a no-op (in copy mode): the guard is
  ;; `(and copy-mode-p term (plusp (length term)))`, so an empty string must
  ;; short-circuit before any cursor movement or term-saving happens.
  (it "copy-mode-search-forward-and-backward-noop-on-empty-term-table"
    (dolist (fn '(nerimux/commands::copy-mode-search-forward
                  nerimux/commands::copy-mode-search-backward))
      (let ((s (make-screen 20 5)))
        (feed s "abc")
        (nerimux/commands::copy-mode-enter s)
        (setf (screen-copy-cursor s) (cons 0 0))
        (funcall fn s "")
        (expect (equal (cons 0 0) (screen-copy-cursor s)))
        (expect (null (nerimux/terminal/types:screen-copy-search-term s))))))

  ;;; ── copy-mode-next-matching-bracket ─────────────────────────────────────────

  ;; Cursor on '(' jumps forward to ')'; cursor on ')' jumps backward to '('.
  (it "copy-mode-next-matching-bracket-paren-table"
    (dolist (row '((2 0 6 "on '(' (col 0) → finds ')' (col 6)")
                   (2 6 0 "on ')' (col 6) → finds '(' (col 0)")))
      (destructuring-bind (start-row start-col expected-col desc) row
        (declare (ignore desc))
        (let ((s (make-screen 20 5)))
          (setf (screen-copy-mode-p s) t)
          (dotimes (i 7)
            (setf (nerimux/terminal/types:screen-cell s i 2)
                  (nerimux/terminal/types:make-cell :char (char "( foo )" i))))
          (setf (screen-copy-cursor s) (cons start-row start-col)
                (screen-copy-offset  s) 0)
          (nerimux/commands::copy-mode-next-matching-bracket s)
          (expect (= expected-col (cdr (screen-copy-cursor s))))))))

  ;; Nested brackets: cursor on outer '(' jumps to the outer matching ')'.
  (it "copy-mode-next-matching-bracket-nested-brackets"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s) t)
      ;; Write "(a(b)c)" at row 0.
      (dotimes (i 7)
        (setf (nerimux/terminal/types:screen-cell s i 0)
              (nerimux/terminal/types:make-cell :char (char "(a(b)c)" i))))
      (setf (screen-copy-cursor s) (cons 0 0)
            (screen-copy-offset  s) 0)
      (nerimux/commands::copy-mode-next-matching-bracket s)
      (expect (= 6 (cdr (screen-copy-cursor s))))))

  ;; Bracket matching is a no-op when not in copy mode.
  (it "copy-mode-next-matching-bracket-noop-outside-copy-mode"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s) nil
            (screen-copy-cursor  s) (cons 0 3))
      (nerimux/commands::copy-mode-next-matching-bracket s)
      (expect (equal (cons 0 3) (screen-copy-cursor s)))))

  ;; previous-matching-bracket jumps backward to the matching '(' from various positions.
  ;; Each row: (string nchars cursor-col description).
  (it "copy-mode-previous-matching-bracket-table"
    (dolist (row '(("( foo )"      7  6 "cursor on ')' jumps to matching '('")
                   ("( foo ) tail" 12 8 "cursor after a matched pair finds the previous close")))
      (destructuring-bind (str nchars col desc) row
        (declare (ignore desc))
        (let ((s (make-screen 20 5)))
          (setf (screen-copy-mode-p s) t)
          (dotimes (i nchars)
            (setf (nerimux/terminal/types:screen-cell s i 2)
                  (nerimux/terminal/types:make-cell :char (char str i))))
          (setf (screen-copy-cursor s) (cons 2 col)
                (screen-copy-offset  s) 0)
          (nerimux/commands::copy-mode-previous-matching-bracket s)
          (expect (= 0 (cdr (screen-copy-cursor s))))))))

  ;; Previous bracket matching is a no-op when not in copy mode.
  (it "copy-mode-previous-matching-bracket-noop-outside-copy-mode"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s) nil
            (screen-copy-cursor  s) (cons 0 3))
      (nerimux/commands::copy-mode-previous-matching-bracket s)
      (expect (equal (cons 0 3) (screen-copy-cursor s)))))

  ;; A bracket pair spanning two rows is matched across the row boundary —
  ;; every other bracket test keeps both brackets on one row.
  (it "copy-mode-next-matching-bracket-crosses-row-boundary"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s) t)
      (setf (nerimux/terminal/types:screen-cell s 0 0)
            (nerimux/terminal/types:make-cell :char #\())
      (setf (nerimux/terminal/types:screen-cell s 3 1)
            (nerimux/terminal/types:make-cell :char #\)))
      (setf (screen-copy-cursor s) (cons 0 0)
            (screen-copy-offset  s) 0)
      (nerimux/commands::copy-mode-next-matching-bracket s)
      (expect (equal (cons 1 3) (screen-copy-cursor s)))))

  ;; An open bracket with no matching close anywhere in the buffer leaves the
  ;; cursor untouched — every other bracket test has a real match to find.
  (it "copy-mode-next-matching-bracket-no-match-leaves-cursor"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s) t)
      (setf (nerimux/terminal/types:screen-cell s 0 0)
            (nerimux/terminal/types:make-cell :char #\())
      (setf (screen-copy-cursor s) (cons 0 0)
            (screen-copy-offset  s) 0)
      (nerimux/commands::copy-mode-next-matching-bracket s)
      (expect (equal (cons 0 0) (screen-copy-cursor s)))))

  ;; Cursor NOT on a bracket ("x ( y )", cursor on 'x') must find the next
  ;; bracket forward ('(' at col 2) and then jump to ITS match (')' at col 6)
  ;; -- every other next-matching-bracket test starts cursor ON a bracket.
  (it "copy-mode-next-matching-bracket-cursor-not-on-bracket-finds-forward"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s) t)
      (dotimes (i 7)
        (setf (nerimux/terminal/types:screen-cell s i 2)
              (nerimux/terminal/types:make-cell :char (char "x ( y )" i))))
      (setf (screen-copy-cursor s) (cons 2 0)
            (screen-copy-offset  s) 0)
      (nerimux/commands::copy-mode-next-matching-bracket s)
      (expect (= 6 (cdr (screen-copy-cursor s))))))

  ;; Nested brackets matched BACKWARD: cursor on the outer ')' must skip over
  ;; the inner "(b)" pair and land on the outer '('. The forward direction has
  ;; an equivalent test above; the backward nesting/depth-tracking path was
  ;; otherwise never exercised.
  (it "copy-mode-previous-matching-bracket-nested-brackets"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s) t)
      ;; Write "(a(b)c)" at row 0.
      (dotimes (i 7)
        (setf (nerimux/terminal/types:screen-cell s i 0)
              (nerimux/terminal/types:make-cell :char (char "(a(b)c)" i))))
      (setf (screen-copy-cursor s) (cons 0 6)
            (screen-copy-offset  s) 0)
      (nerimux/commands::copy-mode-previous-matching-bracket s)
      (expect (= 0 (cdr (screen-copy-cursor s))))))

  ;; A bracket pair spanning two rows matched BACKWARD -- the forward
  ;; direction has an equivalent cross-row test above; scanning backward
  ;; across a row boundary was otherwise never exercised.
  (it "copy-mode-previous-matching-bracket-crosses-row-boundary"
    (let ((s (make-screen 20 5)))
      (setf (screen-copy-mode-p s) t)
      (setf (nerimux/terminal/types:screen-cell s 0 0)
            (nerimux/terminal/types:make-cell :char #\())
      (setf (nerimux/terminal/types:screen-cell s 3 1)
            (nerimux/terminal/types:make-cell :char #\)))
      (setf (screen-copy-cursor s) (cons 1 3)
            (screen-copy-offset  s) 0)
      (nerimux/commands::copy-mode-previous-matching-bracket s)
      (expect (equal (cons 0 0) (screen-copy-cursor s))))))
