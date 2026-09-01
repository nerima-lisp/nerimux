(in-package #:nerimux/terminal/actions)

;;;; Scroll operations and scroll-region setup.
;;;;
;;;; Loads BEFORE cursor.lisp, erase.lisp, and edit.lisp:
;;;;   cursor.lisp needs scroll-up-one;
;;;;   erase.lisp and edit.lisp need %copy-row / %clear-row.
;;; ── Row primitives (data-layer helpers) ─────────────────────────────────────
;;;
;;; Both scroll operations and line-edit operations (insert-lines, delete-lines)
;;; work row-by-row.  %copy-row and %clear-row are the shared building blocks.
(defun %copy-row (screen dst-row src-row)
  "Copy all cells from SRC-ROW to DST-ROW within SCREEN."
  (dotimes (col (screen-width screen))
    (setf (screen-cell screen col dst-row) (screen-cell screen col src-row))))

(defun %erase-cell (screen)
  "A blank cell carrying the current background colour (BCE — background colour
   erase).  Cells cleared by ED/EL/ECH, the blanks introduced by IL/DL/ICH/DCH,
   and lines exposed by scrolling take the current SGR background so a themed app
   that sets a background then clears renders that colour, not the default.  Only
   the background carries over; foreground and attributes reset to default."
  (make-cell :bg (screen-cur-bg screen)))

(defun %clear-row (screen row)
  "Fill every cell in ROW with a background-colour-erase blank (BCE)."
  (dotimes (col (screen-width screen))
    (setf (screen-cell screen col row) (%erase-cell screen))))

;;; ── Scroll operations ───────────────────────────────────────────────────────
;;; ── Scrollback trimming ────────────────────────────────────────────────────
(defconstant +max-scrollback-lines+
  10000
  "Scrollback cap, in rows (§1.4).

   This used to be a 1000-row fallback behind *HISTORY-LIMIT-FUNCTION*, a
   callback the bootstrap layer installed so the terminal model never reached up
   into the options package. With the option gone there is one number and no
   injection point, so the callback and its fallback collapse into this.")

(defun trim-scroll-history (screen)
  "Cap the scrollback buffer of SCREEN to +MAX-SCROLLBACK-LINES+.
   Called after every scroll-up."
  (let* ((cap +max-scrollback-lines+)
         (len (length (screen-scrollback screen))))
    (when (> len cap)
      (let ((tail (nthcdr (1- cap) (screen-scrollback screen))))
        (when tail (setf (cdr tail) nil)))
      ;; Truncate the parallel wrap-flag list in lockstep.
      (let ((wtail (nthcdr (1- cap) (screen-scrollback-wrapped screen))))
        (when wtail (setf (cdr wtail) nil)))
      ;; Rows dropped forever shift the absolute-index base; prune OSC 133
      ;; prompt marks that now point below the retained history.
      (incf (screen-history-trimmed screen) (- len cap))
      (setf (screen-prompt-marks screen)
            (delete-if (lambda (m) (< m (screen-history-trimmed screen)))
                       (screen-prompt-marks screen))))))

;;; Clearing the whole screen (ED 2, or the `clear` command) first scrolls the
;;; visible content into history, so what was on screen stays reachable in the
;;; scrollback. This was the `scroll-on-clear` option, reached through a callback
;;; the bootstrap layer installed; it is now unconditional, so both the option
;;; and the injection point are gone and ERASE-DISPLAY simply always scrolls.
(defun %push-row-to-scrollback (screen row)
  "Copy ROW of SCREEN into a new vector and prepend it to the scrollback list.
   Enforces the history cap via TRIM-SCROLL-HISTORY after the push.
   Used by SCROLL-UP-ONE and SCROLL-SCREEN-TO-HISTORY."
  (let* ((w (screen-width screen))
         (saved (make-array w)))
    (dotimes (col w) (setf (aref saved col) (screen-cell screen col row)))
    (push saved (screen-scrollback screen))
    ;; Keep the wrap flag with the row it belongs to (capture-pane -J).
    (push (%line-wrapped-p screen row) (screen-scrollback-wrapped screen))
    (trim-scroll-history screen)))

(defun scroll-screen-to-history (screen)
  "Push every visible row of SCREEN into the scrollback (so a full-screen clear keeps
   its content in history), then enforce the history cap.  No-op on the alternate
   screen, which has no scrollback.  Backs scroll-on-clear before an ED-2 erase.
   Rows are pushed top→bottom so the top row ends up oldest in the newest-first list."
  (unless (screen-alt-cells screen)
    (dotimes (row (screen-height screen))
      (%push-row-to-scrollback screen row))))

