(defpackage #:nerimux/text
            (:use #:cl)
            (:documentation
             "FOUNDATION: dependency-free string-to-value coercions.  This foundational
    package is available to every higher-level component and has no dependency
    on the application package.")
            (:export #:parse-integer-or-nil #:non-empty-string))
