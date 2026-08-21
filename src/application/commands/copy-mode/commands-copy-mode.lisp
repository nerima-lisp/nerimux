(in-package #:nerimux/commands)

;;; ── Copy mode ──────────────────────────────────────────────────────────────
;;;
;;; copy_mode(enter, Screen) :- set(copy-mode-p, true), set(copy-offset, 0).
;;; copy_mode(exit, Screen)  :- set(copy-mode-p, false), set(copy-offset, 0).
;;; copy_mode(scroll, Screen, Delta)      :- copy-mode-p(Screen),
;;;                                          new_offset(clamp(offset+Delta, 0, len(scrollback))),
;;;                                          scroll_cursor_into_view(Screen).
;;; copy_mode(move_cursor, Screen, Dir)  :- copy-mode-p(Screen),
;;;                                          move_cursor_one(Screen, Dir),
;;;                                          scroll_to_ensure_visible(Screen).
;;; copy_mode(begin_selection, Screen) :- copy-mode-p(Screen),
;;;                                       set(mark, cursor), set(selecting, true).
;;; copy_mode(cancel, Screen) :- set(mark, nil), set(cursor, nil), set(selecting, false).
;;; copy_mode(yank, Screen)   :- selection_text(Screen, T), add_paste_buffer(T),
;;;                               copy_mode(cancel, Screen), copy_mode(exit, Screen).

(defun copy-mode-enter (screen &key scroll-to-top exit-on-bottom)
  "Enter copy/scroll mode on SCREEN: freeze the viewport at the live position.
   The copy-mode cursor is placed at the bottom-left of the viewport so that
   the first navigation key moves it naturally upward toward older content.
   SCROLL-TO-TOP T pre-scrolls to the oldest scrollback content (copy-mode -u).
   EXIT-ON-BOTTOM T (copy-mode -e) auto-exits copy mode when the viewport is
   scrolled back down to the live bottom (offset 0)."
  (setf (screen-copy-mode-p        screen) t
        (screen-copy-mark          screen) nil
        (screen-copy-mark-offset   screen) 0
        (screen-copy-selecting     screen) nil
        (screen-copy-exit-on-bottom screen) (and exit-on-bottom t))
  (if scroll-to-top
      ;; copy-mode -u: scroll to oldest content (max offset), cursor at top-left.
      (let ((max-offset (length (screen-scrollback screen))))
        (setf (screen-copy-offset screen) max-offset
              (screen-copy-cursor screen) (cons 0 0)))
      ;; Normal entry: live view, cursor at bottom-left.
      (setf (screen-copy-offset screen) 0
            (screen-copy-cursor screen) (cons (1- (screen-height screen)) 0))))

(defun copy-mode-exit (screen)
  "Exit copy mode: resume live PTY output display."
  (setf (screen-copy-mode-p        screen) nil
        (screen-copy-offset         screen) 0
        (screen-copy-mark           screen) nil
        (screen-copy-mark-offset    screen) 0
        (screen-copy-cursor         screen) nil
        (screen-copy-selecting      screen) nil
        (screen-copy-line-selection-p screen) nil
        (screen-copy-rect-select-p  screen) nil
        (screen-copy-exit-on-bottom screen) nil
        (screen-copy-mode-entered-by-mouse-p screen) nil))

(defun %clamp-row-col (screen row col)
  "Return (cons clamped-row clamped-col) with row in [0, height-1] and col in [0, width-1]."
  (cons (max 0 (min (1- (screen-height screen)) row))
        (max 0 (min (1- (screen-width  screen)) col))))

(defun %copy-mode-clamp-cursor (screen)
  "Clamp the copy-mode cursor row into [0, height-1] and col into [0, width-1].
   Called after the viewport offset changes so the cursor stays visible.
   Operates on the cursor cons directly; no-op when cursor is NIL."
  (let ((cursor (screen-copy-cursor screen)))
    (when cursor
      (setf (screen-copy-cursor screen)
            (%clamp-row-col screen (car cursor) (cdr cursor))))))

(defun copy-mode-scroll (screen delta)
  "Scroll SCREEN's viewport by DELTA lines (positive = older, negative = newer).
   The copy-mode cursor is clamped to remain within the visible viewport.
   This is the raw viewport-jump path used by Page-Up/Down, mouse wheel, g/G.
   Arrow-key and j/k navigation goes through COPY-MODE-MOVE-CURSOR instead."
  (when (screen-copy-mode-p screen)
    (let ((max-offset (length (screen-scrollback screen))))
      (setf (screen-copy-offset screen)
            (max 0 (min max-offset (+ (screen-copy-offset screen) delta))))
      (%copy-mode-clamp-cursor screen)
      (setf (screen-dirty-p screen) t)
      ;; copy-mode -e: auto-exit when scrolled back down to the live bottom.
      ;; Only triggers on a downward (newer) scroll that reaches offset 0.
      (when (and (screen-copy-exit-on-bottom screen)
                 (< delta 0)
                 (zerop (screen-copy-offset screen)))
        (copy-mode-exit screen)))))

;;; The *-and-cancel family (%copy-mode-with-cancel-at-bottom,
;;; define-copy-mode-cancel-commands + copy-mode-scroll-down-and-cancel /
;;; -page-down-and-cancel, copy-mode-cursor-down-and-cancel in
;;; commands-copy-mode-cursor.lisp), previous/next-prompt (+ their
;;; %copy-mode-cursor-absolute / %copy-mode-jump-to-absolute /
;;; %nearest-prompt-mark support), toggle-position (+ the
;;; define-copy-mode-toggle macro, once copy-mode-toggle-rectangle in
;;; commands-copy-mode-clip.lisp was also gone), stop-selection, and
;;; scroll-to-mouse were removed: none is reachable from
;;; %handle-client-copy-key-payload or any other live call site.

(defun copy-mode-begin-selection (screen)
  "Begin a text selection at the current copy-mode cursor position."
  (when (screen-copy-mode-p screen)
    (let ((cur (or (screen-copy-cursor screen) (cons 0 0))))
      (setf (screen-copy-mark        screen) cur
            (screen-copy-mark-offset screen) (screen-copy-offset screen)
            (screen-copy-cursor      screen) cur
            (screen-copy-selecting   screen) t
            (screen-dirty-p          screen) t))))

;;; copy-mode-set-mark, copy-mode-other-end, and copy-mode-jump-to-mark were
;;; removed: unreachable from %handle-client-copy-key-payload or any other
;;; live call site.

(defun %reset-selection-fields (screen)
  "Clear all selection state fields on SCREEN (selecting, mark, line/rect flags) and
   mark dirty.  Does NOT clear the cursor — callers that need that do so separately."
  (setf (screen-copy-selecting        screen) nil
        (screen-copy-mark             screen) nil
        (screen-copy-mark-offset      screen) 0
        (screen-copy-line-selection-p screen) nil
        (screen-copy-rect-select-p    screen) nil
        (screen-dirty-p               screen) t))

;;; copy-mode-clear-selection (the clear-selection copy-mode command) was removed: its only two
;;; callers, copy-mode-copy-selection-no-cancel and the :clear finish branch of
;;; define-copy-pipe-commands (commands-copy-mode-clip.lisp), were themselves
;;; dead and were deleted first; re-grepped for zero remaining callers before
;;; removing this one, per the caution that it looked dead on an earlier pass
;;; but was in fact still called at that time.

(defun copy-mode-cancel-selection (screen)
  "Cancel any active copy-mode selection."
  (setf (screen-copy-cursor screen) nil)
  (%reset-selection-fields screen))
