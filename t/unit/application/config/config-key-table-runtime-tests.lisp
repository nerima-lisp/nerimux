(in-package #:nerimux/test)

;;;; Numeric defaults and default-shell tests.
;;;;
;;;; Runtime key-table state tests (key-table-bind/-lookup/-repeatable-p,
;;;; ensure-key-table, initialize-default-key-tables, table-name-constants)
;;;; were removed with the key-table config subsystem.

;;; ── Import the config symbols we need ────────────────────────────────────

;; +max-scrollback-lines+ is deliberately NOT in this import list: t/package.lisp
;; (out of scope for this migration) still does
;; (:import-from #:nerimux/config #:+max-scrollback-lines+), which pulls the old,
;; now-unexported, orphaned constant of that name from nerimux/config into
;; NERIMUX/TEST unqualified.  Importing nerimux/terminal:+max-scrollback-lines+
;; under the same bare name here would collide with that inherited symbol
;; (two distinct symbols, same print name, both homed in NERIMUX/TEST) and abort
;; compilation.  Reference the moved constant fully qualified instead.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (import '(nerimux/config:+poll-timeout-us+
            nerimux/config:+accept-timeout-us+
            nerimux/config:+pty-buf-size+
            nerimux/config:+pty-poll-timeout-us+)))

(describe "config-suite"

  ;;; ── +max-scrollback-lines+ constant ───────────────────────────────────────

  ;; +max-scrollback-lines+ equals 1000.
  (it "max-scrollback-lines-constant"
    (expect (= 1000 nerimux/terminal:+max-scrollback-lines+)))

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

  ;;; ── *default-shell* and status-line-count initial values ──────────────────

  ;; *default-shell* is a non-empty string (set from $SHELL or /bin/sh).
  (it "default-shell-is-string"
    (expect (stringp (nerimux/options:get-option "default-shell")))
    (expect (plusp (length (nerimux/options:get-option "default-shell")))))

  ;; nerimux/options:status-line-count is a positive integer (default 1).
  (it "status-line-count-positive-integer"
    (expect (integerp (nerimux/options:status-line-count)))
    (expect (plusp (nerimux/options:status-line-count))))

  ;;; ── init-default-shell ────────────────────────────────────────────────────

  ;; init-default-shell sets *default-shell* from $SHELL when it is set and
  ;; non-empty.
  (it "init-default-shell-reads-shell-env-var"
    (with-isolated-config
      (with-temporary-posix-environment-variable ("SHELL" "/bin/my-test-shell")
        (nerimux/config:init-default-shell)
        (expect (string= "/bin/my-test-shell" (nerimux/options:get-option "default-shell"))))))

  ;; init-default-shell leaves the `default-shell' option unchanged when $SHELL is unset.
  (it "init-default-shell-ignores-unset-shell-env-var"
    (with-isolated-config
      (with-temporary-posix-environment-variable ("SHELL" nil)
        (let ((before (nerimux/options:get-option "default-shell")))
          (nerimux/config:init-default-shell)
          (expect (string= before (nerimux/options:get-option "default-shell"))))))))
