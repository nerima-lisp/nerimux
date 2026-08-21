(in-package #:nerimux/test)

;;;; renderer tests — part F: parse-style-string, style-to-sgr,
;;;; status-left/right length enforcement, window-status-format,
;;;; window-status-separator.

(describe "renderer-suite"

  ;;; ── parse-style-string ───────────────────────────────────────────────────────

  ;; parse-style-string returns NIL for NIL and empty-string inputs.
  (it "parse-style-string-nil-inputs-table"
    (dolist (row '((nil "NIL input → nil")
                   (""  "empty-string input → nil")))
      (destructuring-bind (input desc) row
        (declare (ignore desc))
        (expect (null (nerimux/renderer:parse-style-string input))))))

  ;; parse-style-string sets :fg or :bg to the parsed colour name.
  (it "parse-style-string-color-key-table"
    (dolist (row '(("fg=red"     :fg "red"     "fg=red → :fg \"red\"")
                   ("bg=blue"    :bg "blue"     "bg=blue → :bg \"blue\"")
                   ("fg=colour4" :fg "colour4"  "fg=colour4 → :fg \"colour4\"")))
      (destructuring-bind (input key expected desc) row
        (declare (ignore desc))
        (let ((p (nerimux/renderer:parse-style-string input)))
          (expect (string= expected (getf p key)))))))

  ;; parse-style-string sets boolean attribute keys to T.
  (it "parse-style-string-bool-attr-table"
    (dolist (row '(("bold"    :bold    "bold → :bold T")
                   ("reverse" :reverse "reverse → :reverse T")))
      (destructuring-bind (input key desc) row
        (declare (ignore desc))
        (let ((p (nerimux/renderer:parse-style-string input)))
          (expect (getf p key))))))

  ;; parse-style-string parses fg=green,bold,underline into a combined plist.
  (it "parse-style-string-multiple-attrs"
    (let ((p (nerimux/renderer:parse-style-string "fg=green,bold,underline")))
      (expect (string= "green" (getf p :fg)))
      (expect (getf p :bold))
      (expect (getf p :underline))))

  ;;; ── style-to-sgr ────────────────────────────────────────────────────────────

  ;; style-to-sgr with NIL returns default blue-on-white SGR "44;97".
  (it "style-to-sgr-nil-returns-default"
    (expect (string= "44;97" (nerimux/renderer:style-to-sgr nil))))

  ;; style-to-sgr includes the correct SGR code substring for each attribute.
  (it "style-to-sgr-attrs-table"
    (dolist (row '(((:bold t)       "1"      ":bold T → SGR 1")
                   ((:reverse t)    "7"      ":reverse T → SGR 7")
                   ((:fg "red")     "31"     ":fg red → SGR 31")
                   ((:bg "blue")    "44"     ":bg blue → SGR 44")
                   ((:bg "colour4") "48;5;4" ":bg colour4 → SGR 48;5;4")))
      (destructuring-bind (style expected desc) row
        (declare (ignore desc))
        (let ((sgr (nerimux/renderer:style-to-sgr style)))
          (expect (search expected sgr))))))

  ;;; ── status-left-length / status-right-length enforcement ────────────────────

  ;; status-left-length truncates the expanded left string to the configured max.
  (it "status-left-length-truncates-long-left"
    (with-isolated-options ()
      (nerimux/options:set-option "status-left" "abcdefghij")
      (nerimux/options:set-option "status-left-length" 5)
      (let* ((sess (make-renderer-test-session 80 10))
             (out  (render-status-bar-output sess 11 80)))
        (expect (search "abcde" out))
        (expect (null (search "abcdefghij" out))))))

  ;; status-right-length truncates the expanded right string to the configured max.
  (it "status-right-length-truncates-long-right"
    (with-isolated-options ()
      (nerimux/options:set-option "status-right" "1234567890")
      (nerimux/options:set-option "status-right-length" 4)
      (let* ((sess (make-renderer-test-session 80 10))
             (out  (render-status-bar-output sess 11 80)))
        (expect (search "1234" out))
        (expect (null (search "1234567890" out))))))

  ;;; ── window-status-format and window-status-current-format ───────────────────

  ;; window-status-format option is used when rendering inactive windows.
  (it "window-status-format-custom"
    (with-empty-status-bar-options ("window-status-format" "WIN:#{window_name}"
                                    "window-status-current-format" "[#{window_name}]")
      ;; make-two-window-session creates windows named "alpha" (active) and "beta".
      (multiple-value-bind (sess win0 _p0 _w1 _p1)
          (make-two-window-session 80 5)
        (declare (ignore _p0 _w1 _p1))
        (session-select-window sess win0)  ; alpha is active
        (let ((out (render-status-bar-output sess 11 80)))
          (expect (search "[alpha]" out))
          (expect (search "WIN:beta" out))))))

  ;;; ── window-status-separator ──────────────────────────────────────────────────

  ;; window-status-separator is placed between window entries.
  (it "window-status-separator-used-between-windows"
    (with-empty-status-bar-options ("window-status-separator" "|SEP|")
      (multiple-value-bind (sess win0 _p0 _w1 _p1)
          (make-two-window-session 80 5)
        (declare (ignore _p0 _w1 _p1))
        (session-select-window sess win0)
        (let ((out (render-status-bar-output sess 11 80)))
          (expect (search "|SEP|" out)))))))
