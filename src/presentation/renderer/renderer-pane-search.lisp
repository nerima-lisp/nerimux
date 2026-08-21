(in-package #:nerimux/renderer)

;;; Copy-mode search-match highlighting for pane rendering.

(defun %screen-row-display-string (screen row)
  "The visible (offset-aware) content of ROW as a string."
  (with-output-to-string (s)
    (dotimes (col (screen-width screen))
      (write-char (cell-char (screen-display-cell screen col row)) s))))

(defun %all-match-ranges (term row-str)
  "All (START . END) column ranges in ROW-STR matching TERM: regex via
   cl-regex-kit, literal-substring fallback when TERM is not a valid regex.
   Zero-width matches are skipped.

   :OCTAL NIL MUST MATCH %COPY-MODE-MAKE-MATCHER (commands-copy-mode-search.lisp).
   These are two independent decisions about whether the same user TERM is a
   valid regex — one drives cursor motion for n/N, this one paints the highlight.
   Any difference in compile options desynchronises them.

   ALL-MATCHES returns a list of MATCH-RESULT structs, not cl-ppcre's flat list
   of alternating integers, so the ranges are read off with MATCH-START/MATCH-END
   instead of walking the list two at a time.  The compiled regex is now also
   reused for the scan rather than recompiled from the string, which the cl-ppcre
   version did (it compiled TERM once just to test validity, then handed the raw
   string to ALL-MATCHES)."
  (let ((scanner (ignore-errors (cl-regex-kit:compile-regex term :octal nil))))
    (if scanner
        (loop for match in (cl-regex-kit:all-matches scanner row-str)
              for s = (cl-regex-kit:match-start match)
              for e = (cl-regex-kit:match-end match)
              when (> e s) collect (cons s e))
        (loop with tlen = (length term) and start = 0
              for pos = (search term row-str :start2 start)
              while pos
              collect (cons pos (+ pos tlen))
              do (setf start (+ pos (max 1 tlen)))))))

;;; copy-mode-match-style / copy-mode-current-match-style are fixed at their
;;; registry defaults "bg=green" / "bg=magenta" (R2.2: no config exists to
;;; change them) — SGR "42" / "45" is what parse-style-string + style-to-sgr
;;; always resolved those two strings to, so the strings themselves are gone
;;; (R2.4) and only the resolved codes remain.

(defconstant +sgr-copy-mode-match+
    (if (boundp (quote +sgr-copy-mode-match+))
        (symbol-value (quote +sgr-copy-mode-match+))
        "42")
  "SGR for a copy-mode search match: bg=green.")
(defconstant +sgr-copy-mode-current-match+
    (if (boundp (quote +sgr-copy-mode-current-match+))
        (symbol-value (quote +sgr-copy-mode-current-match+))
        "45")
  "SGR for the copy-mode search match under the cursor: bg=magenta.")

(defun %render-row-search-matches (buffer row row-str term w
                                    cur-row cur-col match-sgr current-sgr
                                    ox oy)
  "Overdraw every TERM match in ROW-STR (screen row ROW, already offset by
   OX/OY) onto BUFFER in MATCH-SGR — CURRENT-SGR when the match spans
   (CUR-ROW . CUR-COL), the copy-mode cursor position."
  (dolist (range (%all-match-ranges term row-str))
    (let* ((start (car range))
           (end   (min (cdr range) w))
           (current-p (and (eql cur-row row) cur-col
                           (<= start cur-col) (< cur-col end)))
           (sgr   (if current-p (or current-sgr match-sgr) match-sgr)))
      (move-to buffer (+ oy row) (+ ox start))
      (%emit-sgr buffer sgr)
      (write-string (subseq row-str start end) buffer)
      (reset-attrs buffer))))

(defun %render-copy-search-matches (buffer pane)
  "When PANE's screen is in copy mode with an active search term, overdraw each
   matching span in copy-mode-match-style — the span under the copy cursor in
   copy-mode-current-match-style — over the already-rendered pane content."
  (let ((screen (pane-screen pane)))
    (when (and screen (screen-copy-mode-p screen))
      (let ((term (screen-copy-search-term screen)))
        (when (and term (plusp (length term)))
          (let* ((match-sgr   +sgr-copy-mode-match+)
                 (current-sgr  +sgr-copy-mode-current-match+)
                 (cursor       (screen-copy-cursor screen))
                 (cur-row      (and (consp cursor) (car cursor)))
                 (cur-col      (and (consp cursor) (cdr cursor)))
                 (ox           (pane-x pane))
                 (oy           (pane-y pane))
                 (w            (screen-width screen)))
            (when match-sgr
              (dotimes (row (screen-height screen))
                (let ((row-str (%screen-row-display-string screen row)))
                  (%render-row-search-matches buffer row row-str term w
                                               cur-row cur-col match-sgr current-sgr
                                               ox oy))))))))))
