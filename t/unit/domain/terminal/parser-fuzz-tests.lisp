(in-package #:nerimux/test)

;;;; Fuzz coverage for the CPS VT100 parser's single entry point,
;;;; screen-process-bytes (src/domain/terminal/emulator.lisp).
;;;;
;;;; A real PTY child process is not under this codebase's control: any byte
;;;; sequence it ever writes -- truncated UTF-8, malformed CSI/OSC/DCS
;;;; framing, ESC immediately followed by more ESC, raw C1 controls -- must
;;;; advance the parser's state machine without signaling an error. it-fuzz
;;;; is exactly this invariant: a trial passes by merely running to
;;;; completion, and any signaled error is minimized to the smallest
;;;; reproducing byte sequence.

(describe "terminal-suite/parser-fuzz"

  (it-fuzz "screen-process-bytes never signals an error on an arbitrary byte stream"
      ((bytes (gen-vector (gen-integer :min 0 :max 255) :min-length 0 :max-length 128)))
      (:trials 300 :timeout-per-trial 2)
    (with-screen (s 20 5)
      (screen-process-bytes
       s (coerce bytes '(simple-array (unsigned-byte 8) (*))))))

  ;; A stream that starts with ESC is far more likely to drive the parser
  ;; through its escape/CSI/OSC/DCS states than uniformly random bytes are,
  ;; since most of those states are only entered via #\Escape from ground
  ;; state -- this variant biases generation toward the state machine's
  ;; least-travelled corners.
  (it-fuzz "screen-process-bytes never signals an error on an ESC-prefixed byte stream"
      ((bytes (gen-vector (gen-integer :min 0 :max 255) :min-length 1 :max-length 64)))
      (:trials 300 :timeout-per-trial 2)
    (with-screen (s 20 5)
      (screen-process-bytes
       s (concatenate '(simple-array (unsigned-byte 8) (*))
                       (vector (char-code #\Escape))
                       bytes)))))
