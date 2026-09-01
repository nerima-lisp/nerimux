(in-package #:nerimux/commands)

;;;; Rectangle selection text, copy-pipe helpers, yank, append-selection.
;;;; Uses selection helpers from commands-copy-mode-selection.lisp and search
;;;; helpers from commands-copy-mode-search.lisp.
;;; ── Rectangle selection text ────────────────────────────────────────────────
;;;
;;; When rectangle select is active (screen-copy-rect-select-p), each row in
;;; the selection range is read between the same left and right column bounds
;;; (the canonical column range derived from mark and cursor column positions).
;;; Rows are joined with newlines; trailing spaces within each row are trimmed.
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

;;; ── Selection-text dispatch helper ──────────────────────────────────────────
(defun %get-selection-text (screen)
  "Return the selected text for SCREEN, respecting rectangle-select mode.
   Delegates to %rectangle-selection-text when rect-select is active, else
   %selection-text."
  (if (screen-copy-rect-select-p screen)
      (%rectangle-selection-text screen)
      (%selection-text screen)))

;;; ── Clipboard ─────────────────────────────────────────────────────────────
;;;
;;; yank sends the selection to the host terminal via OSC 52 only (§1.1/§R3.1
;;; of docs/notes/workspace-requirements.md: nerimux keeps no paste buffer and
;;; runs no copy-command).
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

;;; copy-mode-copy-selection-no-cancel/-no-clear, the rectangle-select toggle,
;;; append-selection(-and-cancel), the copy-pipe/pipe command family, and
;;; explicit rectangle-on/off were removed: none of them is reachable from
;;; %handle-client-copy-key-payload (the sole copy-mode dispatch entry in
;;; multi-dispatch command handlers) or from any other live call site — confirmed
;;; via grep for each bare identifier across src/, where the only hits were
;;; this file's own definitions and the export list in package-application.lisp.
