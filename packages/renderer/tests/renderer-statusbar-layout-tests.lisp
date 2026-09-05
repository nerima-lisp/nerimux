(in-package #:nerimux/test/renderer)

(describe "renderer-suite/statusbar-layout"


  (it "sgr-sequence-end-finds-final-byte"
    (let ((s (format nil "~C[1;32mtext" #\Escape)))
      (expect (= 7 (nerimux/renderer::%sgr-sequence-end s 0)))))

  (it "sgr-sequence-end-returns-nil-for-plain-text"
    (expect (null (nerimux/renderer::%sgr-sequence-end "plain text" 0))))

  (it "sgr-sequence-end-returns-nil-for-trailing-esc"
    (expect (null (nerimux/renderer::%sgr-sequence-end (string #\Escape) 0))))

  (it "sgr-sequence-end-unterminated-consumes-rest"
    (let ((s (format nil "~C[1;32" #\Escape)))
      (expect (= (length s) (nerimux/renderer::%sgr-sequence-end s 0)))))


  (it "split-comma-attrs-preserves-empty-fields"
    (expect (equal '("a" "" "b") (nerimux/renderer::%split-comma-attrs "a,,b"))))

  (it "split-comma-attrs-single-element"
    (expect (equal '("fg=red") (nerimux/renderer::%split-comma-attrs "fg=red"))))

  (it "split-comma-attrs-empty-string"
    (expect (equal '("") (nerimux/renderer::%split-comma-attrs ""))))

  (it "split-comma-attrs-trailing-comma"
    (expect (equal '("a" "b" "") (nerimux/renderer::%split-comma-attrs "a,b,"))))


  (it "status-align-step-copies-plain-char"
    (let ((buckets (list :left (make-string-output-stream)
                          :centre (make-string-output-stream)
                          :right (make-string-output-stream))))
      (multiple-value-bind (next-i next-current)
          (nerimux/renderer::%status-align-step "abc" 0 buckets :left)
        (expect (= 1 next-i))
        (expect (eq :left next-current))
        (expect (string= "a" (get-output-stream-string (getf buckets :left)))))))

  (it "status-align-step-dispatches-on-align-marker"
    (let ((buckets (list :left (make-string-output-stream)
                          :centre (make-string-output-stream)
                          :right (make-string-output-stream))))
      (multiple-value-bind (next-i next-current)
          (nerimux/renderer::%status-align-step "#[align=right]" 0 buckets :left)
        (expect (= 14 next-i))
        (expect (eq :right next-current)))))

  (it "status-align-block-step-switches-bucket-on-align-only"
    (let ((buckets (list :left (make-string-output-stream)
                          :centre (make-string-output-stream)
                          :right (make-string-output-stream))))
      (multiple-value-bind (next-i next-current)
          (nerimux/renderer::%status-align-block-step "#[align=centre]" 0 buckets :left)
        (expect (= 15 next-i))
        (expect (eq :centre next-current))
        (expect (string= "" (get-output-stream-string (getf buckets :centre)))))))

  (it "status-align-block-step-preserves-combined-attrs"
    (let ((buckets (list :left (make-string-output-stream)
                          :centre (make-string-output-stream)
                          :right (make-string-output-stream))))
      (nerimux/renderer::%status-align-block-step "#[align=right,fg=red]" 0 buckets :left)
      (expect (string= "#[fg=red]" (get-output-stream-string (getf buckets :right))))))

  (it "status-align-block-step-copies-non-align-block-verbatim"
    (let ((buckets (list :left (make-string-output-stream)
                          :centre (make-string-output-stream)
                          :right (make-string-output-stream))))
      (multiple-value-bind (next-i next-current)
          (nerimux/renderer::%status-align-block-step "#[fg=green]" 0 buckets :left)
        (expect (= 11 next-i))
        (expect (eq :left next-current))
        (expect (string= "#[fg=green]" (get-output-stream-string (getf buckets :left)))))))

  (it "status-align-block-step-unterminated-marker"
    (let ((buckets (list :left (make-string-output-stream)
                          :centre (make-string-output-stream)
                          :right (make-string-output-stream))))
      (multiple-value-bind (next-i next-current)
          (nerimux/renderer::%status-align-block-step "#[unterminated" 0 buckets :left)
        (expect (= 1 next-i))
        (expect (eq :left next-current))
        (expect (string= "#" (get-output-stream-string (getf buckets :left)))))))


  (it "status-pad-to-pads-and-returns-new-column"
    (let ((out (make-string-output-stream)))
      (expect (= 5 (nerimux/renderer::%status-pad-to out 2 5)))
      (expect (string= "   " (get-output-stream-string out)))))

  (it "status-pad-to-noop-when-already-at-target"
    (let ((out (make-string-output-stream)))
      (expect (= 5 (nerimux/renderer::%status-pad-to out 5 5)))
      (expect (= 6 (nerimux/renderer::%status-pad-to out 6 5)))
      (expect (string= "" (get-output-stream-string out)))))


  (it "status-emit-segment-pads-then-writes"
    (let ((out (make-string-output-stream)))
      (expect (= 8 (nerimux/renderer::%status-emit-segment out 0 80 "abc" 3 5)))
      (expect (string= "     abc" (get-output-stream-string out)))))

  (it "status-emit-segment-noop-for-zero-width"
    (let ((out (make-string-output-stream)))
      (expect (= 3 (nerimux/renderer::%status-emit-segment out 3 80 "" 0 5)))
      (expect (string= "" (get-output-stream-string out)))))

  (it "status-emit-segment-skips-when-past-cols"
    (let ((out (make-string-output-stream)))
      (nerimux/renderer::%status-emit-segment out 80 80 "xyz" 3 80)
      (expect (string= "" (get-output-stream-string out)))))


  (it "expand-segment-or-empty-returns-empty-for-empty-raw"
    (expect (string= "" (nerimux/renderer::%expand-segment-or-empty "" "44;97" "reset"))))

  (it "expand-segment-or-empty-expands-and-appends-reset"
    (let ((result (nerimux/renderer::%expand-segment-or-empty "plain" "44;97" "RESET-MARKER")))
      (expect (string= "plainRESET-MARKER" result))))

  (it "expand-segment-or-empty-with-style-block-appends-reset"
    (let ((result (nerimux/renderer::%expand-segment-or-empty "#[fg=red]x" "44;97" "RESET-MARKER")))
      (expect (search "RESET-MARKER" result))
      (expect (char= #\x (char result (1- (- (length result) (length "RESET-MARKER"))))))))
  )
