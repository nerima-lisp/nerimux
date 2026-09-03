(in-package #:nerimux/test/terminal)

(defmacro define-boolean-slot-tests (slot-accessor suite-name
                                                   enable-sequence
                                                   disable-sequence
                                                   &key
                                                   (suite-description
                                                    (symbol-name suite-name))
                                                   (parent-suite
                                                    'terminal-suite))
  "Generate a describe block with three cl-weave tests for a boolean screen slot.

   SLOT-ACCESSOR    — accessor symbol (e.g. nerimux/terminal/types:screen-insert-mode)
   SUITE-NAME       — unquoted symbol naming the describe block
   ENABLE-SEQUENCE  — form that feeds the enabling sequence to screen variable S
   DISABLE-SEQUENCE — form that feeds the disabling sequence to screen variable S"
  (declare (ignore suite-description))
  (let* ((name (symbol-name slot-accessor))
         (default-test (string-downcase (format nil "~A-DEFAULTS-FALSE" name)))
         (enabled-test
          (string-downcase (format nil "~A-ENABLED-BY-SEQUENCE" name)))
         (disabled-test
          (string-downcase (format nil "~A-DISABLED-BY-SEQUENCE" name))))
    `(describe
      ,(format nil
               "~A/~A"
               (string-downcase (symbol-name parent-suite))
               (string-downcase (symbol-name suite-name)))
      (it ,default-test
          (with-screen (s 10 5) (expect (,slot-accessor s) :to-be-falsy)))
      (it ,enabled-test
          (with-screen (s 10 5)
                       ,enable-sequence
                       (expect (,slot-accessor s) :to-be-truthy)))
      (it ,disabled-test
          (with-screen (s 10 5)
                       ,enable-sequence
                       ,disable-sequence
                       (expect (,slot-accessor s) :to-be-falsy))))))

(describe "terminal-suite/title-stack-suite"

  (it "screen-title-stack-defaults-nil"
    (with-screen (s 10 5)
      (expect (null (nerimux/terminal/types:screen-title-stack s)))))

  (it "screen-title-stack-push-pop-via-sequences"
    (with-screen (s 10 5)
      (feed s (format nil "~C]2;MyTitle~C\\" #\Escape #\Escape))
      (expect (string= "MyTitle" (nerimux/terminal/types:screen-title s)))
      (feed s (esc "[>0t"))
      (expect (not (null (nerimux/terminal/types:screen-title-stack s))))
      (feed s (format nil "~C]2;NewTitle~C\\" #\Escape #\Escape))
      (expect (string= "NewTitle" (nerimux/terminal/types:screen-title s)))
      (feed s (esc "[<0t"))
      (expect (string= "MyTitle" (nerimux/terminal/types:screen-title s)))))

  (it "screen-title-stack-depth-limit"
    (with-screen (s 10 5)
      (dotimes (_ (+ nerimux/terminal/types:+title-stack-max-depth+ 2))
        (feed s (esc "[>0t")))
      (expect (<= (length (nerimux/terminal/types:screen-title-stack s))
                  nerimux/terminal/types:+title-stack-max-depth+)))))

(describe "terminal-suite/screen-cwd-suite"

  (it "screen-cwd-defaults-empty-string"
    (with-screen (s 10 5)
      (expect (string= "" (nerimux/terminal/types:screen-cwd s)))))

  (it "screen-cwd-can-be-set-directly"
    (with-screen (s 10 5)
      (setf (nerimux/terminal/types:screen-cwd s) "/home/user/project")
      (expect (string= "/home/user/project" (nerimux/terminal/types:screen-cwd s)))))

  (it "screen-cwd-updated-by-osc7"
    (with-screen (s 20 5)
      (feed s (format nil "~C]7;file://localhost/tmp/foo~C\\" #\Escape #\Escape))
      (expect (string/= "" (nerimux/terminal/types:screen-cwd s))))))

(describe "terminal-suite/pending-wrap-suite"

  (it "screen-pending-wrap-defaults-false"
    (with-screen (s 10 5)
      (expect (nerimux/terminal/types:screen-pending-wrap s) :to-be-falsy)))

  (it "screen-pending-wrap-set-when-cursor-at-last-column"
    (with-screen (s 3 2)
      (feed s "abc")
      (expect (nerimux/terminal/types:screen-pending-wrap s) :to-be-truthy)))

  (it "screen-pending-wrap-cleared-on-wrap"
    (with-screen (s 3 2)
      (feed s "abc")
      (expect (nerimux/terminal/types:screen-pending-wrap s) :to-be-truthy)
      (feed s "d")
      (expect (nerimux/terminal/types:screen-pending-wrap s) :to-be-falsy)))

  (it "screen-pending-wrap-cleared-by-cursor-move"
    (with-screen (s 3 2)
      (feed s "abc")
      (feed s (string #\Return))
      (expect (nerimux/terminal/types:screen-pending-wrap s) :to-be-falsy))))

(define-boolean-slot-tests
  nerimux/terminal/types:screen-focus-events
  focus-events-suite
  (feed s (esc "[?1004h"))   ; ?1004h enables focus event reporting
  (feed s (esc "[?1004l"))   ; ?1004l disables focus event reporting
  :suite-description "screen-focus-events: defaults NIL, ?1004h enables, ?1004l disables")

(describe "terminal-suite/g0-g1-charset-suite"

  (it "screen-g0-charset-defaults-ascii"
    (with-screen (s 10 5)
      (expect (eq :ascii (nerimux/terminal/types:screen-g0-charset s)))))

  (it "screen-g1-charset-defaults-ascii"
    (with-screen (s 10 5)
      (expect (eq :ascii (nerimux/terminal/types:screen-g1-charset s)))))

  (it "screen-active-g-defaults-g0"
    (with-screen (s 10 5)
      (expect (eq :g0 (nerimux/terminal/types:screen-active-g s)))))

  (it "screen-g0-charset-designated-by-esc-paren-0"
    (with-screen (s 10 5)
      (feed s (esc "(0"))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-g0-charset s)))))

  (it "screen-g1-charset-designated-by-esc-paren-0"
    (with-screen (s 10 5)
      (feed s (esc ")0"))
      (expect (eq :dec-graphics (nerimux/terminal/types:screen-g1-charset s)))))

  (it "screen-active-g-toggled-by-so-si"
    (with-screen (s 10 5)
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#x0E)))
      (expect (eq :g1 (nerimux/terminal/types:screen-active-g s)))
      (screen-process-bytes s (make-array 1 :element-type '(unsigned-byte 8)
                                            :initial-contents '(#x0F)))
      (expect (eq :g0 (nerimux/terminal/types:screen-active-g s))))))
