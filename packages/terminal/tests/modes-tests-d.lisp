(in-package #:nerimux/test/terminal)

(defun test-dec-pm-toggle-boolean (mode accessor)
  "Shared helper: verify that DEC PM MODE toggles boolean ACCESSOR on SCREEN
   to T on set (h) and back to NIL on reset (l)."
  (with-screen (s 20 5)
               (expect (funcall accessor s) :to-be-falsy)
               (feed s (esc "[?~Dh" mode))
               (expect (funcall accessor s) :to-be-truthy)
               (feed s (esc "[?~Dl" mode))
               (expect (funcall accessor s) :to-be-falsy)))

(describe "terminal-suite/direct-modes-suite"

  (it "mouse-reporting-modes-are-silently-ignored"
    (with-screen (s 20 5)
      (feed s "hello")
      (dolist (mode '(1000 1002 1003 1006))
        (finishes (feed s (esc "[?~Dh" mode)))
        (finishes (feed s (esc "[?~Dl" mode))))
      (check-row s 0 "hello")))

  (it "dec-pm-boolean-toggle-table"
    (dolist (row (list (list 1    #'nerimux/terminal/types:screen-app-cursor-keys)
                       (list 1004 #'nerimux/terminal/types:screen-focus-events)
                       (list 2004 #'nerimux/terminal/types:screen-bracketed-paste)))
      (destructuring-bind (mode accessor) row
        (test-dec-pm-toggle-boolean mode accessor))))

  (it "focus-event-report-bytes"
    (with-screen (s 20 5)
      (expect (nerimux/terminal/actions:focus-event-report s t) :to-be-falsy)
      (expect (nerimux/terminal/actions:focus-event-report s nil) :to-be-falsy)
      (feed s (esc "[?1004h"))
      (expect (string= (format nil "~C[I" #\Escape)
                       (nerimux/terminal/actions:focus-event-report s t)))
      (expect (string= (format nil "~C[O" #\Escape)
                       (nerimux/terminal/actions:focus-event-report s nil)))))



  (it "autowrap-default-is-on"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-autowrap s))))

  (it "autowrap-disable-toggle"
    (with-screen (s 10 5)
      (feed s (esc "[?7l"))
      (expect (nerimux/terminal/types:screen-autowrap s) :to-be-falsy)
      (feed s (esc "[?7h"))
      (expect (nerimux/terminal/types:screen-autowrap s))))


  (it "reset-sgr-pen-clears-all-slots"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-cur-fg       s) 3
            (nerimux/terminal/types:screen-cur-bg       s) 5
            (nerimux/terminal/types:screen-cur-attrs    s) #xFF
            (nerimux/terminal/types:screen-cur-attrs2   s) #xFF
            (nerimux/terminal/types:screen-cur-ul-color s) 42)
      (nerimux/terminal/types:reset-sgr-pen s)
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-fg s)))
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-bg s)))
      (expect (= 0 (nerimux/terminal/types:screen-cur-attrs s)))
      (expect (= 0 (nerimux/terminal/types:screen-cur-attrs2 s)))
      (expect (= 0 (nerimux/terminal/types:screen-cur-ul-color s))))))

(describe "terminal-suite/display-cell-suite"

  (it "display-cell-live-grid-when-no-copy-mode"
    (with-screen (s 5 3)
      (feed s "abcde")
      (expect (char= #\a (cell-char (nerimux/terminal/actions:screen-display-cell s 0 0))))
      (expect (char= #\e (cell-char (nerimux/terminal/actions:screen-display-cell s 4 0))))))

  (it "display-cell-returns-blank-for-out-of-range-row"
    (with-screen (s 5 3)
      (feed s "hello")
      (let ((cell (nerimux/terminal/actions:screen-display-cell s 0 99)))
        (expect (char= #\Space (cell-char cell))))))

  (it "display-cell-scrollback-when-copy-mode-offset"
    (with-screen (s 5 3)
      (feed s (format nil "AAAAA~C~CBBBBB~C~CCCCCC" #\Return #\Linefeed
                                                     #\Return #\Linefeed))
      (let ((sb-len (length (nerimux/terminal/types:screen-scrollback s))))
        (when (> sb-len 0)
          (setf (nerimux/terminal/types:screen-copy-mode-p s) t
                (nerimux/terminal/types:screen-copy-offset s) 1)
          (let ((cell (nerimux/terminal/actions:screen-display-cell s 0 0)))
            (expect (characterp (cell-char cell))))))))

  (it "display-cell-copy-mode-blank-for-empty-scrollback-entry"
    (with-screen (s 5 3)
      (setf (nerimux/terminal/types:screen-scrollback s) (list (vector))
            (nerimux/terminal/types:screen-copy-mode-p s) t
            (nerimux/terminal/types:screen-copy-offset s) 1)
      (let ((cell (nerimux/terminal/actions:screen-display-cell s 0 0)))
        (expect (char= #\Space (cell-char cell)))))))
