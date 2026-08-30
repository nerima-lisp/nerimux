(in-package #:nerimux/text)

;;;; String-to-value coercions shared by every layer.
;;;;
;;;; Both functions are total: they answer NIL rather than signalling, so callers
;;;; can write (or (parse-integer-or-nil s) default) instead of wrapping each
;;;; call in IGNORE-ERRORS.  That total-ness is the whole point -- the option
;;;; registry, the OSC colour parser, and the format-modifier reader all treat
;;;; unparseable input as absent rather than as an error.

(defun non-empty-string (string)
  "Return STRING when it is a non-empty string, otherwise NIL."
  (when (and (stringp string) (plusp (length string))) string))

(defun parse-integer-or-nil (string &rest args)
  "Parse STRING as an integer and return NIL when parsing fails.

   ARGS are forwarded to PARSE-INTEGER, so :RADIX, :START, :END and
   :JUNK-ALLOWED all work.  A non-string STRING answers NIL rather than
   signalling a type error, which is what lets option lookups pass through a
   value that may legitimately be absent."
  (and (stringp string)
       (handler-case (apply #'parse-integer string args)
         (parse-error () nil)
         (type-error () nil))))
