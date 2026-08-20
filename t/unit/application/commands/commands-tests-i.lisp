(in-package #:nerimux/test)

;;;; rectangle-sel-text, run-copy-command, and set-cursor

(describe "commands-suite"

  ;;; ── %rectangle-selection-text (direct unit tests) ────────────────────────────
  ;;;
  ;;; %rectangle-selection-text is exercised transitively through copy-mode-yank
  ;;; with rect-select=T.  These direct tests make boundary conditions explicit.

  ;; %rectangle-selection-text returns NIL when no selection is active.
  (it "rectangle-selection-text-returns-nil-when-no-selection"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-selecting s) nil)
      (expect (null (nerimux/commands::%rectangle-selection-text s)))))

  ;; %rectangle-selection-text returns NIL when mark is NIL even if selecting is T.
  (it "rectangle-selection-text-returns-nil-when-mark-nil"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-selecting s) t
            (nerimux/terminal/types:screen-copy-mark      s) nil
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 0 5))
      (expect (null (nerimux/commands::%rectangle-selection-text s)))))

  ;; %rectangle-selection-text returns the correct column slice for a single-row selection.
  (it "rectangle-selection-text-single-row"
    ;; Feed "hello world" to row 0; rectangle from col 0 to col 5 on row 0 only.
    (let ((s (make-screen 20 5)))
      (feed s "hello world")
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-selecting    s) t
            (nerimux/terminal/types:screen-copy-mark         s) (cons 0 0)
            (nerimux/terminal/types:screen-copy-cursor       s) (cons 0 5))
      (let ((text (nerimux/commands::%rectangle-selection-text s)))
        (expect (stringp text))
        (expect (string= "hello" text)))))

  ;; %rectangle-selection-text extracts the same column range on every row.
  (it "rectangle-selection-text-multi-row-fixed-columns"
    ;; Row 0 = "abcde", row 1 = "ABCDE"; rectangle col 1-3 (2 chars per row).
    (let ((s (make-screen 10 5)))
      (feed s (format nil "abcde~C~CABCDE" #\Return #\Linefeed))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-selecting s) t
            (nerimux/terminal/types:screen-copy-mark      s) (cons 0 1)
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 1 3))
      (let ((text (nerimux/commands::%rectangle-selection-text s)))
        (expect (stringp text))
        (expect (search "bc" text))
        (expect (search "BC" text))
        (expect (find #\Newline text)))))

  ;;; ── %run-copy-command (direct unit tests) ────────────────────────────────────
  ;;;
  ;;; %run-copy-command is exercised only transitively through copy-mode-yank when
  ;;; the 'copy-command' option is set.  These direct tests cover the no-op branch
  ;;; (empty option / empty text) and the error-handling contract.

  ;; %run-copy-command is a no-op for NIL and for an empty string.
  (it "run-copy-command-noop-when-nil-or-empty"
    (finishes (nerimux/commands::%run-copy-command nil)
              "%run-copy-command with nil text must not signal")
    (finishes (nerimux/commands::%run-copy-command "")
              "%run-copy-command with empty text must not signal"))

  ;; %run-copy-command is a no-op when the 'copy-command' option is not set.
  (it "run-copy-command-noop-when-option-unset"
    ;; Fresh option table: 'copy-command' is absent.
    (with-fresh-global-options
      (finishes (nerimux/commands::%run-copy-command "some text")
                "%run-copy-command with no copy-command option must not signal")))

  ;; %run-copy-command swallows errors from a malformed copy-command.
  (it "run-copy-command-does-not-crash-on-bad-command"
    ;; Set copy-command to a command that will fail (exit non-zero or not found).
    (let ((nerimux/options:*global-options*
           (let ((h (make-hash-table :test #'equal)))
             (setf (gethash "copy-command" h) "false")
             h)))
      (finishes (nerimux/commands::%run-copy-command "hello")
                "%run-copy-command must not signal when the copy-command fails")))

  )
