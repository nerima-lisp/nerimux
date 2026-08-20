(in-package #:nerimux/test)

;;;; Config directives tests — part V: macro registry, env-set-p, key-table edge cases, remaining bind/set directives.

(describe "config-directives-suite"

  ;; define-config-directives is a defined macro.
  (it "define-config-directives-macro-is-defined"
    (expect (macro-function 'nerimux/config::define-config-directives)))

  ;; define-key-directive-handlers-macro-is-defined was removed:
  ;; config-directives-bind-dispatch.lisp, which defined
  ;; DEFINE-KEY-DIRECTIVE-HANDLERS, was deleted whole with the key-table
  ;; config subsystem.

  ;; %env-set-p returns T for non-empty strings and NIL for nil or empty strings.
  (it "env-set-p-correctly-classifies-strings"
    (expect (nerimux/config::%env-set-p "/some/path") :to-be-truthy)
    (expect (nerimux/config::%env-set-p "x") :to-be-truthy)
    (expect (nerimux/config::%env-set-p nil) :to-be-falsy)
    (expect (nerimux/config::%env-set-p "") :to-be-falsy))

  ;;; Tokenizer with quote/escape support

  ;; %config-tokens with a double-quoted string produces a single token preserving spaces.
  (it "config-tokenizer-quoted-double-quotes"
    (let ((tokens (nerimux/config::%config-tokens "bind n \"foo bar\"")))
      (expect (equal '("bind" "n" "foo bar") tokens))))

  ;; %config-tokens with a single-quoted string produces a single token.
  (it "config-tokenizer-single-quotes"
    (let ((tokens (nerimux/config::%config-tokens "set-shell '/usr/bin/my shell'")))
      (expect (= 2 (length tokens)))
      (expect (string= "/usr/bin/my shell" (second tokens)))))

  ;; %config-tokens: backslash outside quotes escapes the next character.
  (it "config-tokenizer-backslash-escape"
    ;; The Lisp literal "foo\\ bar" is the 8-char string  foo\ bar  (with a real
    ;; backslash); that is what the tokenizer must collapse to "foo bar".
    (let ((tokens (nerimux/config::%config-tokens "foo\\ bar")))
      (expect (= 1 (length tokens)))
      (expect (string= "foo bar" (first tokens)))))

  ;; %config-tokens: empty double-quotes produces an empty string token.
  (it "config-tokenizer-empty-double-quotes"
    (let ((tokens (nerimux/config::%config-tokens "cmd \"\"")))
      (expect (= 2 (length tokens)))
      (expect (string= "" (second tokens)))))

  ;; %config-tokens: mix of plain tokens, quoted tokens, and backslash escapes.
  (it "config-tokenizer-mixed"
    ;; "a \"b c\" d\\ e" is the literal  a "b c" d\ e  — quoted token preserves the
    ;; inner space; the backslash-space escapes to keep "d e" as one token.
    (let ((tokens (nerimux/config::%config-tokens "a \"b c\" d\\ e")))
      (expect (= 3 (length tokens)))
      (dolist (c '((0 "a"   "first token is a")
                   (1 "b c" "second token is b c")
                   (2 "d e" "third token is d e (backslash-space)")))
        (destructuring-bind (idx expected desc) c
          (declare (ignore desc))
          (expect (string= expected (nth idx tokens)))))))

  ;;; bind/unbind directives with flags
  ;;;
  ;;; bind-key-no-prefix-n-flag, bind-key-repeatable-r-flag,
  ;;; bind-key-custom-table-T-flag, bind-key-simple-also-updates-key-table,
  ;;; unbind-with-n-flag-removes-root-binding, key-directive-aliases-are-rejected,
  ;;; and unbind-with-T-flag-removes-named-table-binding were removed: all
  ;;; asserted key-table effects (key-table-lookup / -command / -repeatable-p,
  ;;; lookup-key-binding), gone with the key-table config subsystem.

  ;;; %whitespace-p
  ;;; NOTE: these directive-store cases are now covered by the table-driven helper below.

  ;; %whitespace-p returns T for space and tab, NIL for other chars.
  (it "whitespace-p-recognizes-space-and-tab"
    (expect (nerimux/config::%whitespace-p #\Space) :to-be-truthy)
    (expect (nerimux/config::%whitespace-p #\Tab) :to-be-truthy)
    (expect (nerimux/config::%whitespace-p #\a) :to-be-falsy)
    (expect (nerimux/config::%whitespace-p #\Newline) :to-be-falsy))

  ;;; %parse-bind-key-args / %parse-unbind-key-args edge cases
  ;;;
  ;;; parse-bind-key-args-empty-returns-nil,
  ;;; parse-bind-key-args-T-flag-missing-table-returns-nil,
  ;;; parse-bind-key-args-unknown-command-returns-nil,
  ;;; parse-bind-key-args-n-and-r-flags-combined,
  ;;; parse-unbind-key-args-empty-returns-nil-nil,
  ;;; parse-unbind-key-args-extra-arg-returns-nil-nil, and
  ;;; parse-unbind-key-args-T-flag-missing-table-returns-nil were removed:
  ;;; config-directives-bind-parse.lisp, which defined %PARSE-BIND-KEY-ARGS
  ;;; and %PARSE-UNBIND-KEY-ARGS, was deleted whole with the key-table config
  ;;; subsystem.

  ;;; Backslash-escape edge case: backslash at end of string

  ;; %config-tokens: backslash at the end of string does not signal an error.
  (it "config-tokenizer-backslash-at-end-of-string"
    (finishes (nerimux/config::%config-tokens "token\\")))

  ;;; load-config-from-string: all-blank and all-comment input

  ;; load-config-from-string with only blanks and comments returns 0.
  (it "load-from-string-blank-input-returns-zero"
    (with-isolated-config
      (let ((applied (load-config-from-string
                      (format nil "# comment~%~%   ~%# another~%"))))
        (expect (= 0 applied)))))

  ;;; bind -r -n combined (order-independent flags)
  ;;;
  ;;; bind-key-r-then-n-flag was removed: it asserted key-table effects
  ;;; (key-table-lookup / -command / -repeatable-p), gone with the key-table
  ;;; config subsystem.
  )
