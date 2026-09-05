(in-package #:nerimux/commands)

(defun %rectangle-selection-text (screen)
  "Compute the rectangle-selected text for SCREEN.
   Returns a string, or NIL when no valid selection exists.
   In rectangle mode each row between start-row and end-row is extracted
   between fixed column bounds (min/max of mark-col and cursor-col)."
  (when 
      (and (screen-copy-selecting screen)
           (screen-copy-mark screen)
           (screen-copy-cursor screen))
    (multiple-value-bind (start-vrow end-vrow start-col end-col) 
        (%selection-bounds screen)
      (let* ((text
              (with-output-to-string (out)
                (loop for vrow from start-vrow to end-vrow
                      do (let* ((row-str
                                 (%extract-vrow-chars screen
                                                      vrow
                                                      start-col
                                                      end-col))
                                (trimmed (string-right-trim " " row-str)))
                           (write-string trimmed out)
                           (when (< vrow end-vrow)
                             (write-char #\Newline out)))))))
        (and (plusp (length text)) text)))))

(defun %get-selection-text (screen)
  "Return the selected text for SCREEN, respecting rectangle-select mode.
   Delegates to %rectangle-selection-text when rect-select is active, else
   %selection-text."
  (if (screen-copy-rect-select-p screen)
      (%rectangle-selection-text screen)
      (%selection-text screen)))

(defun %maybe-copy-to-clipboard (screen text)
  "Enqueue an OSC 52 sequence on SCREEN's clipboard-queue so the renderer
   copies TEXT to the host's system clipboard on the next frame."
  (push (nerimux/terminal/parser:osc52-clipboard-sequence text)
        (screen-clipboard-queue screen)))

(defun %copy-mode-do-yank (screen)
  "Shared copy work for the yank/copy-selection family: emit OSC 52 for the
   current selection text.  Does NOT touch the selection or copy-mode state.
   No-op when there is no selection text."
  (let ((text (%get-selection-text screen)))
    (when (and text (plusp (length text)))
      (%maybe-copy-to-clipboard screen text))))

(defun copy-mode-yank (screen)
  "Copy selected text to the host clipboard via OSC 52, then exit copy mode.
   In rectangle-select mode the rectangular region is used.  This is the
   exit-on-yank path bound to vi y / Enter / emacs M-w / mouse-drag-release."
  (%copy-mode-do-yank screen)
  (copy-mode-cancel-selection screen)
  (copy-mode-exit screen))
