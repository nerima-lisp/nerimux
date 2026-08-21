(in-package #:nerimux/test)

;;;; Direct unit tests for %COPY-MODE-POSITION-OVERLAY-TEXT /
;;;; %RENDER-COPY-MODE-POSITION-OVERLAY (renderer-pane-copy-mode-overlay.lisp),
;;;; the R6.8 copy-mode position display: a fixed "[POS/LIMIT]" string,
;;;; with " /TERM" appended while a search is active.
;;;;
;;;; NOTE on a deliberate gap between the requirement text and the
;;;; implementation, confirmed by reading renderer-pane-copy-mode-overlay.lisp
;;;; itself (lines 14-22): docs/notes/workspace-requirements.md §R6.8 gives
;;;; "[12/3400] /pattern 2/7" as the target -- with a "current match/total
;;;; matches" ordinal ("2/7"). The implementation's own docstring says that
;;;; ordinal is deliberately NOT produced: nothing in this codebase currently
;;;; counts matches across the whole scrollback (the search highlighter,
;;;; %ALL-MATCH-RANGES in renderer-pane-search.lisp, only scans the visible
;;;; viewport once per frame to paint highlights, with no persistent index),
;;;; and the implementer judged that adding one is new domain-level tracking
;;;; out of scope for what was otherwise a template -> string-composition
;;;; swap. Per this agent's brief ("期待文字列は必ず実装から取れ"), the
;;;; expectations below match the ACTUAL "[POS/LIMIT]" / "[POS/LIMIT] /TERM"
;;;; output, not the requirement's literal "2/7"-suffixed example. Flagged to
;;;; the team lead in the R6/R7 test report as a spec/implementation gap, not
;;;; silently reconciled here.

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
      (expect (search "[5/100]" (get-output-stream-string stream))))))
