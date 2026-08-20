(in-package #:nerimux/test)

;;;; Configuration defaults, initialization, and parsing tests split from
;;;; config-tests.lisp so the base file can stay focused on direct binding
;;;; lookup and prefix-table invariants.
;;;;
;;;; copy-mode-count-command-p, default-prefix-bindings-table,
;;;; key-table-command-extracts-car, key-tables-copy-mode-table-exists, and
;;;; %bind-prefix-key coverage were removed with the key-table config
;;;; subsystem. prefix-key-code-dynamic-var-defaults-to-constant,
;;;; parse-prefix-key-table, and parse-prefix-key-extended-notations were
;;;; removed with the config prefix-key cluster (+prefix-key-code+,
;;;; *prefix-key-code*, %parse-prefix-key all deleted).

(describe "config-suite"

  ;; The registry default for mode-keys is emacs, matching tmux (vi is autodetected
  ;; from $VISUAL/$EDITOR at startup, not the static default).
  (it "mode-keys-default-is-emacs"
    (with-isolated-config
      (expect (string= "emacs" (nerimux/options:get-option "mode-keys")))
      (expect (string= "emacs" (nerimux/options:get-option "status-keys"))))))
