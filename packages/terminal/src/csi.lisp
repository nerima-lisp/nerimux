(in-package #:nerimux/terminal/csi)

;;;; CSI (Control Sequence Introducer) declarative rule table.
;;;;
;;;; define-csi-rule-set in csi-dispatch.lisp names these facts for composition.
;;;; Parameter interpretation lives in csi-parameters.lisp.
;;;; All grid mutations (insert/delete chars, scroll-region margins, alternate
;;;; screen) live in nerimux/terminal/actions; the rule table below calls them
;;;; directly.
;;;;
;;; The response-queue reply layer (DSR/DA1/DA2/DA3/XTVERSION/CPR fixed and
;;; computed replies, DECRQM mode-state tables, XTWINOPS size-report helpers)
;;; called by the rules below lives in csi-replies.lisp, which loads first.

(define-csi-rule-set csi-screen-rules

  ;; CUU – Cursor Up
  ((and (null intermed) (char= final #\A))
   (set-cursor screen (screen-cursor-x screen) (- (screen-cursor-y screen) p1*)))

  ;; CUD – Cursor Down
  ((and (null intermed) (char= final #\B))
   (set-cursor screen (screen-cursor-x screen) (+ (screen-cursor-y screen) p1*)))

  ;; CUF – Cursor Forward (right)
  ((and (null intermed) (char= final #\C))
   (set-cursor screen (+ (screen-cursor-x screen) p1*) (screen-cursor-y screen)))

  ;; CUB – Cursor Back (left)
  ((and (null intermed) (char= final #\D))
   (set-cursor screen (- (screen-cursor-x screen) p1*) (screen-cursor-y screen)))

  ;; CNL – Cursor Next Line
  ((and (null intermed) (char= final #\E))
   (set-cursor screen 0 (+ (screen-cursor-y screen) p1*)))

  ;; CPL – Cursor Preceding Line
  ((and (null intermed) (char= final #\F))
   (set-cursor screen 0 (- (screen-cursor-y screen) p1*)))

  ;; CHA – Cursor Horizontal Absolute (1-based column)
  ((and (null intermed) (char= final #\G))
   (set-cursor screen (1- p1*) (screen-cursor-y screen)))

  ;; HPA – Horizontal Position Absolute (CSI `; 1-based column, alias of CHA).
  ((and (null intermed) (char= final #\`))
   (set-cursor screen (1- p1*) (screen-cursor-y screen)))

  ;; HPR – Horizontal Position Relative (CSI a; move right P1, alias of CUF).
  ((and (null intermed) (char= final #\a))
   (set-cursor screen (+ (screen-cursor-x screen) p1*) (screen-cursor-y screen)))

  ;; VPR – Vertical Position Relative (CSI e; move down P1, alias of CUD).
  ((and (null intermed) (char= final #\e))
   (set-cursor screen (screen-cursor-x screen) (+ (screen-cursor-y screen) p1*)))

  ;; SCOSC – Save Cursor Position (CSI s; ANSI.SYS, complements ESC 7 / DECSC).
  ;; This is the OUTPUT (pane → screen) meaning.  On INPUT, CSI <code> u is the
  ;; extended-keys decode handled in events-keystroke.lisp — a separate path, so
  ;; there is no conflict with the CSI u (SCORC) restore below.
  ((and (null intermed) (char= final #\s))
   (save-cursor screen))

  ;; SCORC – Restore Cursor Position (CSI u; ANSI.SYS, complements ESC 8 / DECRC).
  ((and (null intermed) (char= final #\u))
   (restore-cursor screen))

  ;; CUP – Cursor Position (row P1, col P2, 1-based; row is DECOM-aware)
  ((and (null intermed) (char= final #\H))
   (set-cursor screen (1- p2*) (%cup-row screen p1*)))

  ;; ICH – Insert Characters
  ((and (null intermed) (char= final #\@))
   (insert-chars screen p1*))

  ;; ED – Erase in Display
  ((and (null intermed) (char= final #\J))
   (erase-display screen p1))

  ;; EL – Erase in Line
  ((and (null intermed) (char= final #\K))
   (erase-line screen p1))

  ;; IL – Insert Lines at the cursor row
  ((and (null intermed) (char= final #\L))
   (insert-lines screen p1*))

  ;; DL – Delete Lines at the cursor row
  ((and (null intermed) (char= final #\M))
   (delete-lines screen p1*))

  ;; DCH – Delete Characters
  ((and (null intermed) (char= final #\P))
   (delete-chars screen p1*))

  ;; SU – Scroll Up
  ((and (null intermed) (char= final #\S))
   (dotimes (_ p1*) (scroll-up-one screen)))

  ;; SD – Scroll Down
  ((and (null intermed) (char= final #\T))
   (dotimes (_ p1*) (scroll-down-one screen)))

  ;; ECH – Erase Characters (fill with blanks, no shift)
  ((and (null intermed) (char= final #\X))
   (erase-region screen
                 (screen-cursor-x screen) (screen-cursor-y screen)
                 (min (+ (screen-cursor-x screen) p1* -1)
                      (1- (screen-width screen)))
                 (screen-cursor-y screen)))

  ;; REP – Repeat Preceding Character (CSI Ps b)
  ;; Repeats the last printed character P1* times.  The preceding character is
  ;; tracked via the SCREEN-LAST-CHAR slot; if nothing has been written yet
  ;; the sequence is a no-op, which matches xterm behaviour.
  ((and (null intermed) (char= final #\b))
   ;; Count comes from the RAW param: an explicit 0 (CSI 0 b) repeats 0 times
   ;; (a no-op), while an ABSENT param (CSI b) defaults to 1.  p1* = (max 1 p1)
   ;; cannot tell these apart because p1 is 0 in both cases.
   (let ((preceding-char (screen-last-char screen))
         (count          (if params (first params) 1)))
     (when preceding-char
       (dotimes (_ count) (write-char-at-cursor screen preceding-char)))))

  ;; VPA – Vertical Position Absolute (1-based row)
  ((and (null intermed) (char= final #\d))
   (set-cursor screen (screen-cursor-x screen) (1- p1*)))

  ;; HVP – Horizontal and Vertical Position (same as CUP)
  ((and (null intermed) (char= final #\f))
   (set-cursor screen (1- p2*) (%cup-row screen p1*)))

  ;; SGR – Select Graphic Rendition
  ((and (null intermed) (char= final #\m))
   (apply-sgr screen params)))
