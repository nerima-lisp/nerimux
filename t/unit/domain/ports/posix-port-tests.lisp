(in-package #:nerimux/test)

(describe "posix-port"
  (it "environment-value returns the value of a variable set in the real process environment"
    (with-temporary-posix-environment-variable ("NERIMUX_PORTS_TEST_ENV_VALUE" "sentinel-value")
      (expect (string= "sentinel-value"
                        (nerimux/ports:environment-value "NERIMUX_PORTS_TEST_ENV_VALUE")))))

  (it "environment-value returns NIL for a variable that is definitely unset"
    (expect (null (nerimux/ports:environment-value
                   "__NERIMUX_PORTS_DEFINITELY_UNSET_VAR__"))))

  (it "environment-entries returns well-formed NAME=VALUE entries including one set via the helper"
    (with-temporary-posix-environment-variable ("NERIMUX_PORTS_TEST_ENTRIES_VAR" "entries-value")
      (let ((entries (nerimux/ports:environment-entries)))
        (expect (consp entries))
        (expect (every (lambda (entry) (and (stringp entry) (find #\= entry))) entries))
        (expect (member "NERIMUX_PORTS_TEST_ENTRIES_VAR=entries-value" entries
                        :test #'string=)))))

  (it "working-directory names the real process cwd once SB-POSIX is loaded"
    ;; nerimux/test depends on the "nerimux" system, and
    ;; src/infrastructure/pty/pty-ffi.lisp unconditionally (require :sb-posix)s
    ;; at load time (pty.lisp calls sb-posix:kill/close). SB-POSIX is therefore
    ;; already loaded by the time any test runs, so this pins the
    ;; SB-POSIX-present branch specifically -- not the "absent" branch, which
    ;; only occurs in a REPL or harness that never loaded the nerimux system.
    (let ((cwd (nerimux/ports:working-directory)))
      (expect (stringp cwd))
      (expect (plusp (length cwd)))
      (expect (probe-file cwd) :to-be-truthy)
      (expect (string= cwd (sb-posix:getcwd)))))

  (it "find-posix-function returns a fbound symbol for a name SB-POSIX really exports"
    (let ((fn (nerimux/ports:find-posix-function "SETENV")))
      (expect fn)
      (expect (fboundp fn) :to-be-truthy)
      (expect (eq fn (find-symbol "SETENV" "SB-POSIX")))))

  (it "find-posix-function returns NIL for a name SB-POSIX does not export"
    (expect (null (nerimux/ports:find-posix-function
                   "NERIMUX-PORTS-NONSENSE-SYMBOL-XYZZY-QUX")))))
