(in-package #:nerimux/test/renderer)

(describe "renderer-suite/copy-mode-position-text"

  (it "renders [pos/limit] with no search term active"
    (let ((pane (make-test-pane 40 10 :id 1)))
      (setf (screen-copy-offset (pane-screen pane)) 12)
      (setf (screen-scrollback (pane-screen pane)) (make-list 3400))
      (expect (string= "[12/3400]"
                       (nerimux/renderer::%copy-mode-position-overlay-text pane)))))

  (it "appends the search term but not a match ordinal, unlike the requirement's literal example"
    (let ((pane (make-test-pane 40 10 :id 1)))
      (setf (screen-copy-offset (pane-screen pane)) 12)
      (setf (screen-scrollback (pane-screen pane)) (make-list 3400))
      (setf (nerimux/terminal/types:screen-copy-search-term (pane-screen pane))
            "pattern")
      (let ((text (nerimux/renderer::%copy-mode-position-overlay-text pane)))
        (expect (string= "[12/3400] /pattern" text))
        (expect (not (search "2/7" text))))))

  (it "treats an empty-string search term the same as no search term"
    (let ((pane (make-test-pane 40 10 :id 1)))
      (setf (screen-copy-offset (pane-screen pane)) 0)
      (setf (screen-scrollback (pane-screen pane)) nil)
      (setf (nerimux/terminal/types:screen-copy-search-term (pane-screen pane)) "")
      (expect (string= "[0/0]"
                       (nerimux/renderer::%copy-mode-position-overlay-text pane))))))

(describe "renderer-suite/copy-mode-position-overlay-rendering"

  (it "renders nothing when the pane is not in copy-mode"
    (let ((pane (make-test-pane 40 10 :id 1))
          (stream (make-string-output-stream)))
      (nerimux/renderer::%render-copy-mode-position-overlay stream pane 0 0 40)
      (expect (string= "" (get-output-stream-string stream)))))

  (it "renders nothing when copy-hide-position is set, even in copy-mode"
    (let ((pane (make-test-pane 40 10 :id 1))
          (stream (make-string-output-stream)))
      (setf (screen-copy-mode-p (pane-screen pane)) t)
      (setf (nerimux/terminal/types:screen-copy-hide-position (pane-screen pane))
            t)
      (nerimux/renderer::%render-copy-mode-position-overlay stream pane 0 0 40)
      (expect (string= "" (get-output-stream-string stream)))))

  (it "renders the fixed-format position text when in copy-mode"
    (let ((pane (make-test-pane 40 10 :id 1))
          (stream (make-string-output-stream)))
      (setf (screen-copy-mode-p (pane-screen pane)) t)
      (setf (screen-copy-offset (pane-screen pane)) 5)
      (setf (screen-scrollback (pane-screen pane)) (make-list 100))
      (nerimux/renderer::%render-copy-mode-position-overlay stream pane 0 0 40)
      (expect (search "[5/100]" (get-output-stream-string stream)))))

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
