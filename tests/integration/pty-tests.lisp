(in-package #:nerimux/test)

(describe "pty-suite"

  (it "pty-close-ignores-non-positive-pid"
    (finishes (nerimux/pty:pty-close -1 -1))
    (finishes (nerimux/pty:pty-close -1 0)))

  (it "terminal-size-returns-sane-clamped-geometry"
    (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
      (expect (<= 1 rows nerimux/pty::+max-sane-rows+))
      (expect (<= 1 cols nerimux/pty::+max-sane-cols+))))

  (it "terminal-size-fallback-values-are-sane"
    (expect (<= 1 24 nerimux/pty::+max-sane-rows+))
    (expect (<= 1 80 nerimux/pty::+max-sane-cols+)))

  (it "max-sane-bounds-are-reasonable"
    (expect (>= nerimux/pty::+max-sane-rows+ 24))
    (expect (>= nerimux/pty::+max-sane-cols+ 80)))

  (it "terminal-size-returns-rows-first"
    (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
      (expect (integerp rows))
      (expect (integerp cols))
      (expect (<= 1 rows nerimux/pty::+max-sane-rows+))
      (expect (<= 1 cols nerimux/pty::+max-sane-cols+))))

  (it "select-fds-empty-list-returns-nil"
    (expect (null (nerimux/pty:select-fds '() 0)))
    (expect (null (nerimux/pty:select-fds '() 100000)))
    (expect (null (nerimux/pty:select-fds '() -1))))

  (it "pty-write-rejects-bad-type"
    (signals error (nerimux/pty:pty-write -1 42))
    (signals error (nerimux/pty:pty-write -1 '(1 2 3))))

  (it "pty-write-empty-is-noop"
    (let ((empty (make-array 0 :element-type '(unsigned-byte 8))))
      (finishes (nerimux/pty:pty-write -1 empty))))

  (it "pty-write-negative-fd-is-noop"
    (let ((bytes (make-array 3 :element-type '(unsigned-byte 8)
                               :initial-contents '(1 2 3))))
      (finishes (nerimux/pty:pty-write -1 bytes))))


  (it "pty-write-pty-read-octet-round-trip"
    (with-pipe-fds (rfd wfd)
      (let ((original (make-array 5 :element-type '(unsigned-byte 8)
                                    :initial-contents '(0 1 127 128 255))))
        (nerimux/pty:pty-write wfd original)
        (let ((recovered (nerimux/pty:pty-read-blocking-into rfd (make-array 4096 :element-type '(unsigned-byte 8)))))
          (expect (equalp original recovered))
          (expect (typep recovered '(simple-array (unsigned-byte 8) (*))))))))

  (it "select-fds-returns-list-type"
    (let ((result (nerimux/pty:select-fds '() 0)))
      (expect (listp result))))

  (it "select-fds-with-pipe-data-returns-ready-fd"
    (with-pipe-fds (rfd wfd)
      (write-byte-to-fd wfd 99)
      (let ((ready (nerimux/pty:select-fds (list rfd) 200000)))
        (expect (equal (list rfd) ready)))))

  (it "select-fds-zero-timeout-is-non-blocking"
    (with-pipe-fds (rfd _wfd)
      (let ((ready (nerimux/pty:select-fds (list rfd) 0)))
        (expect (null ready)))))

  (it "pty-close-positive-pid-negative-fd-is-noop"
    (finishes (nerimux/pty:pty-close -1 99999999)
              "pty-close with negative fd and unknown pid must not signal"))


  (it "terminal-size-returns-rows-then-cols-not-transposed"
    (multiple-value-bind (rows cols) (nerimux/pty:terminal-size)
      (multiple-value-bind (kit-cols kit-rows) (cl-tty-kit:terminal-size 1)
        (if (and (integerp kit-rows) (integerp kit-cols)
                 (<= 1 kit-rows nerimux/pty::+max-sane-rows+)
                 (<= 1 kit-cols nerimux/pty::+max-sane-cols+))
            (progn
              (expect (= rows kit-rows))
              (expect (= cols kit-cols)))
            (progn
              (expect (= rows nerimux/pty:+default-term-rows+))
              (expect (= cols nerimux/pty:+default-term-cols+))))))))
