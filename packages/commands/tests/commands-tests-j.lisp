(in-package #:nerimux/test/commands)

(describe "commands-suite"


  (it "copy-mode-search-backward-saves-term"
    (let ((s (make-screen 30 5)))
      (feed s "foo bar foo")
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 11))
      (nerimux/commands::copy-mode-search-backward s "foo")
      (expect (string= "foo" (nerimux/terminal/types:screen-copy-search-term s)))))


  (it "copy-mode-search-prev-repeats-backward"
    (let ((s (make-screen 30 5)))
      (feed s "abc")
      (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "abc def")
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 0))
      (nerimux/commands::copy-mode-search-forward s "abc")
      (expect (= 1 (car (nerimux/terminal/types:screen-copy-cursor s))))
      (nerimux/commands::copy-mode-search-prev s)
      (expect (= 0 (car (nerimux/terminal/types:screen-copy-cursor s))))))

  (it "copy-mode-search-next-honors-backward-direction"
    (let ((s (make-screen 30 5)))
      (feed s "abc")
      (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "abc")
      (feed s (format nil "~C~C" #\Return #\Linefeed))
      (feed s "abc")
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 2 0))
      (nerimux/commands::copy-mode-search-backward s "abc")
      (expect (= 1 (car (nerimux/terminal/types:screen-copy-cursor s))))
      (expect (eq :backward (nerimux/terminal/types:screen-copy-search-direction s)))
      (nerimux/commands::copy-mode-search-next s)
      (expect (= 0 (car (nerimux/terminal/types:screen-copy-cursor s))))
      (expect (eq :backward (nerimux/terminal/types:screen-copy-search-direction s)))
      (nerimux/commands::copy-mode-search-prev s)
      (expect (= 1 (car (nerimux/terminal/types:screen-copy-cursor s))))))


  (it "scroll-up-one-line-moves-cursor-up-within-viewport"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 3 2))
      (nerimux/commands::%scroll-up-one-line s 3 2 0)
      (expect (equal (cons 2 2) (nerimux/terminal/types:screen-copy-cursor s)))))

  (it "scroll-up-one-line-scrolls-viewport-at-top-edge"
    (let ((s (%screen-with-scrollback 5)))
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 2))
      (let ((before-offset (screen-copy-offset s)))
        (nerimux/commands::%scroll-up-one-line s 0 2 5)
        (expect (= (1+ before-offset) (screen-copy-offset s)))
        (expect (= 0 (car (nerimux/terminal/types:screen-copy-cursor s)))))))

  (it "scroll-up-one-line-noop-at-oldest-scrollback"
    (let ((s (%screen-with-scrollback 3)))
      (setf (nerimux/terminal/types:screen-copy-offset s) 3)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 2))
      (nerimux/commands::%scroll-up-one-line s 0 2 3)
      (expect (= 3 (screen-copy-offset s)))
      (expect (= 0 (car (nerimux/terminal/types:screen-copy-cursor s))))))


  (it "scroll-down-one-line-moves-cursor-down-within-viewport"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 1 2))
      (nerimux/commands::%scroll-down-one-line s 1 2 5)
      (expect (equal (cons 2 2) (nerimux/terminal/types:screen-copy-cursor s)))))

  (it "scroll-down-one-line-scrolls-viewport-at-bottom-edge"
    (let ((s (%screen-with-scrollback 10)))
      (setf (nerimux/terminal/types:screen-copy-offset s) 5)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 4 2))
      (nerimux/commands::%scroll-down-one-line s 4 2 5)
      (expect (= 4 (screen-copy-offset s)))
      (expect (= 4 (car (nerimux/terminal/types:screen-copy-cursor s))))))

  (it "scroll-down-one-line-noop-at-live-view-bottom"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 4 2))
      (nerimux/commands::%scroll-down-one-line s 4 2 5)
      (expect (= 0 (screen-copy-offset s)))
      (expect (= 4 (car (nerimux/terminal/types:screen-copy-cursor s))))))
  )
