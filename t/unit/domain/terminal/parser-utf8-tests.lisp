(in-package #:cl-tmux/test)

;;;; Parser tests (src/terminal/parser.lisp).
;;;; UTF-8 coverage.

;;; ── SUITE: utf8 ─────────────────────────────────────────────────────────────

(describe "terminal-suite/utf8"

  ;; Multi-byte UTF-8 characters decode and appear at the correct screen position.
  (it "utf8-multibyte-table"
    (dolist (row '((#\é "2-byte: U+00E9 é")
                   (#\あ "3-byte: U+3042 あ")))
      (destructuring-bind (char desc) row
        (declare (ignore desc))
        (with-screen (s 10 2)
          (utf8-feed s (string char))
          (expect (char= char (char-at s 0 0)))))))

  ;; A 4-byte UTF-8 code point is decoded correctly (e.g. U+1F600 if in limit).
  (it "utf8-4byte"
    ;; U+1F600 = 😀; only test if the Lisp runtime supports it.
    (when (< #x1F600 char-code-limit)
      (with-screen (s 10 2)
        ;; Feed the 4-byte UTF-8 sequence for U+1F600: F0 9F 98 80
        (screen-process-bytes s (make-array 4 :element-type '(unsigned-byte 8)
                                              :initial-contents '(#xF0 #x9F #x98 #x80)))
        (expect (char= (code-char #x1F600) (char-at s 0 0))))))

  ;; U+3042 split across two feed calls (E3 | 81 82) assembles correctly.
  (it "utf8-split"
    (with-screen (s 10 2)
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#xE3)))
      (screen-process-bytes s (make-array 2 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#x81 #x82)))
      (expect (char= #\あ (char-at s 0 0)))))

  ;; ASCII + wide CJK + ASCII: the CJK char occupies two columns, so the
  ;; trailing ASCII lands at column 3 (column 2 is the continuation cell).
  (it "utf8-mixed"
    (with-screen (s 10 2)
      (utf8-feed s "aあb")
      (expect (char= #\a  (char-at s 0 0)))
      (expect (char= #\あ (char-at s 1 0)))
      (expect (= 2 (cell-width (cell-at s 1 0))))
      (expect (= 0 (cell-width (cell-at s 2 0))))
      (expect (char= #\b  (char-at s 3 0)))))

  ;; Box-drawing characters are decoded and placed correctly.
  (it "utf8-box-drawing"
    (with-screen (s 10 2)
      (utf8-feed s "│─")
      (expect (char= #\│ (char-at s 0 0)))
      (expect (char= #\─ (char-at s 1 0)))))

  ;; A bare #xFF byte (invalid UTF-8) produces U+FFFD at the cursor.
  (it "utf8-malformed"
    (with-screen (s 10 2)
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#xFF)))
      (expect (char= (code-char #xFFFD) (char-at s 0 0)))))

  ;;; ── CESU-8 lone surrogate ──────────────────────────────────────────────────
  ;;;
  ;;; ED A0 80 is the CESU-8 encoding of U+D800, a lone high surrogate. It is
  ;;; NOT well-formed UTF-8, but this parser's structure accepts it: utf8-lead-p
  ;;; admits #xED, utf8-lead-decode asks for two continuation bytes, and both
  ;;; A0 and 80 are valid continuation bytes, so the accumulator reaches #xD800
  ;;; and is handed to write-codepoint. Any child process can emit these three
  ;;; bytes, so this is reachable from untrusted input.
  ;;;
  ;;; The cell must hold U+FFFD, not #\UD800. A surrogate stored here would be
  ;;; UTF-8 encoded later on the frame-broadcast path, where SBCL's encoder
  ;;; signals (babel silently emitted CESU-8 instead, which is why this only
  ;;; became load-bearing when the codec moved to cl-host-kit).

  ;; A CESU-8 lone surrogate decodes to U+FFFD, not to an unencodable character.
  (it "utf8-cesu8-lone-surrogate-becomes-replacement"
    (with-screen (s 10 2)
      (screen-process-bytes s (make-array 3 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#xED #xA0 #x80)))
      (let ((written (char-at s 0 0)))
        (expect (char= (code-char #xFFFD) written))
        ;; The real invariant: whatever landed in the cell survives encoding.
        (expect (cl-codec-kit:string-to-octets (string written) :encoding :utf-8)
                :to-be-truthy))))

  ;; The low end of the surrogate block (U+DFFF, bytes ED BF BF) is handled the
  ;; same way -- the guard is a range, not a single value.
  (it "utf8-cesu8-low-surrogate-becomes-replacement"
    (with-screen (s 10 2)
      (screen-process-bytes s (make-array 3 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#xED #xBF #xBF)))
      (expect (char= (code-char #xFFFD) (char-at s 0 0))))))
