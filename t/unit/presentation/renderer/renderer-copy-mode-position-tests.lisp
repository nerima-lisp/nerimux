(in-package #:nerimux/test)

;;;; Direct unit tests for %COPY-MODE-POSITION-OVERLAY-TEXT /
;;;; %RENDER-COPY-MODE-POSITION-OVERLAY (renderer-pane-copy-mode-overlay.lisp),
;;;; the R6.8 copy-mode position display: "[POS/LIMIT]", with " /TERM" while a
;;;; search is active and " INDEX/TOTAL" naming which match the cursor is on.
;;;;
;;;; The ordinal is stored on the screen by the search, not derived at render
;;;; time: counting matches scans the whole virtual buffer, and this overlay is
;;;; drawn every frame. So the two halves are tested in two places -- the
;;;; census itself in the copy-mode search tests, and here only that a recorded
;;;; census reaches the string.

(describe "renderer-suite/copy-mode-position-text"

  ;; No active search: just "[POS/LIMIT]".
  (it "renders [pos/limit] with no search term active"
    (let ((pane (make-test-pane 40 10 :id 1)))
      (setf (screen-copy-offset (pane-screen pane)) 12)
      (setf (screen-scrollback (pane-screen pane)) (make-list 3400))
      (expect (string= "[12/3400]"
                       (nerimux/renderer::%copy-mode-position-overlay-text pane)))))

  ;; An active, non-empty search term appends " /TERM" -- this is where the
  ;; implementation stops short of the literal requirement text's trailing
  ;; "2/7" match-ordinal (see the file-level comment above).
  (it "appends the search term but not a match ordinal, unlike the requirement's literal example"
    (let ((pane (make-test-pane 40 10 :id 1)))
      (setf (screen-copy-offset (pane-screen pane)) 12)
      (setf (screen-scrollback (pane-screen pane)) (make-list 3400))
      (setf (nerimux/terminal/types:screen-copy-search-term (pane-screen pane))
            "pattern")
      (let ((text (nerimux/renderer::%copy-mode-position-overlay-text pane)))
        (expect (string= "[12/3400] /pattern" text))
        (expect (not (search "2/7" text))))))

  ;; An empty-string search term (as opposed to NIL) is treated the same as
  ;; no search -- the PLUSP LENGTH guard in %COPY-MODE-POSITION-OVERLAY-TEXT.
  (it "treats an empty-string search term the same as no search term"
    (let ((pane (make-test-pane 40 10 :id 1)))
      (setf (screen-copy-offset (pane-screen pane)) 0)
      (setf (screen-scrollback (pane-screen pane)) nil)
      (setf (nerimux/terminal/types:screen-copy-search-term (pane-screen pane)) "")
      (expect (string= "[0/0]"
                       (nerimux/renderer::%copy-mode-position-overlay-text pane))))))

(describe "renderer-suite/copy-mode-position-overlay-rendering"

  ;; The overlay is suppressed entirely outside copy-mode.
  (it "renders nothing when the pane is not in copy-mode"
    (let ((pane (make-test-pane 40 10 :id 1))
          (stream (make-string-output-stream)))
      (nerimux/renderer::%render-copy-mode-position-overlay stream pane 0 0 40)
      (expect (string= "" (get-output-stream-string stream)))))

  ;; The overlay is suppressed by copy-mode -H (screen-copy-hide-position),
  ;; even while in copy-mode.
  (it "renders nothing when copy-hide-position is set, even in copy-mode"
    (let ((pane (make-test-pane 40 10 :id 1))
          (stream (make-string-output-stream)))
      (setf (screen-copy-mode-p (pane-screen pane)) t)
      (setf (nerimux/terminal/types:screen-copy-hide-position (pane-screen pane))
            t)
      (nerimux/renderer::%render-copy-mode-position-overlay stream pane 0 0 40)
      (expect (string= "" (get-output-stream-string stream)))))

  ;; With copy-mode on and hide-position off, the fixed-format position text
  ;; actually reaches the stream.
  (it "renders the fixed-format position text when in copy-mode"
    (let ((pane (make-test-pane 40 10 :id 1))
          (stream (make-string-output-stream)))
      (setf (screen-copy-mode-p (pane-screen pane)) t)
      (setf (screen-copy-offset (pane-screen pane)) 5)
      (setf (screen-scrollback (pane-screen pane)) (make-list 100))
      (nerimux/renderer::%render-copy-mode-position-overlay stream pane 0 0 40)
      (expect (search "[5/100]" (get-output-stream-string stream)))))

  ;; R6.8's full form: "[12/3400] /pattern 2/7".
  (it "appends the match ordinal recorded by the search"
    (let* ((pane (make-test-pane 40 10 :id 1))
           (screen (pane-screen pane)))
      (setf (screen-copy-offset screen) 12
            (screen-scrollback screen) (make-list 3400)
            (nerimux/terminal/types:screen-copy-search-term screen) "pattern"
            (nerimux/terminal/types:screen-copy-search-index screen) 2
            (nerimux/terminal/types:screen-copy-search-total screen) 7)
      (expect (string= "[12/3400] /pattern 2/7"
                       (nerimux/renderer::%copy-mode-position-overlay-text pane)))))

  ;; A term whose search found nothing must not wear the previous search's
  ;; numbers -- "2/7" beside a term with no matches states something false.
  (it "omits the ordinal when no search has landed"
    (let* ((pane (make-test-pane 40 10 :id 1))
           (screen (pane-screen pane)))
      (setf (screen-copy-offset screen) 12
            (screen-scrollback screen) (make-list 3400)
            (nerimux/terminal/types:screen-copy-search-term screen) "pattern"
            (nerimux/terminal/types:screen-copy-search-index screen) nil
            (nerimux/terminal/types:screen-copy-search-total screen) 0)
      (expect (string= "[12/3400] /pattern"
                       (nerimux/renderer::%copy-mode-position-overlay-text pane))))))
