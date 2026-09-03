(in-package #:nerimux/test/terminal)

(describe "terminal-suite/parser-fuzz"

  (it-fuzz "screen-process-bytes never signals an error on an arbitrary byte stream"
      ((bytes (gen-vector (gen-integer :min 0 :max 255) :min-length 0 :max-length 128)))
      (:trials 300 :timeout-per-trial 2)
    (with-screen (s 20 5)
      (screen-process-bytes
       s (coerce bytes '(simple-array (unsigned-byte 8) (*))))))

  (it-fuzz "screen-process-bytes never signals an error on an ESC-prefixed byte stream"
      ((bytes (gen-vector (gen-integer :min 0 :max 255) :min-length 1 :max-length 64)))
      (:trials 300 :timeout-per-trial 2)
    (with-screen (s 20 5)
      (screen-process-bytes
       s (concatenate '(simple-array (unsigned-byte 8) (*))
                       (vector (char-code #\Escape))
                       bytes)))))
