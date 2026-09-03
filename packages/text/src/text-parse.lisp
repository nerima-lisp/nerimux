(in-package #:nerimux/text)

(defun non-empty-string (string)
  "Return STRING when it is a non-empty string, otherwise NIL."
  (when (and (stringp string) (plusp (length string)))
    string))

(defun parse-integer-or-nil (string &rest args)
  "Parse STRING as an integer and return NIL when parsing fails.

   ARGS are forwarded to PARSE-INTEGER, so :RADIX, :START, :END and
   :JUNK-ALLOWED all work.  A non-string STRING answers NIL rather than
   signalling a type error, which is what lets option lookups pass through a
   value that may legitimately be absent."
  (and (stringp string)
       (handler-case (apply #'parse-integer string args)
         (parse-error ()
           nil)
         (type-error ()
           nil))))
