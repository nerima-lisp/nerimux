(defpackage #:nerimux/text
  (:use #:cl)
  (:documentation
   "FOUNDATION: dependency-free text helpers available to every higher-level component.")
  (:export #:parse-integer-or-nil
           #:non-empty-string
           #:strip-dot-git-suffix
           #:control-character-p))
