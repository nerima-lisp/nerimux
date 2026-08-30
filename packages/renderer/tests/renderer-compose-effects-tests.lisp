(in-package #:nerimux/test/renderer)

;;;; Direct unit tests for renderer-compose-effects.lisp's %render-passthrough
;;;; and %render-clipboard (and, transitively, the shared %drain-screen-queue
;;;; helper they're both built on).
;;;;
;;;; allow-passthrough and set-clipboard (domain/options, deleted R2.2) are
;;;; gone along with the config file that could ever have set either away
;;;; from its registered default: allow-passthrough always drains without
;;;; emitting, set-clipboard always emits — see renderer-compose-effects.lisp.

(describe "renderer-suite/compose-effects"

  ;; allow-passthrough is always off: the queue is drained (cleared) without
  ;; writing its contents to the frame.
  (it "render-passthrough-drains-without-emitting"
    (let* ((p (make-no-pty-pane 1 0 0 10 5))
           (s (nerimux/pane:pane-screen p)))
      (push (format nil "~C]1337;a" #\Escape)
            (nerimux/terminal/types:screen-passthrough-queue s))
      (let ((out (with-output-to-string (buf)
                   (nerimux/renderer::%render-passthrough buf (list p)))))
        (expect (string= "" out))
        (expect (null (nerimux/terminal/types:screen-passthrough-queue s))))))

  ;; Multiple panes are drained independently — each pane's queue clears on
  ;; its own even though nothing is ever emitted to the frame.
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

  ;; set-clipboard is always on: the queued OSC 52 sequence is emitted to the
  ;; frame in FIFO (oldest-first) order, then the queue is cleared.
  (it "render-clipboard-emits-in-fifo-order"
    (let* ((p (make-no-pty-pane 1 0 0 10 5))
           (s (nerimux/pane:pane-screen p)))
      ;; screen-clipboard-queue is push-accumulated (most-recent-first), so
      ;; pushing "first" before "second" means "first" was queued earliest.
      (push "first" (nerimux/terminal/types:screen-clipboard-queue s))
      (push "second" (nerimux/terminal/types:screen-clipboard-queue s))
      (let ((out (with-output-to-string (buf)
                   (nerimux/renderer::%render-clipboard buf (list p)))))
        (expect (string= "firstsecond" out))
        (expect (null (nerimux/terminal/types:screen-clipboard-queue s)))))))
