(in-package #:nerimux/test)

;;;; renderer tests — part F: window-status-separator.
;;;;
;;;; R2.4 deleted parse-style-string/style-to-sgr along with the option
;;;; system they existed to read (renderer-style.lisp/renderer-style-data.lisp
;;;; now hold fixed SGR constants instead).  R2.2 deleted status-left-length/
;;;; status-right-length (status-left/status-right segments are still clamped,
;;;; but to the fixed 40-cell default — see renderer-tests-e.lisp's
;;;; clamp-status-segment-table) and window-status-format/window-status-
;;;; current-format (the window-tab text is now composed directly instead of
;;;; expanded from a template — see renderer-window-list-tests.lisp).
;;;; window-status-separator survives as the fixed constant
;;;; +window-status-separator+ (a single space) — see renderer-statusbar.lisp.

(describe "renderer-suite"

  ;; window-status-separator's fixed value is a single space.
  (it "window-status-separator-is-a-single-space"
    (expect (string= " " nerimux/renderer::+window-status-separator+)))

  ;; The separator sits right after the active tab's trailing SGR reset and
  ;; before the next tab's own leading space, in the status bar's window list.
  (it "window-status-separator-used-between-windows"
    (multiple-value-bind (sess win0 _p0 _w1 _p1)
        (make-two-window-session 80 5)
      (declare (ignore _p0 _w1 _p1))
      (session-select-window sess win0)
      (let* ((out      (nerimux/renderer::%status-window-list-styled
                        sess (session-active-window sess)))
             (expected (concatenate 'string
                                    (format nil "~C[0m" #\Escape)
                                    nerimux/renderer::+window-status-separator+
                                    " 2:beta")))
        (expect (search expected out))))))
