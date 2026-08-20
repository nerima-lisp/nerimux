(in-package #:nerimux/test)

;;;; set-g-status-off, load-config patterns, bare-arg-cmds, %elif, line-continuation, comments, styles — part IV

(describe "config-directives-suite"

  ;; ── set-option -g status off side-effect ────────────────────────────────────────────

  ;; 'set-option -g status off' → *status-height* 0; 'on' → 1.
  (it "apply-set-directive-status-table"
    (dolist (c '(("off" 0 "'set-option -g status off' sets *status-height* to 0")
                 ("on"  1 "'set-option -g status on' sets *status-height* to 1")))
      (destructuring-bind (value expected desc) c
        (declare (ignore desc))
        (let ((orig nerimux/config:*status-height*))
          (unwind-protect
              (progn
                (setf nerimux/config:*status-height* 0)
                (nerimux/config:apply-config-directive (list "set-option" "-g" "status" value))
                (expect (= expected nerimux/config:*status-height*)))
            (setf nerimux/config:*status-height* orig))))))

  ;; bind-n-split-window-with-c-flag and bind-key-semicolon-sequence-stored-as-sequence
  ;; were removed: both asserted key-table effects (key-table-lookup / -command),
  ;; gone with the key-table config subsystem.

  ;; ── Common .tmux.conf patterns ───────────────────────────────────────────────

  ;; Common .tmux.conf patterns load without error.
  (it "load-config-common-patterns-no-error"
    (with-isolated-config
      (let ((common-config
             "set-option -g prefix C-a
set-option -g mouse on
set-option -g base-index 1
set-window-option -g pane-base-index 1
set-option -g default-terminal \"screen-256color\"
set-option -g escape-time 0
set-option -g history-limit 50000
set-option -g renumber-windows on
set-option -g mode-keys vi
bind r source-file /dev/null \; display-message \"Reloaded\"
bind -T copy-mode-vi v send-keys -X begin-selection
bind -T copy-mode-vi y send-keys -X copy-selection
bind '\"' split-window -c #{pane_current_path}
bind % split-window -h -c #{pane_current_path}
bind c new-window -c #{pane_current_path}
unbind-all
bind r source-file /dev/null"))
        ;; The previous assertion here was
        ;;   (expect (zerop (multiple-value-bind (result) (ignore-errors ...)
        ;;                    (declare (ignore result)) 0)))
        ;; which reduces to (zerop 0) -- always true, with ignore-errors
        ;; swallowing any signal. It could not fail, whatever the loader did.
        ;; The nine set-option/set-window-option lines above apply; the eight
        ;; bind/unbind-all lines no longer reach a handler and apply nothing.
        ;; Asserting that count both pins the "parsed but inert" contract and
        ;; fails loudly if loading ever signals.
        (expect (= 9 (nerimux/config:load-config-from-string common-config))))))

  ;; load-config-bind-T-copy-mode-vi-stores-correctly was removed: it asserted
  ;; a key-table effect (key-table-lookup / -command), gone with the
  ;; key-table config subsystem.

  ;; 'set-option -s escape-time 0' stores in server options.
  (it "load-config-set-g-escape-time-stores-as-server-option"
    (with-isolated-config
      (nerimux/config:load-config-from-string "set-option -s escape-time 0")
      (expect (eql 0 (nerimux/options:get-server-option "escape-time")))))

  ;; 'set-option -u status' in a config file removes the option and restores the runtime
  ;; status height to its default.
  (it "load-config-set-u-restores-status-side-effects"
    (with-isolated-config
      (setf nerimux/config:*status-height* 4)
      (nerimux/config:load-config-from-string
       "set-option -g status off
set-option -u status")
      (expect (= 1 nerimux/config:*status-height*))
      (expect (null (nth-value 1 (gethash "status" nerimux/options:*global-options*))))
      (expect (string= "on" (nerimux/options:get-option "status")))))

  ;; ── Bare arg-command shorthand rejection in bind (single-token path) ────────
  ;;
  ;; `bind X <command> args` (multi-token) already works — it is stored
  ;; unvalidated as a deferred token list.  A BARE `bind X <shorthand>` (single
  ;; token) goes through %command-keyword, and the named-buffer family uses
  ;; canonical command names only.

  ;; config-bind-rejects-named-buffer-shorthand-single-tokens was removed: it
  ;; asserted a key-table effect (lookup-key-binding), gone with the
  ;; key-table config subsystem.

  ;; Rejected shorthand spellings do not weaken typo rejection: an unknown
  ;; single-token command is still refused.
  (it "config-bind-rejects-unknown-single-token-still"
    (with-isolated-config
      (expect (= 0 (nerimux/config:load-config-from-string "bind X totally-bogus-cmd")))))

  ;; load-realistic-tmux-conf-with-canonical-commands was removed: it asserted
  ;; key-table effects (lookup-key-binding / key-table-lookup), gone with the
  ;; key-table config subsystem.

  ;; ── %elif chains (4-state cond stack) ────────────────────────────────────────
  ;;
  ;; A plain skip flag mishandles %elif after a matched branch.  These exercise the
  ;; :active/:seeking/:taken/:dead state machine.  The identity evaluator makes the
  ;; condition "1" truthy and "0" falsy.

  ;; The %if/%elif/%else state machine picks exactly the first matching branch.
  (it "config-if-elif-else-state-machine-table"
    ;; The payload directive must be one that still APPLIES; `bind` no longer
    ;; does, so it would count 0 in every branch and the table could not tell a
    ;; taken branch from a skipped one.  set-option is used purely as a
    ;; countable payload -- the subject under test is the branch state machine.
    (dolist (c '(("%if 1~%set-option -g status on~%%elif 1~%set-option -g status off~%%endif~%"
                  1 "if=1 elif=1: only if-branch")
                 ("%if 0~%set-option -g status on~%%elif 1~%set-option -g status off~%%endif~%"
                  1 "if=0 elif=1: elif-branch applies")
                 ("%if 0~%set-option -g status on~%%elif 0~%set-option -g status off~%%else~%set-option -g escape-time 10~%%endif~%"
                  1 "if=0 elif=0: else-branch applies")
                 ("%if 0~%set-option -g status on~%%elif 0~%set-option -g status off~%%elif 1~%set-option -g escape-time 10~%%else~%set-option -g escape-time 20~%%endif~%"
                  1 "elif chain: first true elif wins")
                 ("%if 1~%set-option -g status on~%%elif 1~%set-option -g status off~%%else~%set-option -g escape-time 10~%%endif~%"
                  1 "if=1 with elif+else: only if-branch")
                 ("%if 0~%%if 1~%set-option -g status on~%%elif 1~%set-option -g status off~%%endif~%%endif~%"
                  0 "nested if in dead outer branch stays dead")))
      (destructuring-bind (config-str expected desc) c
        (declare (ignore desc))
        (with-isolated-config
          (let ((nerimux/config:*config-condition-evaluator* (lambda (x) x)))
            (expect (= expected (nerimux/config:load-config-from-string
                                 (format nil config-str)))))))))

  ;; ── Line continuation (trailing backslash) ───────────────────────────────────

  ;; %line-continues-p is T for an odd number of trailing backslashes.
  (it "line-continues-p-counts-trailing-backslashes"
    (expect (nerimux/config::%line-continues-p "foo \\") :to-be-truthy)
    (expect (nerimux/config::%line-continues-p "foo \\\\") :to-be-falsy)
    (expect (nerimux/config::%line-continues-p "foo \\\\\\") :to-be-truthy)
    (expect (nerimux/config::%line-continues-p "foo") :to-be-falsy)
    (expect (nerimux/config::%line-continues-p "") :to-be-falsy))

  ;; A line ending in a single backslash continues onto the next line, forming one
  ;; directive.
  (it "config-line-continuation-joins-directive"
    (with-isolated-config
      (expect (= 1 (nerimux/config:load-config-from-string
                    (format nil "set-option -g \\~%status on"))))))

  ;; Without a trailing backslash, two lines remain two separate directives.
  (it "config-no-continuation-two-lines-two-directives"
    (with-isolated-config
      (expect (= 2 (nerimux/config:load-config-from-string
                    (format nil "set-option -g status on~%set-option -g escape-time 10"))))))

  ;; %glob-pattern-p is true for * ? [ metacharacters; NIL for plain paths.
  (it "glob-pattern-p-detects-metacharacters"
    (dolist (row '(("/etc/*.conf"    t   "* is a glob metacharacter")
                   ("/etc/foo?.conf" t   "? is a glob metacharacter")
                   ("/etc/[ab].conf" t   "[ is a glob metacharacter")
                   ("/etc/foo.conf"  nil "plain path has no glob metacharacters")))
      (destructuring-bind (path expected desc) row
        (declare (ignore desc))
        (if expected
            (expect (nerimux/config::%glob-pattern-p path) :to-be-truthy)
            (expect (nerimux/config::%glob-pattern-p path) :to-be-falsy)))))

  ;; ── # comment handling (inline, quote- and format-aware) ─────────────────────

  ;; %strip-config-comment removes a comment only outside quotes and not for #{/##.
  (it "strip-config-comment-respects-quotes-and-formats"
    (dolist (c '(("set-option -g foo bar # note"    "set-option -g foo bar"           "inline comment stripped")
                 ("# full line"              ""                         "full-line comment → empty")
                 ("set x \"#{session_name}\"" "set x \"#{session_name}\"" "# inside double quotes kept")
                 ("set x '# literal'"       "set x '# literal'"        "# inside single quotes kept")
                 ("set x #{session_name}"   "set x #{session_name}"    "unquoted #{ format kept")
                 ("set x ##y"              "set x ##y"                 "## escaped-literal not a comment")
                 ("set x bar"              "set x bar"                 "no comment → unchanged")))
      (destructuring-bind (input expected desc) c
        (declare (ignore desc))
        (expect (string= expected (nerimux/config::%strip-config-comment input))))))

  ;; An inline # comment is stripped before the directive is applied.
  (it "config-inline-comment-not-in-value"
    (with-isolated-options ()
      (nerimux/config:load-config-from-string "set-option -g status-left foo # a comment")
      (expect (string= "foo" (nerimux/options:get-option "status-left")))))

  ;; A #{...} inside a quoted value survives (not treated as a comment).
  (it "config-quoted-hash-preserved-in-value"
    (with-isolated-options ()
      (nerimux/config:load-config-from-string "set-option -g status-left \"#{session_name}\"")
      (expect (string= "#{session_name}" (nerimux/options:get-option "status-left")))))

  ;; config-brace-block-inner-comment-preserved was removed: it asserted a
  ;; key-table effect (key-table-lookup / -command), gone with the key-table
  ;; config subsystem.

  ;; ── Mid-token '#' is a literal, not a comment ────────────────────────────────
  ;;
  ;; tmux's lexer only begins a comment when '#' is the first character of a token
  ;; (line start or just after whitespace).  A '#' in the middle of an unquoted
  ;; word — most commonly a hex colour like bg=#0000ff — is a literal character.
  ;; Previously %strip-config-comment truncated such values to "bg=".

  ;; A '#' in the middle of an unquoted token is literal; only a token-start '#'
  ;; begins a comment.
  (it "strip-config-comment-keeps-mid-token-hash"
    (dolist (c '(("set-option -g status-style bg=#0000ff"                 "set-option -g status-style bg=#0000ff" "mid-token hex colour kept verbatim")
                 ("set-option -g @c fg=#ff0000"                           "set-option -g @c fg=#ff0000"           "mid-token hex in a user (@) option kept")
                 ("set-option -g status-style bg=#0000ff # trailing note" "set-option -g status-style bg=#0000ff" "mid-token hex kept AND a real trailing comment still stripped")
                 ("set-option -g foo #bar"                                "set-option -g foo"                     "a '#' at a token start (after whitespace) still begins a comment")))
      (destructuring-bind (input expected desc) c
        (declare (ignore desc))
        (expect (string= expected (nerimux/config::%strip-config-comment input))))))

  ;; End-to-end: an unquoted hex colour survives apply-config-line into the option
  ;; value (it used to be truncated by comment stripping).
  (it "apply-config-line-keeps-hash-colour-end-to-end"
    (with-isolated-options ("status-style" "")
      (nerimux/config::apply-config-line "set-option -g status-style bg=#1e1e1e")
      (expect (string= "bg=#1e1e1e" (nerimux/options:get-option "status-style")))))

  ;; ── set-option -ag on style options inserts a ',' separator ─────────────────────────
  ;;
  ;; tmux marks *-style options OPTIONS_TABLE_IS_STYLE; `set-option -a` appends to them
  ;; with a comma so incremental theming (bg first, fg later) composes.  Plain
  ;; string options keep separator-less concatenation.

  ;; 'set-option -ag <name>-style v' comma-joins; plain string options still concat.
  (it "apply-set-directive-append-style-comma"
    ;; Style option with a non-empty current value: comma-joined.
    (with-isolated-options ("status-style" "bg=red")
      (assert-set-directive-option-state '("set-option" "-ag" "status-style" "fg=blue")
                                         "status-style" "bg=red,fg=blue"
                                         :context "set-option -ag status-style fg=blue"))
    ;; Style option appended onto an empty value: no leading comma.
    (with-isolated-options ("mode-style" "")
      (apply-config-directive '("set-option" "-ag" "mode-style" "fg=green"))
      (expect (string= "fg=green" (nerimux/options:get-option "mode-style"))))
    ;; Non-style string option: still plain (no comma).
    (with-isolated-options ("status-left" "A")
      (apply-config-directive '("set-option" "-ag" "status-left" "B"))
      (expect (string= "AB" (nerimux/options:get-option "status-left"))))))
