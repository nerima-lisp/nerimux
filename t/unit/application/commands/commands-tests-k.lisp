(in-package #:nerimux/test)

;;;; commands tests — part K: copy-mode search-forward/backward, wrap-search,
;;;; search-across-scrollback.

(defmacro define-copy-mode-search-cases (&body cases)
  `(progn
     ,@(loop for case in cases
             for name = (first case)
             for options = (cddr case)
             for width = (or (getf options :width) 30)
             for height = (or (getf options :height) 5)
             for fixture = (getf options :fixture)
             for cursor = (getf options :cursor)
             for action = (getf options :action)
             for expectations = (getf options :expectations)
             for wrap-search = (getf options :wrap-search)
             for body = `(let ((s (make-screen ,width ,height)))
                           ,fixture
                           (nerimux/commands::copy-mode-enter s)
                           ,@(when cursor
                               `((setf (nerimux/terminal/types:screen-copy-cursor s)
                                       ,cursor)))
                           ,action
                           (%check-copy-mode-search-expectations s ',expectations))
             collect
             `(it ,(string-downcase (symbol-name name))
                ,(if (eq wrap-search :off)
                     `(with-isolated-options ("wrap-search" nil)
                        ,body)
                     body)))))

(describe "commands-suite"

  ;; ── copy-mode-search-forward / search-backward ──────────────────────────────

  (defun %check-copy-mode-search-expectations (screen expectations)
    (dolist (expectation expectations)
      (destructuring-bind (kind expected desc) expectation
        (declare (ignore desc))
        (ecase kind
          (:cursor
           (expect (equal expected (nerimux/terminal/types:screen-copy-cursor screen))))
          (:cursor-col
           (expect (= expected (cdr (nerimux/terminal/types:screen-copy-cursor screen)))))
          (:offset
           (expect (= expected (nerimux/terminal/types:screen-copy-offset screen))))
          (:search-term
           (expect (string= expected (nerimux/terminal/types:screen-copy-search-term screen))))))))

  (define-copy-mode-search-cases
    (copy-mode-search-forward-finds-term
     "copy-mode-search-forward moves cursor to the first match after current position."
     :fixture (feed s "abc def abc")
     :cursor (cons 0 0)
     :action (nerimux/commands::copy-mode-search-forward s "abc")
     :expectations ((:cursor-col 8 "search-forward must find second 'abc' at col 8")))
    (copy-mode-search-forward-saves-term
     "copy-mode-search-forward saves the search term for n/N repeats."
     :fixture (feed s "foo bar foo")
     :cursor (cons 0 0)
     :action (nerimux/commands::copy-mode-search-forward s "foo")
     :expectations ((:search-term "foo" "search term must be saved after search-forward")))
    (copy-mode-search-backward-finds-term
     "copy-mode-search-backward moves cursor to the nearest match before current position."
     :fixture (feed s "abc def abc")
     :cursor (cons 0 11)
     :action (nerimux/commands::copy-mode-search-backward s "abc")
     :expectations ((:cursor-col 8 "search-backward must find 'abc' at col 8")))
    (copy-mode-search-forward-regex-dot
     "search-forward treats the term as a regex: 'a.c' matches 'abc'."
     :fixture (feed s "xy abc z")
     :cursor (cons 0 0)
     :action (nerimux/commands::copy-mode-search-forward s "a.c")
     :expectations ((:cursor-col 3 "regex a.c must match 'abc' at col 3")))
    (copy-mode-search-forward-regex-char-class
     "search-forward regex character class '[0-9]+' finds the first digit run."
     :fixture (feed s "abc 123 def")
     :cursor (cons 0 0)
     :action (nerimux/commands::copy-mode-search-forward s "[0-9]+")
     :expectations ((:cursor-col 4 "regex [0-9]+ must match '123' starting at col 4")))
    (copy-mode-search-invalid-regex-falls-back-to-literal
     "An invalid regex falls back to a literal substring search."
     :fixture (feed s "a (b) c")
     :cursor (cons 0 0)
     :action (nerimux/commands::copy-mode-search-forward s "(")
     :expectations ((:cursor-col 2 "literal '(' must be found at col 2"))))

  ;; ── wrap-search: search wraps around the buffer ends (default on) ────────────

  (define-copy-mode-search-cases
    (copy-mode-search-forward-wraps-to-top
     "With wrap-search on, forward search wraps to the first match in the buffer."
     :fixture (feed s "abc")
     :cursor (cons 2 0)
     :action (nerimux/commands::copy-mode-search-forward s "abc")
     :expectations ((:cursor (0 . 0) "no match below -> wrap to row 0 col 0")))
    (copy-mode-search-forward-no-wrap-when-off
     "With wrap-search off, forward search with no lower match leaves the cursor."
     :wrap-search :off
     :fixture (feed s "abc")
     :cursor (cons 2 0)
     :action (nerimux/commands::copy-mode-search-forward s "abc")
     :expectations ((:cursor (2 . 0) "wrap-search off -> cursor stays put")))
    (copy-mode-search-backward-wraps-to-bottom
     "With wrap-search on, backward search wraps to the last match in the buffer."
     :fixture (feed-lines s "" "" "" "" "abc")
     :cursor (cons 0 0)
     :action (nerimux/commands::copy-mode-search-backward s "abc")
     :expectations ((:cursor (4 . 0) "no match above -> wrap to row 4 col 0")))
    (copy-mode-search-backward-regex
     "search-backward matches a regex and finds the nearest match before the cursor."
     :fixture (feed s "a1b a2b a3b")
     :cursor (cons 0 11)
     :action (nerimux/commands::copy-mode-search-backward s "a.b")
     :expectations ((:cursor-col 8 "regex a.b backward must find the last match before col 11")))
    (copy-mode-search-next-repeats-forward
     "copy-mode-search-next repeats forward search and wraps when needed."
     :fixture (feed s "abc def abc")
     :cursor (cons 0 0)
     :action (progn
               (nerimux/commands::copy-mode-search-forward s "abc")
               (expect (= 8 (cdr (nerimux/terminal/types:screen-copy-cursor s))))
               (nerimux/commands::copy-mode-search-next s))
     :expectations ((:cursor-col 0 "search-next wraps to the first match")))
    (copy-mode-search-prev-noop-without-term
     "copy-mode-search-prev does nothing when no search term is saved."
     :width 20
     :cursor (cons 0 5)
     :action (progn
               (setf (nerimux/terminal/types:screen-copy-search-term s) nil)
               (nerimux/commands::copy-mode-search-prev s))
     :expectations ((:cursor-col 5 "search-prev must not move cursor when no term is saved"))))

  ;; ── copy-mode search across scrollback boundary ─────────────────────────────

  (defun %make-text-row (width text)
    "Create a scrollback row vector WIDTH wide with TEXT followed by space cells."
    (let ((row (make-array width
                           :initial-element
                           (nerimux/terminal/types:make-cell
                            :char #\Space :fg 7 :bg 0 :attrs 0 :width 1))))
      (loop for i from 0 below (min (length text) width)
            do (setf (aref row i)
                     (nerimux/terminal/types:make-cell
                      :char (char text i) :fg 7 :bg 0 :attrs 0 :width 1)))
      row))

  ;; Forward search with wrap-search wraps from the live grid into the scrollback buffer
  ;; when the term is only present in the scrollback.
  (it "copy-mode-search-forward-wraps-into-scrollback"
    ;; Screen 20x3; scrollback newest-first: sb[0]=row with term, sb[1]=blank.
    ;; Virtual rows: vrow0=sb[1](blank), vrow1=sb[0](term), vrow2-4=live(blank).
    (let* ((s    (make-screen 20 3))
           (sb0  (%make-text-row 20 "findme here"))
           (sb1  (%make-text-row 20 "")))
      (setf (nerimux/terminal/types:screen-scrollback s) (list sb0 sb1))
      (nerimux/commands::copy-mode-enter s)
      ;; Cursor starts at bottom of live grid (row 2, col 0), offset 0.
      (nerimux/commands::copy-mode-search-forward s "findme")
      ;; After wrap the term is at virtual row 1 (newest scrollback); set_vrow
      ;; sets offset=1, cursor-row=0.
      (expect (= 1 (nerimux/terminal/types:screen-copy-offset s)))
      (expect (= 0 (car (nerimux/terminal/types:screen-copy-cursor s))))
      (expect (= 0 (cdr (nerimux/terminal/types:screen-copy-cursor s))))))

  ;; Backward search from the live grid finds a term in the scrollback without wrapping.
  (it "copy-mode-search-backward-finds-term-in-scrollback"
    ;; Screen 20x3; sb[0]=newest='target row', sb[1]=oldest=blank.
    ;; Cursor at live-grid top (row 0, offset 0).
    (let* ((s    (make-screen 20 3))
           (sb0  (%make-text-row 20 "target row"))
           (sb1  (%make-text-row 20 "")))
      (setf (nerimux/terminal/types:screen-scrollback s) (list sb0 sb1))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 0))
      (nerimux/commands::copy-mode-search-backward s "target")
      ;; target is in vrow 1 (newest scrollback); set_vrow → offset=1, row=0.
      (expect (= 1 (nerimux/terminal/types:screen-copy-offset s)))
      (expect (= 0 (cdr (nerimux/terminal/types:screen-copy-cursor s)))))))
