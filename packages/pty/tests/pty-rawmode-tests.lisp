(in-package #:nerimux/test/pty)

(describe "pty-rawmode-suite"


  (it "enable-raw-mode-is-fbound"
    (expect (fboundp 'nerimux/pty:enable-raw-mode!)))

  (it "disable-raw-mode-is-fbound"
    (expect (fboundp 'nerimux/pty:disable-raw-mode!)))

  (it "old-raw-mode-internals-removed"
    (expect (null (macro-function
                   (or (find-symbol "WITH-RAW-TERMIOS-FLAGS" '#:nerimux/pty)
                       (gensym)))))
    (expect (not (boundp (or (find-symbol "*SAVED-TERMIOS-TABLE*" '#:nerimux/pty)
                             (gensym))))))


  (it "enable-raw-mode-signals-on-non-tty"
    (with-pipe-fds (rfd wfd)
      (declare (ignorable wfd))
      (signals error (nerimux/pty:enable-raw-mode! rfd))))

  (it "enable-raw-mode-rejects-negative-fd"
    (signals error (nerimux/pty:enable-raw-mode! -1)))

  (it "disable-raw-mode-noop-when-not-enabled"
    (finishes (nerimux/pty:disable-raw-mode! 99)))

  (it "enable-then-disable-round-trips-on-tty"
    (let ((stdout-is-not-tty (string= ""
                                      (uiop:run-program '("sh" "-c"
                                                          "test -t 1 && printf tty")
                                                        :output :string
                                                        :error-output nil
                                                        :ignore-error-status t))))
      (if stdout-is-not-tty
        (skip "stdout is not a tty in this environment")
        (unwind-protect
             (progn
               (nerimux/pty:enable-raw-mode! 1)
               (finishes (nerimux/pty:disable-raw-mode! 1)))
          (ignore-errors (nerimux/pty:disable-raw-mode! 1)))))))
