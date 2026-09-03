(in-package #:nerimux/test/commands)

(defun %make-test-pane (&key (id 1) (x 0) (y 0) (w 20) (h 5))
  "Return a no-PTY pane with a fresh screen of W x H."
  (make-pane :id
             id
             :x
             x
             :y
             y
             :width
             w
             :height
             h
             :fd
             -1
             :pid
             -1
             :screen
             (make-screen w h)))

(defun %screen-with-scrollback (n)
  "A copy-mode screen carrying N scrollback rows (contents irrelevant)."
  (let ((s (make-screen 20 5)))
    (setf (screen-scrollback s) (loop repeat n
                                      collect (make-array 0)))
    (nerimux/commands::copy-mode-enter s)
    s))

(describe "commands-suite"


  (it "copy-mode-scroll-back-clamps-to-scrollback-length"
    (let ((s (%screen-with-scrollback 3)))
      (nerimux/commands::copy-mode-scroll s 100)
      (expect (= 3 (screen-copy-offset s)))
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-truthy)))

  (it "copy-mode-scroll-forward-clamps-at-zero"
    (let ((s (%screen-with-scrollback 3)))
      (nerimux/commands::copy-mode-scroll s 100)   ; first jump to the oldest line
      (expect (= 3 (screen-copy-offset s)))
      (nerimux/commands::copy-mode-scroll s -100)  ; then race back to live
      (expect (= 0 (screen-copy-offset s)))))

  (it "copy-mode-selection-honours-scroll-offset"
    (let ((s (make-screen 8 3)))
      (feed-lines s "AAA" "BBB" "CCC" "DDD" "EEE")
      (nerimux/commands::copy-mode-enter s)
      (nerimux/commands::copy-mode-scroll s 1000)   ; scroll fully back
      (expect (plusp (screen-copy-offset s)))
      (let ((w      (screen-width s))
            (offset (screen-copy-offset s)))
        (let ((expected (string-right-trim " " (display-row-string s 0))))
          (setf (screen-copy-mark        s) (cons 0 0)
                (screen-copy-mark-offset s) offset
                (screen-copy-cursor      s) (cons 0 w)
                (screen-copy-selecting   s) t)
          (expect (string= expected
                           (string-right-trim " " (or (nerimux/commands::%selection-text s) ""))))))))

  (it "copy-mode-enter-e-sets-exit-on-bottom"
    (let ((s (make-screen 20 5)))
      (nerimux/commands::copy-mode-enter s :exit-on-bottom t)
      (expect (nerimux/terminal/types:screen-copy-exit-on-bottom s) :to-be-truthy)))

  (it "copy-mode-e-auto-exits-on-scroll-to-bottom"
    (let ((s (%screen-with-scrollback 3)))
      (nerimux/commands::copy-mode-enter s :exit-on-bottom t)
      (nerimux/commands::copy-mode-scroll s 2)        ; scroll back 2 lines (offset 2)
      (expect (= 2 (screen-copy-offset s)))
      (expect (screen-copy-mode-p s) :to-be-truthy)
      (nerimux/commands::copy-mode-scroll s -100)     ; race back to the live bottom
      (expect (screen-copy-mode-p s) :to-be-falsy)))

  (it "copy-mode-e-no-exit-while-scrolling-up"
    (let ((s (%screen-with-scrollback 3)))
      (nerimux/commands::copy-mode-enter s :exit-on-bottom t)
      (nerimux/commands::copy-mode-scroll s 100)      ; scroll up to oldest
      (expect (screen-copy-mode-p s) :to-be-truthy)))

  (it "copy-mode-scroll-noop-when-not-in-copy-mode"
    (let ((s (make-screen 20 5)))
      (setf (screen-scrollback s) (list (make-array 0) (make-array 0)))
      (expect (screen-copy-mode-p s) :to-be-falsy)
      (expect (null (nerimux/commands::copy-mode-scroll s 100)))
      (expect (= 0 (screen-copy-offset s)))))

  )
