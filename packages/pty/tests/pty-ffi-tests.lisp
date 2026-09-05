(in-package #:nerimux/test/pty)

(describe "pty-ffi-suite"


  (it "stdout-fd-constant-is-1"
    (expect (= 1 nerimux/pty::+stdout-fd+)))


  (it "no-hand-rolled-foreign-symbols-remain"
    (dolist (name '("%SELECT" "%READ" "%WRITE"))
      (let ((sym (find-symbol name '#:nerimux/pty)))
        (expect (or (null sym) (not (fboundp sym))))))
    (dolist (name '("FD-ZERO!" "FD-SET!" "FD-ISSET-P" "+FD-SET-WORDS+"))
      (expect (null (find-symbol name '#:nerimux/pty)))))

  (it "ioctl-request-constants-moved-to-cl-tty-kit"
    (dolist (name '("+TIOCGWINSZ+" "+TIOCSWINSZ+"))
      (expect (null (find-symbol name '#:nerimux/pty))))))
