(in-package #:nerimux/test)

;;;; config directive tests — brace blocks and top-level `;' sequencing.
;;;;
;;;; The bind/unbind key-table-effect tests (multi-token binds, notes,
;;;; brace-block command storage, unbind/-a/-T/-n clearing) were removed with
;;;; the key-table config subsystem.  A `bind'/`unbind' line still parses
;;;; without error — it just has no effect — so the brace-block and
;;;; semicolon-sequencing parser tests below, which never inspect key-table
;;;; state, remain valid coverage of that "parsed but inert" contract.
;;;;
;;;; That justification has to be applied per test, not as a blanket: a test
;;;; whose only signal was `applied = 0' is now vacuous, because every bind line
;;;; returns 0.  See the note where bind-empty-brace-block-rejected used to be.

(describe "config-directives-suite"

  ;; %line-brace-delta nets '{' against '}' and ignores braces inside quotes.
  (it "line-brace-delta-counts-unquoted-braces"
    (dolist (c '((1  "bind r {"                    "open brace is +1")
                 (-1 "}"                           "close brace is -1")
                 (0  "bind r { next-window }"      "balanced block nets 0")
                 (0  "display \"a { b }\""         "braces inside a double-quoted string are ignored")))
      (destructuring-bind (expected input desc) c
        (declare (ignore desc))
        (expect (= expected (nerimux/config::%line-brace-delta input))))))

  ;; bind-empty-brace-block-rejected was removed rather than kept: it asserted
  ;; that `bind r { }' applies nothing, but EVERY bind line applies nothing now,
  ;; so it could no longer distinguish "empty block correctly rejected" from
  ;; "bind never applies anything" -- a regression in the brace logic would have
  ;; passed it. %line-brace-delta above still covers the brace arithmetic against
  ;; a live signal.

  ;;; top-level `;' command-sequence separator on ordinary config lines (tmux parity)

  ;; apply-config-line splits a top-level unescaped `;' into separate command
  ;; sequences and applies each segment in order (tmux command-sequence parity).
  (it "apply-config-line-splits-top-level-semicolons"
    (with-isolated-options ("status" "on" "status-style" "")
      (expect (eq t (nerimux/config::apply-config-line
                     "set-option -g status off ; set-option -g status-style bg=red")))
      (expect (string= "off" (nerimux/options:get-option "status")))
      (expect (string= "bg=red" (nerimux/options:get-option "status-style")))))

  ;; apply-config-line discards empty segments produced by doubled/trailing `;'.
  ;; The separators are whitespace-delimited `;' tokens (an adjacent `;;' is one
  ;; token the tokenizer does not split -- a known limitation).
  (it "apply-config-line-ignores-empty-semicolon-segments"
    (with-isolated-options ("status" "on" "status-style" "")
      (expect (eq t (nerimux/config::apply-config-line
                     "set-option -g status off ; ; set-option -g status-style bg=red ;")))
      (expect (string= "off" (nerimux/options:get-option "status")))
      (expect (string= "bg=red" (nerimux/options:get-option "status-style"))))))
