(in-package #:nerimux/test)

;;;; config directive suite, tokenizer, and status-height parsing — part III
;;;;
;;;; load-config-file-existing-temp-file, command-keyword-does-not-intern-unknown,
;;;; command-keyword-returns-bindable-keyword,
;;;; command-keyword-rejects-standard-tmux-abbreviations,
;;;; bind-rejects-shorthand-and-stores-canonical-deferred-token-lists,
;;;; command-keyword-rejects-non-bindable-keyword, parse-key-token-table,
;;;; parse-key-token-canonicalizes-multi-modifier-order,
;;;; bind-control-letter-fires-via-control-char,
;;;; bind-modifier-arrow-stores-canonical-string-key,
;;;; bind-n-modifier-arrow-stores-in-root-table,
;;;; bind-plain-arrow-stores-canonical-string-key,
;;;; bind-n-meta-key-stores-in-root-table, and
;;;; apply-config-line-applies-valid-directives were removed: all asserted
;;;; key-table effects (lookup-key-binding / key-table-lookup / key-table-command)
;;;; or exercised %command-keyword / %parse-key-token, both deleted with the
;;;; key-table config subsystem.

(describe "config-directives-suite"

  ;;; %config-tokens (tokenizer)

  ;; %config-tokens splits a line into whitespace-separated tokens.
  (it "config-tokens-splits-on-whitespace"
    (expect (equal '("bind" "c" "new-window")
                   (nerimux/config::%config-tokens "bind c new-window")))
    (expect (equal '("set-shell" "/bin/bash")
                   (nerimux/config::%config-tokens "  set-shell  /bin/bash  ")))
    (expect (null (nerimux/config::%config-tokens "")))
    (expect (null (nerimux/config::%config-tokens "   "))))

  ;;; status option: off / on / line-count parsing → nerimux/options:status-line-count

  ;; `set-option -g status` maps string values to the expected status height.
  (it "set-status-directive-table"
    (dolist (case '(("off" 0 "status off → height 0")
                    ("0" 0 "status 0 → height 0")
                    ("on" 1 "status on → height 1")
                    ("2" 2 "status 2 must reserve 2 rows")
                    ("5" 5 "status 5 → 5 rows")
                    ("9" 5 "status 9 → clamped to 5 rows")))
      (destructuring-bind (value expected desc) case
        (declare (ignore desc))
        (with-isolated-config
          (nerimux/config:apply-config-directive (list "set-option" "-g" "status" value))
          (expect (= expected (nerimux/options:status-line-count)))))))

  ;;; apply-config-line

  ;; apply-config-line returns NIL for blank lines and # comments.
  (it "apply-config-line-ignores-blank-and-comments"
    (expect (null (nerimux/config::apply-config-line "")))
    (expect (null (nerimux/config::apply-config-line "   ")))
    (expect (null (nerimux/config::apply-config-line "# this is a comment")))))
