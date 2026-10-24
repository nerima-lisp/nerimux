(in-package #:nerimux/text)

(defun non-empty-string (string)
  "Return STRING when it is a non-empty string, otherwise NIL."
  (when (and (stringp string) (plusp (length string)))
    string))

(defun strip-dot-git-suffix (name)
  "NAME with a trailing \".git\" removed (case-insensitively), unless NAME
   is nothing but \".git\" itself -- in which case stripping it would leave
   an empty label, so NAME is returned unchanged."
  (if (and (> (length name) 4)
           (string-equal name ".git" :start1 (- (length name) 4)))
      (subseq name 0 (- (length name) 4))
      name))

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

(defun control-character-p (character)
  "Return true for terminal controls and bidi formatting marks that alter displayed text."
  (let ((code (char-code character)))
    (or (< code 32)
        (<= 127 code 159)
        (= code #x061c)
        (<= #x200e code #x200f)
        (<= #x202a code #x202e)
        (<= #x2066 code #x2069))))
