(in-package #:cl-tmux/test)

;;;; Platform constant tests (src/infrastructure/pty/pty-ffi.lisp).
;;;;
;;;; This suite used to be ~110 lines of fd_set bit-manipulation tests covering
;;;; cl-tmux's hand-rolled FD_ZERO/FD_SET/FD_ISSET over a foreign :uint32 array,
;;;; plus reachability checks on a cffi-declared %select and the TIOCGWINSZ /
;;;; TIOCSWINSZ request numbers. All of that was deleted, not merely retargeted:
;;;;
;;;;   * fd_set handling now lives in cl-process-kit, which owns its own tests
;;;;     (t/fd-readiness-test.lisp) AND rejects an fd >= FD_SETSIZE instead of
;;;;     writing past the end of the bitmap — the case the old fd-set! silently
;;;;     corrupted memory on and which no test here covered.
;;;;   * the ioctl request numbers now live in cl-tty-kit.
;;;;
;;;; Behaviour that used to be asserted through those internals is now asserted
;;;; through the public wrapper instead: select-fds in pty-tests.lisp, and the
;;;; ioctl request numbers by a set-and-read-back round trip on a NON-SQUARE
;;;; size, which lives in two places and in neither case here —
;;;; SET-PTY-SIZE-ROUND-TRIPS-NON-SQUARE-SIZE-ON-REAL-PTY in
;;;; t/unit/infrastructure/pty/pty-tests.lisp, and
;;;; SET-PTY-SIZE-APPLIES-NON-SQUARE-SIZE-WITHOUT-TRANSPOSITION in
;;;; t/integration/pty-tests.lisp.  (There has never been a test named
;;;; `set-pty-size-transposition`; this comment used to point at one.)

(describe "pty-ffi-suite"

  ;;; ── Platform constants ───────────────────────────────────────────────────

  ;; +stdout-fd+ is 1, the descriptor terminal-size queries.
  (it "stdout-fd-constant-is-1"
    (expect (= 1 cl-tmux/pty::+stdout-fd+)))

  ;;; ── Retired foreign surface ──────────────────────────────────────────────

  ;; cl-tmux declares no foreign functions at all any more: cffi is gone from
  ;; :depends-on, and every syscall goes through cl-tty-kit, cl-process-kit or
  ;; sb-posix. A reintroduced %select/%read/%write here would mean someone
  ;; re-added a private C surface instead of extending the sibling kit.
  (it "no-hand-rolled-foreign-symbols-remain"
    (dolist (name '("%SELECT" "%READ" "%WRITE"))
      (let ((sym (find-symbol name '#:cl-tmux/pty)))
        (expect (or (null sym) (not (fboundp sym))))))
    ;; The fd_set helpers moved to cl-process-kit wholesale.
    (dolist (name '("FD-ZERO!" "FD-SET!" "FD-ISSET-P" "+FD-SET-WORDS+"))
      (expect (null (find-symbol name '#:cl-tmux/pty)))))

  ;; The TIOC* request numbers belong to cl-tty-kit now. cl-tmux keeping its own
  ;; copy is how the two could drift on a platform where they differ.
  (it "ioctl-request-constants-moved-to-cl-tty-kit"
    (dolist (name '("+TIOCGWINSZ+" "+TIOCSWINSZ+"))
      (expect (null (find-symbol name '#:cl-tmux/pty))))))
