(in-package #:nerimux/test)

;;;; Runtime key-table state, numeric defaults, and default shell tests.

;;; ── Import the config symbols we need ────────────────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (import '(nerimux/config:lookup-key-binding
            nerimux/config:describe-key-bindings
            nerimux/config:+prefix-key-code+
            nerimux/config:+max-scrollback-lines+
            nerimux/config:+poll-timeout-us+
            nerimux/config:+accept-timeout-us+
            nerimux/config:+pty-buf-size+
            nerimux/config:+pty-poll-timeout-us+)))

(describe "config-suite"

  ;;; ── +max-scrollback-lines+ constant ───────────────────────────────────────

  ;; +max-scrollback-lines+ equals 1000.
  (it "max-scrollback-lines-constant"
    (expect (= 1000 +max-scrollback-lines+)))

  ;;; ── Key-table system tests ────────────────────────────────────────────────

  ;; *key-tables* is populated after load.
  (it "key-tables-initialized"
    (expect (hash-table-p nerimux/config:*key-tables*)))

  ;; The standard key-tables are created by initialize-default-key-tables.
  (it "key-tables-required-tables-exist"
    (dolist (name '("prefix" "root" "copy-mode" "copy-mode-vi"))
      (expect (not (null (gethash name nerimux/config:*key-tables*))))))

  ;; key-table-bind stores a binding retrievable by key-table-lookup in both 'root' and 'prefix' tables.
  (it "key-table-bind-table"
    (dolist (row '(("root"   #\a "root table binding")
                   ("prefix" #\c "prefix table binding")))
      (destructuring-bind (table-name key desc) row
        (declare (ignore desc))
        (with-isolated-key-tables
          (nerimux/config:key-table-bind table-name key :new-window)
          (let ((entry (nerimux/config:key-table-lookup table-name key)))
            (expect (not (null entry)))
            (expect (eq :new-window (nerimux/config:key-table-command entry))))))))

  ;; key-table-bind with :repeatable T marks the entry repeatable; without the flag
  ;; it defaults to not repeatable.  Each row: (key cmd rep expected description).
  (it "key-table-repeatable-flag-variants"
    (dolist (row '((#\r :resize-left t   t   ":repeatable T must be repeatable")
                   (#\c :new-window  nil nil "no :repeatable flag must not be repeatable")))
      (destructuring-bind (key cmd rep expected desc) row
        (declare (ignore desc))
        (with-isolated-key-tables
          (nerimux/config:key-table-bind "prefix" key cmd :repeatable rep)
          (let ((entry (nerimux/config:key-table-lookup "prefix" key)))
            (expect (not (null entry)))
            (expect (eql expected (nerimux/config:key-table-repeatable-p entry))))))))

  ;; key-table-lookup returns NIL for an absent key and for a non-existent table.
  (it "key-table-lookup-missing-returns-nil"
    (let ((nerimux/config:*key-tables* (make-hash-table :test #'equal)))
      (expect (null (nerimux/config:key-table-lookup "prefix"      #\z)))
      (expect (null (nerimux/config:key-table-lookup "nonexistent" #\a)))))

  ;;; ── key-table-repeatable-p nil-safe guard ─────────────────────────────────

  ;; key-table-repeatable-p returns NIL when passed NIL (nil-safe guard).
  (it "key-table-repeatable-p-nil-safe"
    (expect (null (nerimux/config:key-table-repeatable-p nil))))

  ;; key-table-command is the car of the entry; key-table-repeatable-p is nil-safe.
  (it "key-table-command-nil-safe"
    (with-isolated-key-tables
      ;; Absent key returns NIL; nil-safe guard means no error.
      (let ((absent (nerimux/config:key-table-lookup "prefix" #\@)))
        (expect (null absent))
        (expect (null (nerimux/config:key-table-repeatable-p absent))))))

  ;; Timeout and buffer-size constants have the expected values and are all positive.
  (it "numeric-constants"
    (dolist (row `((,+poll-timeout-us+     50000  "+poll-timeout-us+")
                   (,+accept-timeout-us+   100000 "+accept-timeout-us+")
                   (,+pty-buf-size+        4096   "+pty-buf-size+")
                   (,+pty-poll-timeout-us+ 50000  "+pty-poll-timeout-us+")))
      (destructuring-bind (value expected name) row
        (declare (ignore name))
        (expect (= expected value))
        (expect (plusp value)))))

  ;;; ── ensure-key-table side effects ────────────────────────────────────────

  ;; ensure-key-table creates a fresh hash-table for a previously unknown name.
  (it "ensure-key-table-creates-new-table"
    (with-isolated-key-tables
      (let ((tbl (nerimux/config:ensure-key-table "my-table")))
        (expect (hash-table-p tbl))
        (expect (eq tbl (gethash "my-table" nerimux/config:*key-tables*))))))

  ;; ensure-key-table returns the same table on repeated calls.
  (it "ensure-key-table-returns-existing-table"
    (with-isolated-key-tables
      (let* ((tbl1 (nerimux/config:ensure-key-table "my-table"))
             (tbl2 (nerimux/config:ensure-key-table "my-table")))
        (expect (eq tbl1 tbl2)))))

  ;;; ── lookup-key-binding on digit keys ────────────────────────────────────

  ;; The digit characters 0-9 all bind :select-window in the default prefix table.
  (it "lookup-digit-keys-bind-select-window"
    (dolist (d '(#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9))
      (expect (eq :select-window (lookup-key-binding d)))))

  ;;; ── send-prefix binding ──────────────────────────────────────────────────

  ;; The prefix key itself (code-char 2 = C-b) is bound to :send-prefix.
  (it "send-prefix-binding"
    (expect (eq :send-prefix (lookup-key-binding (code-char +prefix-key-code+)))))

  ;;; ── describe-key-bindings header ────────────────────────────────────────

  ;; describe-key-bindings output uses bind-key -T table format (real tmux list-keys format).
  (it "describe-key-bindings-has-header"
    (let ((text (describe-key-bindings)))
      (expect (search "bind-key" text))
      (expect (search "-T" text))))

  ;;; ── initialize-default-key-tables idempotency ─────────────────────────────

  ;; Calling initialize-default-key-tables twice does not duplicate bindings.
  (it "initialize-default-key-tables-idempotent"
    (with-isolated-key-tables
      (nerimux/config::initialize-default-key-tables)
      (let* ((tbl-after-first  (nerimux/config:ensure-key-table "prefix"))
             (count-after-first (hash-table-count tbl-after-first)))
        (nerimux/config::initialize-default-key-tables)
        (let ((count-after-second (hash-table-count tbl-after-first)))
          (expect (= count-after-first count-after-second))))
      (expect (not (null (gethash "root"      nerimux/config:*key-tables*))))
      (expect (not (null (gethash "copy-mode" nerimux/config:*key-tables*))))
      (expect (not (null (gethash "copy-mode-vi" nerimux/config:*key-tables*))))))

  ;;; ── Key-table name constants ──────────────────────────────────────────────

  ;; Standard key-table constants have their expected string values.
  (it "table-name-constants"
    (check-table `((,nerimux/config:+table-prefix+       "prefix"       "+table-prefix+")
                   (,nerimux/config:+table-root+         "root"         "+table-root+")
                   (,nerimux/config:+table-copy-mode+    "copy-mode"    "+table-copy-mode+")
                   (,nerimux/config:+table-copy-mode-vi+ "copy-mode-vi" "+table-copy-mode-vi+"))
                :test #'string=))

  ;;; ── *default-shell* and *status-height* initial values ───────────────────

  ;; *default-shell* is a non-empty string (set from $SHELL or /bin/sh).
  (it "default-shell-is-string"
    (expect (stringp nerimux/config:*default-shell*))
    (expect (plusp (length nerimux/config:*default-shell*))))

  ;; *status-height* is a positive integer (default 1).
  (it "status-height-positive-integer"
    (expect (integerp nerimux/config:*status-height*))
    (expect (plusp nerimux/config:*status-height*)))

  ;;; ── init-default-shell ────────────────────────────────────────────────────

  ;; init-default-shell sets *default-shell* from $SHELL when it is set and
  ;; non-empty.
  (it "init-default-shell-reads-shell-env-var"
    (with-isolated-config
      (with-temporary-posix-environment-variable ("SHELL" "/bin/my-test-shell")
        (nerimux/config:init-default-shell)
        (expect (string= "/bin/my-test-shell" nerimux/config:*default-shell*)))))

  ;; init-default-shell leaves *default-shell* unchanged when $SHELL is unset.
  (it "init-default-shell-ignores-unset-shell-env-var"
    (with-isolated-config
      (with-temporary-posix-environment-variable ("SHELL" nil)
        (let ((before nerimux/config:*default-shell*))
          (nerimux/config:init-default-shell)
          (expect (string= before nerimux/config:*default-shell*)))))))
