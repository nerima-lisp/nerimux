(in-package #:nerimux/test/terminal)

(describe "terminal-suite/direct-action-cursor"


  (it "cursor-ri-moves-up-within-region"
    (with-screen (s 10 10)
      (setf (nerimux/terminal/types:screen-cursor-y s) 5)
      (nerimux/terminal/actions:cursor-ri s)
      (expect (= 4 (screen-cursor-y s)))))

  (it "cursor-ri-at-scroll-top-scrolls-down"
    (with-screen (s 5 5)
      (feed s "LINE0")
      (nerimux/terminal/actions:set-cursor s 0 0)
      (nerimux/terminal/actions:cursor-ri s)
      (expect (row-blank-p s 0))
      (check-row s 1 "LINE0")))

  (it "cursor-ri-at-scroll-top-non-default-region"
    (with-scroll-region (s 10 10 3 7 3)
      (nerimux/terminal/actions:cursor-ri s)
      (expect (= 3 (screen-cursor-y s))))))

(describe "terminal-suite/cursor-nel-suite"

  (it "cursor-nel-moves-to-column-zero-of-next-row"
    (with-screen (s 10 5)
      (feed s "hello")                       ; cursor at col 5, row 0
      (nerimux/terminal/actions:cursor-nel s)
      (check-cursor s 0 1)))

  (it "cursor-nel-at-right-edge-moves-to-next-row"
    (with-screen (s 5 5)
      (setf (nerimux/terminal/types:screen-cursor-x s) 4
            (nerimux/terminal/types:screen-cursor-y s) 2)
      (nerimux/terminal/actions:cursor-nel s)
      (check-cursor s 0 3)))

  (it "cursor-nel-at-bottom-margin-scrolls"
    (with-screen (s 5 3)
      (feed s "LINE0")
      (nerimux/terminal/actions:set-cursor s 3 2)  ; col 3, last row
      (nerimux/terminal/actions:cursor-nel s)
      (check-cursor s 0 2)
      (expect (plusp (length (nerimux/terminal/types:screen-scrollback s))))))

  (it "cursor-nel-via-parser"
    (with-screen (s 10 5)
      (feed s "hello")                       ; cursor at col 5, row 0
      (feed s (esc "E"))                     ; ESC E = NEL
      (check-cursor s 0 1)))


  (it "write-char-at-cursor-wide-char-wraps-at-right-edge"
    (with-screen (s 3 3)
      (feed s "ab")                          ; cursor at col 2
      (utf8-feed s "あ")
      (expect (char= #\Space (char-at s 2 0)))
      (expect (char= #\あ (char-at s 0 1)))))

  (it "write-codepoint-places-character"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:write-codepoint s 65)  ; U+0041 = 'A'
      (expect (char= #\A (char-at s 0 0)))
      (check-cursor s 1 0)))

  (it "cursor-down-slash-scroll-advances-within-region"
    (with-screen (s 10 5)
      (nerimux/terminal/actions:cursor-down/scroll s)  ; internal
      (check-cursor s 0 1)))

  (it "cursor-down-slash-scroll-scrolls-at-bottom"
    (with-screen (s 5 3)
      (feed s "L0")
      (nerimux/terminal/actions:set-cursor s 0 2) ; bottom row
      (nerimux/terminal/actions:cursor-down/scroll s)
      (check-cursor s 0 2)
      (expect (plusp (length (nerimux/terminal/types:screen-scrollback s))))))

  (it "advance-cursor-stays-in-line-when-room"
    (with-screen (s 10 5)
      (nerimux/terminal/actions::%advance-cursor s 3)
      (check-cursor s 3 0)))

  (it "advance-cursor-defers-wrap-at-right-edge"
    (with-screen (s 5 3)
      (nerimux/terminal/actions:set-cursor s 4 0)  ; last column
      (nerimux/terminal/actions::%advance-cursor s 1)
      (check-cursor s 4 0)                          ; parked, NOT wrapped
      (expect (nerimux/terminal/types:screen-pending-wrap s) :to-be-truthy)))

  (it "deferred-wrap-next-char-wraps-and-clears"
    (with-screen (s 3 3)
      (feed s "abc")                  ; fills row 0; cursor parks at col 2, wrap pending
      (expect (nerimux/terminal/types:screen-pending-wrap s) :to-be-truthy)
      (check-cursor s 2 0)            ; parked at last column of row 0
      (feed s "d")                    ; triggers the deferred wrap
      (expect (char= #\d (char-at s 0 1)))
      (check-cursor s 1 1)
      (expect (nerimux/terminal/types:screen-pending-wrap s) :to-be-falsy)))

  (it "deferred-wrap-newline-no-spurious-blank-line"
    (with-screen (s 3 4)
      (feed s "abc")                  ; fills row 0 (pending wrap)
      (feed s (format nil "~C~C" #\Return #\Linefeed))  ; CR LF
      (feed s "d")
      (expect (char= #\a (char-at s 0 0)))
      (expect (char= #\d (char-at s 0 1)))
      (expect (char= #\Space (char-at s 1 1)))))


  (it "advance-cursor-clamps-when-autowrap-off"
    (with-screen (s 5 3)
      (setf (nerimux/terminal/types:screen-autowrap s) nil)
      (nerimux/terminal/actions:set-cursor s 4 0)
      (nerimux/terminal/actions::%advance-cursor s 1)
      (check-cursor s 4 0)))

  (it "write-char-overwrites-at-right-edge-when-autowrap-off"
    (with-screen (s 5 3)
      (feed s (esc "[?7l"))        ; disable auto-wrap
      (nerimux/terminal/actions:set-cursor s 4 0)
      (nerimux/terminal/actions:write-char-at-cursor s #\A)
      (check-cursor s 4 0)
      (expect (char= #\A (char-at s 4 0)))
      (expect (row-blank-p s 1))))


  (it "cursor-direction-moves-by-n-table"
    (dolist (row (list (list #'nerimux/terminal/actions:cursor-up    :y 6 2 4 "cursor-up 2 from row 6 → row 4")
                       (list #'nerimux/terminal/actions:cursor-down  :y 3 3 6 "cursor-down 3 from row 3 → row 6")
                       (list #'nerimux/terminal/actions:cursor-left  :x 7 3 4 "cursor-left 3 from col 7 → col 4")
                       (list #'nerimux/terminal/actions:cursor-right :x 2 4 6 "cursor-right 4 from col 2 → col 6")))
      (destructuring-bind (fn axis init-val count expected desc) row
        (declare (ignore desc))
        (with-screen (s 10 10)
          (if (eq axis :x)
              (setf (nerimux/terminal/types::screen-cursor-x s) init-val)
              (setf (nerimux/terminal/types::screen-cursor-y s) init-val))
          (funcall fn s count)
          (let ((actual (if (eq axis :x) (screen-cursor-x s) (screen-cursor-y s))))
            (expect (= expected actual))))))))