(defun scroll-up-one (screen)
  "Scroll the scroll region up one line; the displaced top row is pushed onto
   the scrollback buffer ONLY when the scroll region starts at the top of the
   screen (scroll-top = 0) and we are on the primary screen (not alt-screen).
   This is the correct scrollback rule: partial-region scrolling and
   alt-screen scrolling never add to the scrollback history.

   Scrollback cap note: the cap is enforced by trim-scroll-history which
   splices off the tail cons of the list, keeping the operation O(limit).
   The list is maintained newest-first so the tail is always the oldest entry."
  (let* ((top    (screen-scroll-top    screen))
         (bottom (screen-scroll-bottom screen)))
    ;; Only the primary screen with a full-top scroll region contributes to
    ;; the scrollback history (see this function's docstring for why).
    (when (and (zerop top) (null (screen-alt-cells screen)))
      (%push-row-to-scrollback screen top))
    ;; Copy row+1 → row (shift content upward within the scroll region).
    (loop for row from top below bottom
          do (%copy-row screen row (1+ row)))
    (%clear-row screen bottom)
    ;; Shift the capture-pane -J wrap flags in lockstep with the content.
    (%shift-line-wrapped-up screen top bottom)
    ;; Shift the DECDHL/DECDWL row sizes with their lines.
    (let ((sizes (screen-line-sizes screen)))
      (when (plusp (hash-table-count sizes))
        (loop for row from top below bottom
              do (let ((below (gethash (1+ row) sizes)))
                   (if below
                       (setf (gethash row sizes) below)
                       (remhash row sizes))))
        (remhash bottom sizes)))
    (setf (screen-dirty-p screen) t)))

(defun clear-scrollback (screen)
  "Clear SCREEN's scrollback history; the visible grid is left intact.
   Backs the clear-history command: drops the accumulated scrollback while
   leaving the visible grid untouched."
  (incf (screen-history-trimmed screen) (length (screen-scrollback screen)))
  (setf (screen-scrollback screen) nil
        (screen-scrollback-wrapped screen) nil
        (screen-prompt-marks screen) (delete-if
                                      (lambda (m)
                                        (< m (screen-history-trimmed screen)))
                                      (screen-prompt-marks screen))))

(defun trim-below-cursor (screen)
  "resize-pane -T: drop the rows below the cursor and pull rows out of the
   scrollback to refill the screen from the top — the surviving content shifts
   down so the cursor row becomes the bottom row, trimming all lines below the
   cursor position and pulling replacement lines out of the history.
   No-op when the cursor is already on the bottom row or on the alt screen
   (which has no history)."
  (unless (screen-alt-cells screen)
    (let* ((h    (screen-height screen))
           (w    (screen-width screen))
           (cy   (screen-cursor-y screen))
           (need (- h (1+ cy))))
      (when (plusp need)
        ;; Shift the surviving rows 0..cy down by NEED (bottom-up copy).
        (loop for y from cy downto 0
              do (%copy-row screen (+ y need) y))
        ;; Refill rows NEED-1..0 upward from the newest-first scrollback; rows
        ;; beyond the available history are cleared to blanks.
        (loop for y from (1- need) downto 0
              do (pop (screen-scrollback-wrapped screen))
                 (let ((saved (pop (screen-scrollback screen))))
                   (if saved
                       (dotimes (col w)
                         (setf (screen-cell screen col y)
                               (if (< col (length saved))
                                   (aref saved col)
                                   (blank-cell))))
                       (%clear-row screen y))))
        ;; Wrap flags no longer line up with the shifted content.
        (%clear-all-line-wrapped screen)
        (setf (screen-cursor-y screen) (1- h)
              (screen-dirty-p screen) t)))))

(defun scroll-down-one (screen)
  "Scroll the scroll region down one line; the new top line is cleared to blanks."
  (let ((top    (screen-scroll-top    screen))
        (bottom (screen-scroll-bottom screen)))
    (loop for row from bottom above top
          do (%copy-row screen row (1- row)))
    (%clear-row screen top)
    ;; Reverse index (RI) is rare; drop the -J wrap flags rather than track the
    ;; downward shift (safe — capture-pane -J then degrades to no-join, never a
    ;; wrong join).
    (%clear-all-line-wrapped screen)
    (setf (screen-dirty-p screen) t)))

;;; ── Scroll region ──────────────────────────────────────────────────────────
(defun decstbm (screen top bottom)
  "DECSTBM — set the vertical scroll region.
   TOP and BOTTOM are 0-based inclusive row indices.  The cursor is homed
   to (0,0) after a valid set."
  (let ((clamped-top (max 0 top))
        (clamped-bottom (min (1- (screen-height screen)) bottom)))
    (when (< clamped-top clamped-bottom)
      (setf (screen-scroll-top screen) clamped-top
            (screen-scroll-bottom screen) clamped-bottom)
      (set-cursor screen 0 0))))
