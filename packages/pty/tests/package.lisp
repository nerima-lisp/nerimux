;;;; Test package for nerimux-pty.
(defpackage #:nerimux/test/pty
  ;; The test framework is cl-weave, used natively: every file registers its own
  ;; top-level (describe "name" (it "case" ...) ...) block.
  (:use #:cl)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave
                #:it #:it-only #:it-concurrent #:it-sequential
                #:it-each #:describe-each
                #:describe-only #:describe-concurrent #:describe-sequential
                #:expect #:expect-not
                #:signals #:finishes #:fail #:skip
                #:before-each #:after-each #:before-all #:after-all #:around-each
                #:make-mock-function #:with-mocked-functions #:mock-calls
                #:it-property #:it-fuzz #:gen-integer #:gen-list #:gen-boolean #:gen-string
                #:gen-vector #:gen-member #:gen-one-of
                #:defmatcher)
  ;; The unit under test. These were in tests/package.lisp's one shared import
  ;; list; they move with the tests that use them.
  (:import-from #:nerimux/pty
                #:forkpty-with-shell
                #:pty-write
                #:pty-read-blocking-into
                #:pty-close
                #:select-fds)
  ;; Legal because nerimux-pty depends on nerimux-ports: a test package may
  ;; reach only where its own unit could.
  (:import-from #:nerimux/test/ports
                #:with-temporary-posix-environment-variable
                #:with-pipe-fds
                #:write-byte-to-fd
                #:with-stubbed-fdefinition))
