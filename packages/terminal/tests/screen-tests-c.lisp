(in-package #:nerimux/test/terminal)

(declaim (notinline nerimux/terminal/types:reset-sgr-pen))

(describe "terminal-suite/resize"


  (it "screen-clear-dirty-resets-and-is-idempotent"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-truthy)
      (screen-clear-dirty s)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-falsy)
      (screen-clear-dirty s)
      (expect (nerimux/terminal/types:screen-dirty-p s) :to-be-falsy))))

(describe "terminal-suite/reset-sgr-pen-suite"

  (it "reset-sgr-pen-restores-all-five-slots"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-cur-fg       s) 3
            (nerimux/terminal/types:screen-cur-bg       s) 4
            (nerimux/terminal/types:screen-cur-attrs    s) #b11111111
            (nerimux/terminal/types:screen-cur-attrs2   s) #b00000011
            (nerimux/terminal/types:screen-cur-ul-color s) 200)
      (nerimux/terminal/types:reset-sgr-pen s)
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-fg       s)))
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-bg       s)))
      (expect (= 0 (nerimux/terminal/types:screen-cur-attrs    s)))
      (expect (= 0 (nerimux/terminal/types:screen-cur-attrs2   s)))
      (expect (= 0 (nerimux/terminal/types:screen-cur-ul-color s)))))

  (it "reset-sgr-pen-idempotent"
    (with-screen (s 10 5)
      (nerimux/terminal/types:reset-sgr-pen s)
      (nerimux/terminal/types:reset-sgr-pen s)
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-fg s)))
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-bg s)))))

  (it "screen-cur-fg-and-cur-bg-default-to-sentinel"
    (with-screen (s 10 5)
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-fg s)))
      (expect (= nerimux/terminal/types:+default-color+ (nerimux/terminal/types:screen-cur-bg s))))))

(describe "terminal-suite/bell-pending-c-suite"

  (it "bell-pending-default-and-toggle"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)
      (setf (nerimux/terminal/types:screen-bell-pending s) t)
      (expect (nerimux/terminal/types:screen-bell-pending s))
      (setf (nerimux/terminal/types:screen-bell-pending s) nil)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)))

  (it "bel-byte-sets-bell-pending"
    (with-screen (s 10 5)
      (screen-clear-dirty s)
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(7)))
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-truthy))))

(describe "terminal-suite/screen-consume-bell-c-suite"

  (it "screen-consume-bell-returns-nil-when-no-bell-pending"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-falsy)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)))

  (it "screen-consume-bell-returns-true-clears-then-nil"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-bell-pending s) t)
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-truthy)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-falsy)))

  (it "screen-consume-bell-after-bel-byte"
    (with-screen (s 10 5)
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(7)))
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-truthy)
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-truthy)
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy))))

(describe "terminal-suite/screen-slots"

  (it "screen-last-char-nil-then-updated"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-last-char s)))
      (feed s "Z")
      (expect (char= #\Z (nerimux/terminal/types:screen-last-char s)))))

  (it "screen-slot-defaults-table"
    (dolist (row (list (list #'nerimux/terminal/types:screen-charset        :ascii "charset defaults to :ascii")
                       (list #'nerimux/terminal/types:screen-autowrap        t      "autowrap defaults to T")
                       (list #'nerimux/terminal/types:screen-cursor-shape    1      "cursor-shape defaults to 1")
                       (list #'nerimux/terminal/types:screen-bracketed-paste nil    "bracketed-paste defaults to NIL")
                       (list #'nerimux/terminal/types:screen-app-cursor-keys nil    "app-cursor-keys defaults to NIL")
                       (list #'screen-title                                   ""     "title defaults to empty string")
                       (list #'screen-copy-mark                               nil    "copy-mark defaults to NIL")))
      (destructuring-bind (accessor expected desc) row
        (declare (ignore desc))
        (with-screen (s 10 5)
          (expect (equal expected (funcall accessor s))))))))

(describe "terminal-suite/copy-mode-extra-slots"

  (it "copy-mode-entered-by-mouse-defaults-nil"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p s) :to-be-falsy)))

  (it "copy-mode-entered-by-mouse-can-be-set"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p s) t)
      (expect (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p s) :to-be-truthy)
      (setf (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p s) nil)
      (expect (nerimux/terminal/types:screen-copy-mode-entered-by-mouse-p s) :to-be-falsy)))

  (it "copy-exit-on-bottom-defaults-nil"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-copy-exit-on-bottom s) :to-be-falsy)))

  (it "copy-exit-on-bottom-can-be-set"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-copy-exit-on-bottom s) t)
      (expect (nerimux/terminal/types:screen-copy-exit-on-bottom s) :to-be-truthy)
      (setf (nerimux/terminal/types:screen-copy-exit-on-bottom s) nil)
      (expect (nerimux/terminal/types:screen-copy-exit-on-bottom s) :to-be-falsy))))

