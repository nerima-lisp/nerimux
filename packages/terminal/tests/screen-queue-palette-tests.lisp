(in-package #:nerimux/test/terminal)

(describe "terminal-suite/queue-slots-suite"

  (it "screen-passthrough-queue-defaults-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-passthrough-queue s)))))

  (it "screen-passthrough-queue-can-be-pushed-and-drained"
    (with-screen (s 10 5)
      (push "pt-a" (nerimux/terminal/types:screen-passthrough-queue s))
      (push "pt-b" (nerimux/terminal/types:screen-passthrough-queue s))
      (let ((items (nreverse (nerimux/terminal/types:screen-passthrough-queue s))))
        (setf (nerimux/terminal/types:screen-passthrough-queue s) nil)
        (expect (equal '("pt-a" "pt-b") items)))))

  (it "screen-clipboard-queue-defaults-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-clipboard-queue s)))))

  (it "screen-clipboard-queue-can-be-pushed-and-drained"
    (with-screen (s 10 5)
      (push "clip-a" (nerimux/terminal/types:screen-clipboard-queue s))
      (push "clip-b" (nerimux/terminal/types:screen-clipboard-queue s))
      (let ((items (nreverse (nerimux/terminal/types:screen-clipboard-queue s))))
        (setf (nerimux/terminal/types:screen-clipboard-queue s) nil)
        (expect (equal '("clip-a" "clip-b") items)))))

  (it "screen-drain-queue-reads-and-clears-atomically"
    (with-screen (s 10 5)
      (push "pt-a" (nerimux/terminal/types:screen-passthrough-queue s))
      (push "pt-b" (nerimux/terminal/types:screen-passthrough-queue s))
      (let ((items (nerimux/terminal/types:screen-drain-queue
                    s
                    #'nerimux/terminal/types:screen-passthrough-queue
                    (lambda (screen value)
                      (setf (nerimux/terminal/types:screen-passthrough-queue screen) value)))))
        (expect (equal '("pt-a" "pt-b") items))
        (expect (null (nerimux/terminal/types:screen-passthrough-queue s))))))

  (it "screen-drain-queue-empty-queue-returns-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-drain-queue
                     s
                     #'nerimux/terminal/types:screen-clipboard-queue
                     (lambda (screen value)
                       (setf (nerimux/terminal/types:screen-clipboard-queue screen) value))))))))

(describe "terminal-suite/palette-overrides-slot-suite"

  (it "screen-palette-overrides-slot-defaults-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-palette-overrides s)))))

  (it "screen-palette-overrides-lazily-allocated-on-first-set"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%palette-override-set s 42 #xABCDEF)
      (let ((overrides (nerimux/terminal/types:screen-palette-overrides s)))
        (expect (simple-vector-p overrides))
        (expect (= 256 (length overrides)))))))

(describe "terminal-suite/palette-override-get-set-clear-suite"

  (it "palette-override-get-returns-nil-before-any-set"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:%palette-override-get s 0)))
      (expect (null (nerimux/terminal/types:%palette-override-get s 255)))))

  (it "palette-override-set-then-get-round-trips"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%palette-override-set s 42 #xABCDEF)
      (expect (= #xABCDEF (nerimux/terminal/types:%palette-override-get s 42)))))

  (it "palette-override-set-does-not-disturb-other-indices"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%palette-override-set s 5 #x123456)
      (expect (null (nerimux/terminal/types:%palette-override-get s 4)))
      (expect (null (nerimux/terminal/types:%palette-override-get s 6)))))

  (it "palette-override-get-out-of-range-index-returns-nil"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%palette-override-set s 0 #xFFFFFF)
      (expect (null (nerimux/terminal/types:%palette-override-get s -1)))
      (expect (null (nerimux/terminal/types:%palette-override-get s 256)))))

  (it "palette-override-set-out-of-range-index-is-ignored"
    (with-screen (s 10 5)
      (finishes (nerimux/terminal/types:%palette-override-set s 256 #xFFFFFF))
      (finishes (nerimux/terminal/types:%palette-override-set s -1 #xFFFFFF))))

  (it "palette-override-clear-resets-single-index-to-nil"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%palette-override-set s 10 #x111111)
      (nerimux/terminal/types:%palette-override-set s 20 #x222222)
      (nerimux/terminal/types:%palette-override-clear s 10)
      (expect (null (nerimux/terminal/types:%palette-override-get s 10)))
      (expect (= #x222222 (nerimux/terminal/types:%palette-override-get s 20)))))

  (it "palette-override-clear-on-unset-index-is-noop"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%palette-override-set s 0 #xABCDEF)
      (finishes (nerimux/terminal/types:%palette-override-clear s 100))
      (expect (null (nerimux/terminal/types:%palette-override-get s 100)))))

  (it "palette-override-clear-with-no-overrides-allocated-is-noop"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-palette-overrides s)))
      (finishes (nerimux/terminal/types:%palette-override-clear s 0))
      (expect (null (nerimux/terminal/types:screen-palette-overrides s)))))

  (it "palette-override-clear-out-of-range-index-is-ignored"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%palette-override-set s 0 #xFFFFFF)
      (finishes (nerimux/terminal/types:%palette-override-clear s 256))
      (finishes (nerimux/terminal/types:%palette-override-clear s -1))
      (expect (= #xFFFFFF (nerimux/terminal/types:%palette-override-get s 0))))))

(describe "terminal-suite/palette-clear-all-suite"

  (it "palette-override-clear-all-drops-vector"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%palette-override-set s 0 #xFF0000)
      (nerimux/terminal/types:%palette-override-set s 255 #x00FF00)
      (expect (nerimux/terminal/types:screen-palette-overrides s) :to-be-truthy)
      (nerimux/terminal/types:%palette-override-clear-all s)
      (expect (null (nerimux/terminal/types:screen-palette-overrides s)))))

  (it "palette-override-clear-all-on-empty-screen-is-noop"
    (with-screen (s 10 5)
      (finishes (nerimux/terminal/types:%palette-override-clear-all s))
      (expect (null (nerimux/terminal/types:screen-palette-overrides s)))))

  (it "palette-override-clear-all-makes-all-indices-return-nil"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%palette-override-set s 0   #x111111)
      (nerimux/terminal/types:%palette-override-set s 128 #x888888)
      (nerimux/terminal/types:%palette-override-set s 255 #xFFFFFF)
      (nerimux/terminal/types:%palette-override-clear-all s)
      (expect (null (nerimux/terminal/types:%palette-override-get s 0)))
      (expect (null (nerimux/terminal/types:%palette-override-get s 128)))
      (expect (null (nerimux/terminal/types:%palette-override-get s 255))))))
