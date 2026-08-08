(in-package #:cl-tmux/test)

;;;; parser tests - OSC dispatch edge cases.

(describe "terminal-suite/osc-dispatch-edge-cases"

  ;; An OSC payload with no semicolon is silently discarded (no command to dispatch).
  (it "osc-payload-no-semicolon-is-noop"
    (with-screen (s 20 5)
      ;; Feed OSC with no semicolon: just the command number, BEL terminated.
      ;; This should not crash and must not set screen-title.
      (finishes
        (screen-process-bytes s
          (cl-codec-kit:string-to-octets
            (format nil "~C]notanumber~C" #\Escape (code-char 7))
            :encoding :utf-8)))
      ;; screen-title must remain at its default (NIL or empty string).
      (let ((title (cl-tmux/terminal/types:screen-title s)))
        (expect (or (null title) (string= "" title))))))

  ;; An OSC payload with a valid integer command but no matching rule is silently ignored.
  (it "osc-unknown-command-is-silently-ignored"
    (with-screen (s 20 5)
      ;; OSC 99 is not handled - must not crash.
      (finishes
        (screen-process-bytes s
          (cl-codec-kit:string-to-octets
            (format nil "~C]99;some-data~C" #\Escape (code-char 7))
            :encoding :utf-8)))
      ;; screen-title must remain unset (OSC 99 has no handler).
      (let ((title (cl-tmux/terminal/types:screen-title s)))
        (expect (or (null title) (string= "" title))))))

  ;; An OSC terminated immediately by BEL (empty payload) is consumed without error.
  (it "osc-empty-payload-bel-is-noop"
    (with-screen (s 20 5)
      (feed s "A")
      ;; ESC ] BEL - empty payload
      (screen-process-bytes s
        (make-array 3 :element-type '(unsigned-byte 8)
                      :initial-contents (list #x1B #x5D #x07)))
      (feed s "B")
      (expect (char= #\A (char-at s 0 0)))
      (expect (char= #\B (char-at s 1 0)))))

  ;; %dispatch-osc decodes untrusted payloads with :ERRORP NIL, and passes
  ;; :REPLACEMENT explicitly.  These two tests pin that choice.
  ;;
  ;; CL-CODEC-KIT's own default replacement is #\SUB (U+001A) — a C0 control
  ;; character, which is wrong for text that becomes a window title.  babel,
  ;; which this call site used before the codec migration, substituted U+FFFD
  ;; (its UTF-8 decoder hardcodes +REPL+ = #xFFFD).  U+FFFD is also what
  ;; SAFE-CODE-CHAR substitutes everywhere else in cl-tmux.  If someone drops
  ;; the explicit :REPLACEMENT and lets the default apply, these fail.
  (it "osc-malformed-utf8-payload-is-replaced-with-u+fffd-not-sub"
    (with-screen (s 20 5)
      ;; ESC ] 0 ; ED A0 80 BEL — a lone surrogate, which no well-formed
      ;; UTF-8 encoder produces and which must not signal out of the parser.
      (screen-process-bytes s
        (make-array 8 :element-type '(unsigned-byte 8)
                      :initial-contents (list #x1B #x5D #x30 #x3B
                                              #xED #xA0 #x80 #x07)))
      (let ((title (cl-tmux/terminal/types:screen-title s)))
        (expect (stringp title))
        (expect (plusp (length title)))
        ;; Every character of the decoded body is the replacement character.
        (expect (every (lambda (c) (char= c #\REPLACEMENT_CHARACTER)) title))
        ;; And specifically NOT cl-codec-kit's #\SUB default.
        (expect (notany (lambda (c) (= #x1A (char-code c))) title)))))

  (it "osc-malformed-utf8-keeps-surrounding-valid-text"
    (with-screen (s 20 5)
      ;; ESC ] 0 ; "A" ED A0 80 "B" BEL — valid text either side of the
      ;; malformed sequence survives, so decoding resumes rather than aborting.
      (screen-process-bytes s
        (make-array 10 :element-type '(unsigned-byte 8)
                       :initial-contents (list #x1B #x5D #x30 #x3B
                                               #x41 #xED #xA0 #x80 #x42 #x07)))
      (let ((title (cl-tmux/terminal/types:screen-title s)))
        (expect (stringp title))
        (expect (char= #\A (char title 0)))
        (expect (char= #\B (char title (1- (length title)))))
        (expect (find #\REPLACEMENT_CHARACTER title))
        (expect (notany (lambda (c) (= #x1A (char-code c))) title))))))
