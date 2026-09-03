(in-package #:nerimux/terminal/actions)

;;;; Viewport projection: map a (col, row) viewport position to the cell shown for
;;;; the current copy-mode scroll state, reading from scrollback or the live grid.
;;; ── Display projection (copy-mode scrollback) ──────────────────────────────
(defparameter *display-blank-cell*
  (blank-cell)
  "Shared immutable blank cell for out-of-range display lookups.
   Safe to share because cells are never mutated in place.")

(defun %scrollback-cell (screen col offset-from-top)
  "Return the cell at COLUMN COL in the scrollback row OFFSET-FROM-TOP rows above
   the live grid top (1-based: 1 = newest scrollback row).
   Returns *display-blank-cell* when the row or column is out of range."
  (let ((vec (nth (1- offset-from-top) (screen-scrollback screen))))
    (if (and vec (< col (length vec)))
        (aref vec col)
        *display-blank-cell*)))

(defun %live-grid-cell (screen col live-row)
  "Return the live grid cell at COLUMN COL, ROW LIVE-ROW.
   Returns *display-blank-cell* when LIVE-ROW is beyond the screen height."
  (if (< live-row (screen-height screen))
      (screen-cell screen col live-row)
      *display-blank-cell*))

(defun screen-display-cell (screen col row &optional viewport)
  "Cell shown at viewport position (COL, ROW) for the current scroll state.
   With copy-offset 0 this is the live grid cell.  When scrolled back by N
   lines the top N rows come from the scrollback buffer and the live grid
   is shifted down by N rows.  VIEWPORT adds a client-local scroll offset
   without mutating the shared screen's copy-mode state.  Out-of-range reads
   return *display-blank-cell*."
  (let ((offset
         (+
          (if (screen-copy-mode-p screen)
              (screen-copy-offset screen)
              0)
          (max 0 (or viewport 0)))))
    (if (< row offset)
        (%scrollback-cell screen col (- offset row))
        (%live-grid-cell screen col (- row offset)))))
