(in-package #:nerimux/terminal/actions)

(defun %remap-charset-char (screen ch)
  "Apply a pending single shift or the active DEC graphics charset to CH."
  (let ((shift (screen-single-shift screen)))
    (cond
      (shift
        (setf (screen-single-shift screen) nil)
        (if (eq (screen-invoked-charset screen shift) :dec-graphics)
            (%dec-graphics-char ch)
            ch))
      ((eq (screen-charset screen) :dec-graphics) (%dec-graphics-char ch))
      (t ch))))

(defun %consume-pending-wrap (screen)
  "Perform the deferred VT100 wrap before the next printable character."
  (when (screen-pending-wrap screen)
    (%mark-line-wrapped screen (screen-cursor-y screen))
    (setf (screen-pending-wrap screen) nil
          (screen-cursor-x screen) 0)
    (cursor-down/scroll screen)))

(defun %apply-insert-mode-gap (screen ch)
  "Open a display-width gap for CH when insert mode is active."
  (when (screen-insert-mode screen)
    (insert-chars screen (char-width ch))))

(defun write-char-at-cursor (screen ch)
  "Write CH at the cursor according to width, charset, wrap, and insert modes."
  (if (combining-char-p ch)
      (%append-combining-char screen ch)
      (let ((remapped-ch
             (progn
               (%consume-pending-wrap screen)
               (%remap-charset-char screen ch))))
        (setf (screen-last-char screen) remapped-ch)
        (%apply-insert-mode-gap screen remapped-ch)
        (if (= (char-width remapped-ch) 2)
            (%write-wide-cell screen remapped-ch)
            (%write-normal-cell screen remapped-ch)))))

(defun write-codepoint (screen codepoint)
  "Write CODEPOINT at the cursor after converting it with SAFE-CODE-CHAR."
  (write-char-at-cursor screen (safe-code-char codepoint)))
