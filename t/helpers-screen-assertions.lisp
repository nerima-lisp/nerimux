(in-package #:nerimux/test)

;;;; Screen assertion DSL and command-state fixtures.

;;; These macros raise the abstraction level for common screen assertions,
;;; making test intent visible and reducing boilerplate IS calls.

(defmacro check-row (screen y expected-string)
  "Assert that row Y of SCREEN starts with EXPECTED-STRING."
  `(expect (string= ,expected-string
                    (row-string ,screen ,y :end (length ,expected-string)))))

(defmacro check-cell (screen x y &key char fg bg attrs)
  "Assert cell attributes at column X, row Y of SCREEN.
   Only non-NIL keyword arguments are checked."
  (let ((forms '()))
    (when char
      (push `(expect (char= ,char (char-at ,screen ,x ,y))) forms))
    (when fg
      (push `(expect (= ,fg (fg-at ,screen ,x ,y))) forms))
    (when bg
      (push `(expect (= ,bg (bg-at ,screen ,x ,y))) forms))
    (when attrs
      (push `(expect (= ,attrs (attrs-at ,screen ,x ,y))) forms))
    `(progn ,@(nreverse forms))))

(defmacro check-sgr-state (screen &key (fg 7) (bg 0) (attrs 0))
  "Assert the current SGR pen state (foreground, background, attribute bitmask)."
  `(progn
     (expect (= ,fg (nerimux/terminal/types:screen-cur-fg ,screen)))
     (expect (= ,bg (nerimux/terminal/types:screen-cur-bg ,screen)))
     (expect (= ,attrs (nerimux/terminal/types:screen-cur-attrs ,screen)))))

(defmacro with-command-test-state ((sess) &body body)
  "Run BODY with a single-session server state and a clean dirty flag."
  `(let ((nerimux::*server-sessions* (list (cons "0" ,sess)))
         (nerimux::*dirty* nil))
     ,@body))
