(in-package #:nerimux/test)

;;;; Runtime prompt history persistence and stream parsing

(describe "runtime-suite"

  ;; add-prompt-history saves to history-file and load-prompt-history restores it
  ;; (newest first).
  (it "prompt-history-persists-to-history-file"
    (with-fresh-options
      (let ((path (format nil "~A/nerimux-hist-~D.txt"
                          (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                          (get-universal-time))))
        (unwind-protect
             (progn
               (let ((nerimux::*prompt-history* (history-kit:make-history)))
                 (nerimux/options:set-option "history-file" path)
                 (nerimux::add-prompt-history "first")
                 (nerimux::add-prompt-history "second"))
               ;; Fresh in-memory history; loading from the file restores both.
               (let ((nerimux::*prompt-history* (history-kit:make-history)))
                 (nerimux::load-prompt-history)
                 (expect (equal '("second" "first") (%prompt-history-texts)))))
          (ignore-errors (delete-file path))))))

  ;; With history-file unset (default ""), history stays in memory and add does not error.
  (it "prompt-history-no-file-is-in-memory-only"
    (with-fresh-options
      (let ((nerimux::*prompt-history* (history-kit:make-history)))
        (expect (null (nerimux::%prompt-history-path)))
        (nerimux::add-prompt-history "x")
        (expect (equal '("x") (%prompt-history-texts))))))

  ;; save-prompt-history writes *prompt-history* (newest-first in memory) to the
  ;; history-file oldest-first, so a later load-prompt-history restores the
  ;; original newest-first order.
  (it "save-prompt-history-writes-oldest-first"
    (with-isolated-options ()
      (let ((path (format nil "~A/nerimux-save-hist-~D.txt"
                          (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                          (get-universal-time))))
        (unwind-protect
             (progn
               (nerimux/options:set-option "history-file" path)
               (let ((nerimux::*prompt-history* (%prompt-history-of "oldest" "middle" "newest")))
                 (nerimux::save-prompt-history))
               (with-open-file (s path :direction :input)
                 (expect (string= "oldest" (read-line s)))
                 (expect (string= "middle" (read-line s)))
                 (expect (string= "newest" (read-line s)))))
          (ignore-errors (delete-file path))))))

  ;; save-prompt-history is a no-op (does not error, does not create a file) when
  ;; history-file is unset.
  (it "save-prompt-history-no-op-when-history-file-unset"
    (with-isolated-options ("history-file" "")
      (let ((nerimux::*prompt-history* (%prompt-history-of "b" "a")))
        (finishes (nerimux::save-prompt-history)
                  "save-prompt-history must not error with history-file unset"))))

  ;; save-prompt-history ignores I/O errors (e.g., an unwritable directory) rather
  ;; than signalling.
  (it "save-prompt-history-swallows-io-errors"
    (with-isolated-options ("history-file" "/nonexistent-dir-xyz/hist.txt")
      (let ((nerimux::*prompt-history* (%prompt-history-of "a")))
        (finishes (nerimux::save-prompt-history)
                  "save-prompt-history must swallow I/O errors from an invalid path"))))

  ;; %read-history-lines reads non-empty lines from a stream, oldest first (file order).
  (it "read-history-lines-returns-lines-in-file-order"
    (let ((content (format nil "line1~%line2~%line3~%")))
      (with-input-from-string (stream content)
        (let ((result (nerimux::%read-history-lines stream)))
          (expect (equal '("line1" "line2" "line3") result))))))

  ;; %read-history-lines skips empty lines in the stream.
  (it "read-history-lines-skips-empty-lines"
    (let ((content (format nil "first~%~%second~%")))
      (with-input-from-string (stream content)
        (let ((result (nerimux::%read-history-lines stream)))
          (expect (= 2 (length result)))
          (expect (member "first" result :test #'string=))
          (expect (member "second" result :test #'string=))))))

  ;; %read-history-lines returns NIL when stream is empty.
  (it "read-history-lines-returns-nil-for-empty-stream"
    (with-input-from-string (stream "")
      (let ((result (nerimux::%read-history-lines stream)))
        (expect (null result))))))