(describe "terminal-suite/osc-default-color-slots"

  (it "osc-default-fg-initial-value-matches-constant"
    (with-screen (s 10 5)
      (expect (= nerimux/terminal/types:+osc-default-fg+
                 (nerimux/terminal/types:screen-osc-default-fg s)))))

  (it "osc-default-bg-initial-value-matches-constant"
    (with-screen (s 10 5)
      (expect (= nerimux/terminal/types:+osc-default-bg+
                 (nerimux/terminal/types:screen-osc-default-bg s)))))

  (it "osc-default-fg-can-be-set-and-reset-via-sequence"
    (with-screen (s 10 5)
      (feed s (format nil "~C]10;#112233~C\\" #\Escape #\Escape))
      (expect (= #x112233 (nerimux/terminal/types:screen-osc-default-fg s)))
      (feed s (format nil "~C]110~C\\" #\Escape #\Escape))
      (expect (= nerimux/terminal/types:+osc-default-fg+
                 (nerimux/terminal/types:screen-osc-default-fg s)))))

  (it "osc-default-bg-can-be-set-and-reset-via-sequence"
    (with-screen (s 10 5)
      (feed s (format nil "~C]11;#aabbcc~C\\" #\Escape #\Escape))
      (expect (= #xAABBCC (nerimux/terminal/types:screen-osc-default-bg s)))
      (feed s (format nil "~C]111~C\\" #\Escape #\Escape))
      (expect (= nerimux/terminal/types:+osc-default-bg+
                 (nerimux/terminal/types:screen-osc-default-bg s))))))

(describe "terminal-suite/current-hyperlink-slots"

  (it "screen-current-hyperlink-defaults-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-current-hyperlink s)))))

  (it "screen-current-hyperlink-set-by-osc8"
    (with-screen (s 10 5)
      (feed s (format nil "~C]8;;https://example.com~C\\" #\Escape #\Escape))
      (expect (string= "https://example.com"
                       (nerimux/terminal/types:screen-current-hyperlink s)))))

  (it "screen-current-hyperlink-cleared-by-osc8-empty"
    (with-screen (s 10 5)
      (feed s (format nil "~C]8;;https://example.com~C\\" #\Escape #\Escape))
      (expect (nerimux/terminal/types:screen-current-hyperlink s))
      (feed s (format nil "~C]8;;~C\\" #\Escape #\Escape))
      (expect (null (nerimux/terminal/types:screen-current-hyperlink s)))))

  (it "screen-current-hyperlink-stamped-onto-written-cells"
    (with-screen (s 10 5)
      (feed s (format nil "~C]8;;https://cl.org~C\\" #\Escape #\Escape))
      (feed s "AB")
      (expect (string= "https://cl.org"
                       (nerimux/terminal/types:cell-hyperlink (cell-at s 0 0))))
      (expect (string= "https://cl.org"
                       (nerimux/terminal/types:cell-hyperlink (cell-at s 1 0))))
      (feed s (format nil "~C]8;;~C\\" #\Escape #\Escape))
      (feed s "C")
      (expect (null (nerimux/terminal/types:cell-hyperlink (cell-at s 2 0)))))))

(describe "terminal-suite/clear-line-wrapped-suite"

  (it "clear-line-wrapped-removes-set-flag"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%mark-line-wrapped s 2)
      (expect (nerimux/terminal/types:%line-wrapped-p s 2) :to-be-truthy)
      (nerimux/terminal/types:%clear-line-wrapped s 2)
      (expect (nerimux/terminal/types:%line-wrapped-p s 2) :to-be-falsy)))

  (it "clear-line-wrapped-is-noop-on-unmarked-row"
    (with-screen (s 10 5)
      (finishes (nerimux/terminal/types:%clear-line-wrapped s 3))
      (expect (nerimux/terminal/types:%line-wrapped-p s 3) :to-be-falsy)))

  (it "clear-line-wrapped-does-not-disturb-other-rows"
    (with-screen (s 10 5)
      (nerimux/terminal/types:%mark-line-wrapped s 0)
      (nerimux/terminal/types:%mark-line-wrapped s 1)
      (nerimux/terminal/types:%mark-line-wrapped s 2)
      (nerimux/terminal/types:%clear-line-wrapped s 1)
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-truthy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 1) :to-be-falsy)
      (expect (nerimux/terminal/types:%line-wrapped-p s 2) :to-be-truthy)))

  (it "clear-line-wrapped-is-noop-when-no-hash-table"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-wrapped-rows s)))
      (finishes (nerimux/terminal/types:%clear-line-wrapped s 0))
      (expect (nerimux/terminal/types:%line-wrapped-p s 0) :to-be-falsy))))
