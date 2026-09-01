(in-package #:nerimux/test/commands)

;;;; linear selection-text — part III
(describe "commands-suite"

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
