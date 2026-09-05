(defpackage #:nerimux/test/pty
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
  (:import-from #:nerimux/pty
                #:forkpty-with-shell
                #:pty-write
                #:pty-read-blocking-into
                #:pty-close
                #:select-fds)
  (:import-from #:nerimux/test/ports
                #:with-temporary-posix-environment-variable
                #:with-pipe-fds
                #:write-byte-to-fd
                #:with-stubbed-fdefinition))
