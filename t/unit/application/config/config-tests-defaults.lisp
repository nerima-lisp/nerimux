(in-package #:nerimux/test)

;;;; Configuration defaults, initialization, and parsing tests split from
;;;; config-tests.lisp so the base file can stay focused on direct binding
;;;; lookup and prefix-table invariants.

;;; ── Import the config symbols we need ────────────────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (import '(nerimux/config:lookup-key-binding
             nerimux/config:describe-key-bindings
             nerimux/config:+prefix-key-code+
            nerimux/config:+table-prefix+
            nerimux/config:+table-root+
            nerimux/config:+table-copy-mode+
            nerimux/config:+table-copy-mode-vi+
            nerimux/config:*prefix-key-code*)))

(describe "config-suite"

  ;;; ── copy-mode-count-command-p ────────────────────────────────────────────────

  ;; copy-mode-count-command-p: T for the motion/scroll commands that honour a
  ;; vi-style numeric count, NIL for commands (and non-commands) that do not.
  (it-each ((:copy-mode-cursor-down    t)
            (:copy-mode-cursor-up      t)
            (:copy-mode-page-down      t)
            (:copy-mode-copy-selection nil)
            (:copy-mode-cancel         nil)
            (:not-a-copy-mode-command  nil))
      "copy-mode-count-command-p ~S → ~A"
      (command expected)
    (expect (eq expected (nerimux/config:copy-mode-count-command-p command))))

  ;;; ── Default prefix bindings and list-keys output ──────────────────────────

  ;; All standard single-char prefix bindings are registered with the correct commands.
  (it "default-prefix-bindings-table"
    (dolist (pair '((#\c :new-window)
                    (#\n :next-window)
                    (#\p :prev-window)
                    (#\o :next-pane)
                    (#\d :detach)
                    (#\? :list-keys)
                    (#\[ :copy-mode-enter)
                    (#\] :paste-buffer)
                    (#\x :kill-pane-confirm)
                    (#\& :kill-window-confirm)
                    (#\, :rename-window)
                    (#\H :resize-left)
                    (#\J :resize-down)
                    (#\K :resize-up)
                    ;; L and ! used to be rebound to :last-session / :break-pane
                    ;; by the extended binding set in presentation/events, which
                    ;; was deleted with the tmux keystroke pipeline.  What the
                    ;; store holds now is the bootstrap default set alone.
                    (#\L :resize-right)
                    (#\$ :rename-session)
                    (#\! :if-shell)))
      (let ((key (first pair))
            (expected (second pair)))
        (expect (eq expected (lookup-key-binding key)))))
    (expect (null (lookup-key-binding #\@)))
    (expect (null (lookup-key-binding #\Z))))

  ;;; describe-key-bindings-has-header, initialize-default-key-tables-idempotent,
  ;;; and table-name-constants used to be duplicated here; the canonical copies
  ;;; (with isolation helpers) live in config-key-table-runtime-tests.lisp.

  ;; key-table-command returns the car of a key-table entry (the command keyword).
  (it "key-table-command-extracts-car"
    (let ((nerimux/config:*key-tables* (make-hash-table :test #'equal)))
      (nerimux/config:key-table-bind "prefix" #\c :new-window)
      (let ((entry (nerimux/config:key-table-lookup "prefix" #\c)))
        (expect (not (null entry)))
        (expect (eq :new-window (nerimux/config:key-table-command entry))))))

  ;; The copy-mode key-tables are created by initialize-default-key-tables.
  (it "key-tables-copy-mode-table-exists"
    (expect (not (null (gethash "copy-mode" nerimux/config:*key-tables*))))
    (expect (not (null (gethash "copy-mode-vi" nerimux/config:*key-tables*)))))

  ;; The registry default for mode-keys is emacs, matching tmux (vi is autodetected
  ;; from $VISUAL/$EDITOR at startup, not the static default).
  (it "mode-keys-default-is-emacs"
    (with-isolated-config
      (expect (string= "emacs" (nerimux/options:get-option "mode-keys")))
      (expect (string= "emacs" (nerimux/options:get-option "status-keys")))))

  ;; *prefix-key-code* defaults to the value of +prefix-key-code+.
  (it "prefix-key-code-dynamic-var-defaults-to-constant"
    (expect (= +prefix-key-code+ nerimux/config:*prefix-key-code*)))

  ;;; ── %parse-prefix-key ────────────────────────────────────────────────────────

  ;; %parse-prefix-key: C-X keys, single chars, and unknown return expected values.
  (it "parse-prefix-key-table"
    (dolist (c '(("C-a"        1   "C-a → 1 (logand 97 #x1f)")
                 ("C-b"        2   "C-b → 2 (logand 98 #x1f, the default prefix)")
                 ("A"          65  "single char 'A' → char-code 65")
                 ("UnknownKey" nil "unknown key name → NIL")))
      (destructuring-bind (input expected desc) c
        (declare (ignore desc))
        (expect (equal expected (nerimux/config::%parse-prefix-key input))))))

  ;; %parse-prefix-key also accepts caret control notation, C-Space/C-@ (NUL), and
  ;; control symbols, while None/Any and named keys (M-/F-keys) parse to NIL so the
  ;; byte event loop never tries to match an unmatchable prefix.
  (it "parse-prefix-key-extended-notations"
    (dolist (c '(("^A"      1   "caret ^A → 1")
                 ("^["      27  "caret ^[ → 27 (Escape byte)")
                 ("C-Space" 0   "C-Space → 0 (NUL)")
                 ("C-@"     0   "C-@ → 0 (NUL)")
                 ("None"    nil "None → NIL (disable, not a byte)")
                 ("Any"     nil "Any → NIL")
                 ("M-a"     nil "M-a → NIL (not single-byte matchable)")
                 ("F1"      nil "F1 → NIL (not single-byte matchable)")))
      (destructuring-bind (input expected desc) c
        (declare (ignore desc))
        (expect (equal expected (nerimux/config::%parse-prefix-key input))))))

  ;; `set-option -g prefix2 None` disables the secondary prefix (NIL); `set-option -g prefix None`
  ;; resets the primary prefix to the default +prefix-key-code+.
  (it "bind-prefix-key-none-disables"
    (let ((nerimux/config:*prefix-key-code*  1)
          (nerimux/config:*prefix2-key-code* 7))
      (nerimux/config::%bind-prefix-key "None" 'nerimux/config::*prefix2-key-code*)
      (expect (null nerimux/config:*prefix2-key-code*))
      (nerimux/config::%bind-prefix-key "None" 'nerimux/config::*prefix-key-code*)
      (expect (= nerimux/config:+prefix-key-code+ nerimux/config:*prefix-key-code*)))))
