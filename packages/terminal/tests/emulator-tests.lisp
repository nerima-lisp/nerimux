(in-package #:nerimux/test/terminal)

(describe "terminal-suite/copy-mode"

  (it "scrollback-accumulates"
    (with-screen (s 5 3)
      (feed-lines s "L0" "L1" "L2" "L3" "L4")   ; 5 lines into a 3-row screen
      (expect (= 2 (length (screen-scrollback s))))
      (expect (string= "L2" (row-string s 0 :end 2)))
      (expect (string= "L4" (row-string s 2 :end 2)))))

  (it "copy-offset-projects-history"
    (with-screen (s 5 3)
      (feed-lines s "L0" "L1" "L2" "L3" "L4")
      (setf (screen-copy-mode-p s) t)
      (dolist (group '((0 ((0 "L2") (2 "L4")))
                       (1 ((0 "L1") (1 "L2") (2 "L3")))
                       (2 ((0 "L0") (1 "L1") (2 "L2")))))
        (destructuring-bind (offset checks) group
          (setf (screen-copy-offset s) offset)
          (check-table (loop for (row expected) in checks
                             collect (list (display-row-string s row :end 2)
                                           expected
                                           (format nil "offset ~D row ~D"
                                                   offset row)))
                       :test #'string=)))))

  (it "copy-mode-off-ignores-offset"
    (with-screen (s 5 3)
      (feed-lines s "L0" "L1" "L2" "L3" "L4")
      (setf (screen-copy-mode-p s) nil
            (screen-copy-offset s) 2)  ; should have no effect
      (expect (string= "L2" (display-row-string s 0 :end 2)))
      (expect (string= "L4" (display-row-string s 2 :end 2))))))

(describe "copy-mode/display-cell-oob"

  (it "display-cell-scrollback-col-oob-returns-blank"
    (with-screen (s 10 3)
      (let ((narrow-row (make-array 3 :initial-element
                                      (nerimux/terminal/types:blank-cell))))
        (setf (nerimux/terminal/types:screen-scrollback s) (list narrow-row))
        (setf (nerimux/terminal/types:screen-copy-mode-p s) t
              (nerimux/terminal/types:screen-copy-offset  s) 1))
      (let ((cell (nerimux/terminal/actions:screen-display-cell s 5 0)))
        (expect (char= #\Space (nerimux/terminal/types:cell-char cell))))))

  (it "display-cell-live-row-oob-returns-blank"
    (with-screen (s 5 3)
      (feed-lines s "L0" "L1" "L2")
      (let ((cell (nerimux/terminal/actions:screen-display-cell s 0 3)))
        (expect (char= #\Space (nerimux/terminal/types:cell-char cell))))))

  (it "display-cell-scrollback-nil-row-returns-blank"
    (with-screen (s 5 3)
      (setf (nerimux/terminal/types:screen-scrollback s) (list nil))
      (setf (nerimux/terminal/types:screen-copy-mode-p s) t
            (nerimux/terminal/types:screen-copy-offset  s) 1)
      (let ((cell (nerimux/terminal/actions:screen-display-cell s 0 0)))
        (expect (char= #\Space (nerimux/terminal/types:cell-char cell)))))))

(describe "terminal-suite/screen-process-bytes-suite"

  (it "screen-process-bytes-start-end-slice"
    (with-screen (s 10 5)
      (let ((buf (map '(simple-array (unsigned-byte 8) (*)) #'char-code "ABCDE")))
        (screen-process-bytes s buf :start 1 :end 3))
      (expect (char= #\B (char-at s 0 0)))
      (expect (char= #\C (char-at s 1 0)))
      (expect (char= #\Space (char-at s 2 0)))))

  (it "screen-process-bytes-empty-slice-is-noop"
    (with-screen (s 10 5)
      (screen-clear-dirty s)
      (let ((buf (map '(simple-array (unsigned-byte 8) (*)) #'char-code "XYZ")))
        (screen-process-bytes s buf :start 0 :end 0))
      (expect (char= #\Space (char-at s 0 0)))))

  (it "screen-process-bytes-processes-full-buffer-by-default"
    (with-screen (s 10 5)
      (let ((buf (map '(simple-array (unsigned-byte 8) (*)) #'char-code "HELLO")))
        (screen-process-bytes s buf))
      (expect (string= "HELLO" (row-string s 0 :end 5))))))

(describe "terminal-suite/trim-scroll-history-suite"

  (it "trim-scroll-history-caps-at-effective-limit"
    (with-screen (s 5 3)
      (let ((cap nerimux/terminal:+max-scrollback-lines+))
        (setf (nerimux/terminal/types:screen-scrollback s)
              (loop repeat (+ cap 50)
                    collect (make-array 5 :initial-element
                                         (nerimux/terminal/types:blank-cell))))
        (nerimux/terminal/actions:trim-scroll-history s)
        (expect (= cap (length (nerimux/terminal/types:screen-scrollback s)))))))

  (it "trim-scroll-history-noop-when-within-limit"
    (with-screen (s 5 3)
      (setf (nerimux/terminal/types:screen-scrollback s)
            (loop repeat 2 collect (make-array 5 :initial-element
                                                 (nerimux/terminal/types:blank-cell))))
      (nerimux/terminal/actions:trim-scroll-history s)
      (expect (= 2 (length (nerimux/terminal/types:screen-scrollback s))))))

  (it "scroll-enforces-history-cap-during-feed"
    (with-screen (s 5 3)
      (let ((cap nerimux/terminal:+max-scrollback-lines+))
        (setf (nerimux/terminal/types:screen-scrollback s)
              (loop repeat (1- cap)
                    collect (make-array 5 :initial-element
                                         (nerimux/terminal/types:blank-cell))))
        (loop for i below 5
              do (feed s (format nil "L~D" i))
              do (feed s (format nil "~C~C" #\Return #\Linefeed)))
        (expect (<= (length (nerimux/terminal/types:screen-scrollback s)) cap))))))

(describe "terminal-suite/decstbm-suite"

  (it "decstbm-sets-scroll-region"
    (with-screen (s 10 10)
      (nerimux/terminal/actions:decstbm s 2 7)
      (expect (= 2 (nerimux/terminal/types:screen-scroll-top    s)))
      (expect (= 7 (nerimux/terminal/types:screen-scroll-bottom s)))))

  (it "decstbm-homes-cursor-to-origin"
    (with-screen (s 10 10)
      (setf (nerimux/terminal/types:screen-cursor-x s) 5
            (nerimux/terminal/types:screen-cursor-y s) 5)
      (nerimux/terminal/actions:decstbm s 2 7)
      (check-cursor s 0 0)))

  (it "decstbm-rejects-invalid-region"
    (with-screen (s 10 10)
      (let ((old-top    (nerimux/terminal/types:screen-scroll-top    s))
            (old-bottom (nerimux/terminal/types:screen-scroll-bottom s)))
        (nerimux/terminal/actions:decstbm s 5 5)
        (expect (= old-top    (nerimux/terminal/types:screen-scroll-top    s)))
        (expect (= old-bottom (nerimux/terminal/types:screen-scroll-bottom s))))))

  (it "decstbm-clamps-bottom-to-height-minus-one"
    (with-screen (s 10 10)
      (nerimux/terminal/actions:decstbm s 0 99)
      (expect (= 9 (nerimux/terminal/types:screen-scroll-bottom s))))))

(describe "terminal-suite/screen-consume-bell-suite"

  (it "screen-consume-bell-pending-and-idempotent"
    (with-screen (s 10 5)
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#x07)))
      (expect (nerimux/terminal/types:screen-bell-pending s))
      (expect (nerimux/terminal/types:screen-consume-bell s))
      (expect (nerimux/terminal/types:screen-bell-pending s) :to-be-falsy)
      (expect (nerimux/terminal/types:screen-consume-bell s) :to-be-falsy))))

(describe "terminal-suite/screen-resize-suite"

  (it "screen-resize-dimensions-table"
    (dolist (row '((10 5  20 10 "grow:   10x5 → 20x10")
                   (20 10 10 5  "shrink: 20x10 → 10x5")))
      (destructuring-bind (init-w init-h new-w new-h desc) row
        (declare (ignore desc))
        (with-screen (s init-w init-h)
          (screen-resize s new-w new-h)
          (expect (= new-w (screen-width  s)))
          (expect (= new-h (screen-height s)))))))

  (it "screen-resize-preserves-content-within-new-bounds"
    (with-screen (s 5 3)
      (feed s "hello")
      (screen-resize s 10 5)
      (check-row s 0 "hello")))

  (it "screen-resize-clamps-cursor-inside-new-bounds"
    (with-screen (s 20 10)
      (feed s (esc "[10;20H"))   ; row 9, col 19
      (screen-resize s 5 3)
      (expect (<= (screen-cursor-x s) 4))
      (expect (<= (screen-cursor-y s) 2)))))
