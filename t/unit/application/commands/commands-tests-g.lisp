(in-package #:nerimux/test)

;;;; command tokenizer, copy-mode find

;;; ── %copy-mode-find-forward / %copy-mode-find-backward ──────────────────────

(defun %copy-mode-find-result (fn width height text term row col)
  (let ((s (make-screen width height)))
    (feed s text)
    (nerimux/commands::copy-mode-enter s)
    (funcall fn s term row col)))

(defun %check-copy-mode-find-case (width height text term case)
  (destructuring-bind (fn srow scol expected-row expected-col desc) case
    (multiple-value-bind (row col)
        (%copy-mode-find-result fn width height text term srow scol)
      (check-table
       (list (list row expected-row
                   (format nil "~A: row (got ~S)" desc row))
             (list col expected-col
                   (format nil "~A: col (got ~S)" desc col)))
       :test #'equal))))

(defmacro define-copy-mode-find-cases (&body cases)
  `(progn
     ,@(loop for (name doc width height text term rows) in cases
             collect
             `(it ,(string-downcase (symbol-name name))
                (dolist (case ',rows)
                  (%check-copy-mode-find-case ,width ,height ,text ,term case))))))

(describe "commands-suite"

  ;;; ── tokenize-command-string (shell-style command lexer) ──────────────────────

  ;; tokenize-command-string splits on whitespace; handles quoted spans, escapes, and unterminated quotes.
  (it "tokenize-command-string-table"
    (dolist (c '(("a b c"          ("a" "b" "c")  "basic whitespace split")
                 ("  a   b  "      ("a" "b")       "leading/trailing collapses")
                 ("   "            ()              "all-whitespace → empty list")
                 ("'a b' c"        ("a b" "c")     "space inside single quotes is literal")
                 ("'a\\b'"         ("a\\b")        "backslash in single quotes is literal")
                 ("''"             ("")            "empty single-quoted token")
                 ("\"a b\""        ("a b")         "space inside double quotes kept")
                 ("\"a\\\"b\""     ("a\"b")        "escaped double-quote inside double quotes")
                 ("a\\ b"          ("a b")         "backslash-space joins one argument")
                 ("a\\b"           ("ab")          "bare backslash-char collapses")
                 ("foo\"bar baz\"" ("foobar baz")  "adjacent spans concatenate")
                 ("'ab'' cd'"      ("ab cd")       "adjacent single-quoted spans join")
                 ("'a b"           ("a b")         "unterminated single quote")
                 ("\"xy"           ("xy")          "unterminated double quote")))
      (destructuring-bind (input expected desc) c
        (declare (ignore desc))
        (expect (equal expected (nerimux/commands:tokenize-command-string input))))))

  ;;; ── %copy-mode-find-forward / %copy-mode-find-backward ──────────────────────

  (define-copy-mode-find-cases
    (copy-mode-find-locates-term
     "%copy-mode-find-forward and %copy-mode-find-backward both find TERM in 'abc def abc'."
     30
     5
     "abc def abc"
     "abc"
     ((nerimux/commands::%copy-mode-find-forward  0 1  0 8 "forward from col 1 finds second 'abc' at col 8")
      (nerimux/commands::%copy-mode-find-backward 0 11 0 8 "backward from col 11 finds 'abc' at col 8")))
    (copy-mode-find-no-match-returns-nil-nil
     "%copy-mode-find-forward and %copy-mode-find-backward both return (values nil nil) when no match exists."
     20
     5
     "hello world"
     "zzz"
     ((nerimux/commands::%copy-mode-find-forward  0 0 nil nil "forward: no match")
      (nerimux/commands::%copy-mode-find-backward 0 5 nil nil "backward: no match")))))
