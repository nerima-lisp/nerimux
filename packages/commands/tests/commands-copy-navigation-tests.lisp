(in-package #:nerimux/test/commands)

(describe "commands-suite"


  (it "copy-mode-search-next-and-prev-noop-outside-copy-mode-table"
    (dolist (fn '(nerimux/commands::copy-mode-search-next
                  nerimux/commands::copy-mode-search-prev))
      (let ((s (make-screen 20 5)))
        (setf (screen-copy-mode-p s) nil
              (screen-copy-cursor  s) (cons 0 3)
              (nerimux/terminal/types:screen-copy-search-term s) "abc")
        (funcall fn s)
        (expect (equal (cons 0 3) (screen-copy-cursor s))))))


  (it "copy-mode-search-forward-and-backward-noop-outside-copy-mode-table"
    (dolist (fn '(nerimux/commands::copy-mode-search-forward
                  nerimux/commands::copy-mode-search-backward))
      (let ((s (make-screen 20 5)))
        (feed s "abc")
        (setf (screen-copy-mode-p s) nil
              (screen-copy-cursor  s) (cons 0 0))
        (funcall fn s "abc")
        (expect (equal (cons 0 0) (screen-copy-cursor s)))
        (expect (null (nerimux/terminal/types:screen-copy-search-term s))))))

  (it "copy-mode-search-forward-and-backward-noop-on-empty-term-table"
    (dolist (fn '(nerimux/commands::copy-mode-search-forward
                  nerimux/commands::copy-mode-search-backward))
      (let ((s (make-screen 20 5)))
        (feed s "abc")
        (nerimux/commands::copy-mode-enter s)
        (setf (screen-copy-cursor s) (cons 0 0))
        (funcall fn s "")
        (expect (equal (cons 0 0) (screen-copy-cursor s)))
        (expect (null (nerimux/terminal/types:screen-copy-search-term s)))))))
