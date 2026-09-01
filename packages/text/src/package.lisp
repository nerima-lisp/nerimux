(defpackage #:nerimux/text
            (:use #:cl)
            (:documentation
             "FOUNDATION: string-to-value coercions with no nerimux dependency of any kind.
    Deliberately the first module ASDF loads after the package declarations, so
    every later layer may call it and it can call none of them.

    It exists because these two functions previously lived in the top-level
    NERIMUX package, and five packages across three layers reached up into it as
    NERIMUX::%PARSE-INTEGER-OR-NIL -- a double-colon reference, which bypasses
    both the export list and the DEFPACKAGE form, so no declaration recorded the
    dependency and the layering test could not see it.  Three of those callers
    were also compiled before the file that defined it.")
            (:export #:parse-integer-or-nil #:non-empty-string))
