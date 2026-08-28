(in-package #:nerimux/test)

;;;; Tests for src/domain/text/text-parse.lisp — the FOUNDATION coercions.
;;;;
;;;; These cases used to live in target-suite, because both functions were
;;;; defined in src/domain/model/target.lisp under the top-level NERIMUX package
;;;; and reached from five packages as NERIMUX::%PARSE-INTEGER-OR-NIL.  They moved
;;;; here with the functions.  Nothing about them is target-resolution specific;
;;;; the numeric-index lookups in find-window-by-target / find-pane-by-target are
;;;; one consumer of many.

(describe "text-parse-suite"

  ;;; ── non-empty-string ─────────────────────────────────────────────────────────

  ;; non-empty-string returns the string for non-empty input; NIL for empty string
  ;; or NIL input.
  (it "non-empty-string-table"
    (dolist (row '(("hello" "hello" "non-empty-string of \"hello\" must return itself")
                   (""      nil     "non-empty-string of empty string must return NIL")
                   (nil     nil     "non-empty-string of NIL input must return NIL")
                   (42      nil     "non-empty-string of non-string input must return NIL")))
      (destructuring-bind (input expected desc) row
        (declare (ignore desc))
        (expect (equal expected (nerimux/text:non-empty-string input))))))

  ;;; ── parse-integer-or-nil ─────────────────────────────────────────────────────

  ;; parse-integer-or-nil parses numeric strings, forwards parse-integer keywords,
  ;; and returns NIL for invalid input.
  (it "parse-integer-or-nil-table"
    (dolist (row '(("0"    0   nil                         "zero parses")
                   ("42"   42  nil                         "multi-digit parses")
                   ("-7"   -7  nil                         "signed integers parse")
                   ("1f"   31  (:radix 16)                "hexadecimal parsing works")
                   ("123x" 123 (:end 3)                   "substring parsing works")
                   ("abc"  nil nil                        "alphabetic input returns NIL")
                   (""     nil nil                        "empty string returns NIL")
                   (nil    nil nil                        "NIL input returns NIL")))
      (destructuring-bind (input expected args desc) row
        (declare (ignore desc))
        (expect (eql expected (apply #'nerimux/text:parse-integer-or-nil input args))))))

  ;; The failure paths again, directly rather than through the table, because these
  ;; are the ones every caller relies on: each treats NIL as "absent" and would
  ;; otherwise have to wrap the call in IGNORE-ERRORS itself.
  (it "parse-integer-or-nil-returns-nil-for-non-integer-string"
    (dolist (bad '("" "abc" "1.5" "12abc" " "))
      (expect (null (nerimux/text:parse-integer-or-nil bad)))))

  ;; A non-string argument answers NIL rather than signalling a type error.  Option
  ;; lookups pass through values that may legitimately be absent, so this is load
  ;; bearing, not defensive.
  (it "parse-integer-or-nil-returns-nil-for-nil-input"
    (expect (null (nerimux/text:parse-integer-or-nil nil))))

  (it "parse-integer-or-nil-returns-nil-for-parse-integer-type-error"
    (expect (null (nerimux/text:parse-integer-or-nil "1" :start "not-an-index"))))

  (it "parse-integer-or-nil-parses-valid-integer"
    (dolist (pair '(("0" 0) ("42" 42) ("-3" -3)))
      (destructuring-bind (str expected) pair
        (expect (= expected (nerimux/text:parse-integer-or-nil str)))))))
