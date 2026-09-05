(in-package #:nerimux/test/renderer)

(describe "renderer-suite/compose-effects"

  (it "render-passthrough-drains-without-emitting"
    (let* ((p (make-no-pty-pane 1 0 0 10 5))
           (s (nerimux/pane:pane-screen p)))
      (push (format nil "~C]1337;a" #\Escape)
            (nerimux/terminal/types:screen-passthrough-queue s))
      (let ((out (with-output-to-string (buf)
                   (nerimux/renderer::%render-passthrough buf (list p)))))
        (expect (string= "" out))
        (expect (null (nerimux/terminal/types:screen-passthrough-queue s))))))

  (it "render-passthrough-multiple-panes-all-drained"
    (let* ((p1 (make-no-pty-pane 1 0 0 10 5))
           (p2 (make-no-pty-pane 2 0 0 10 5))
           (s1 (nerimux/pane:pane-screen p1))
           (s2 (nerimux/pane:pane-screen p2)))
      (push "from-p1" (nerimux/terminal/types:screen-passthrough-queue s1))
      (push "from-p2" (nerimux/terminal/types:screen-passthrough-queue s2))
      (let ((out (with-output-to-string (buf)
                   (nerimux/renderer::%render-passthrough buf (list p1 p2)))))
        (expect (string= "" out))
        (expect (null (nerimux/terminal/types:screen-passthrough-queue s1)))
        (expect (null (nerimux/terminal/types:screen-passthrough-queue s2))))))

  (it "render-clipboard-emits-in-fifo-order"
    (let* ((p (make-no-pty-pane 1 0 0 10 5))
           (s (nerimux/pane:pane-screen p)))
      (push "first" (nerimux/terminal/types:screen-clipboard-queue s))
      (push "second" (nerimux/terminal/types:screen-clipboard-queue s))
      (let ((out (with-output-to-string (buf)
                   (nerimux/renderer::%render-clipboard buf (list p)))))
        (expect (string= "firstsecond" out))
        (expect (null (nerimux/terminal/types:screen-clipboard-queue s)))))))
