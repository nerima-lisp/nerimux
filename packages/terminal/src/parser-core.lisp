(in-package #:nerimux/terminal/parser)

(declaim (inline printable-ascii-p))

(defun printable-ascii-p (byte)
  "Return T when BYTE is in the printable ASCII range #x20-#x7E (space through tilde)."
  (and (>= byte #x20) (< byte #x7F)))

(defmacro define-state (name (screen-var byte-var) &rest rules)
  "Define a Prolog-like CPS parser state with one rule per state clause."
  `(defun ,name (,screen-var ,byte-var)
     ,(format nil
              "CPS parser state ~(~A~): (screen byte) -> next-state-function.~%   ~
                   Dispatches on BYTE across ~D rule~:P defined via DEFINE-STATE."
              name
              (length rules))
     (declare (type screen ,screen-var)
              (type (unsigned-byte 8) ,byte-var)
              (ignorable ,screen-var ,byte-var))
     (cond
       ,@(mapcar
          (lambda (rule)
            (destructuring-bind (pattern &rest body) rule
              `(,(cond
                   ((eq pattern 't) 't)
                   ((integerp pattern) `(= ,byte-var ,pattern))
                   ((symbolp pattern) `(,pattern ,byte-var))
                   (t pattern)) ,@body)))
          rules))))
