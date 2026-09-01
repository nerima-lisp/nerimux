;;;; Test package for nerimux-ports.
(defpackage #:nerimux/test/ports
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
  ;; Fixtures the units above ports, and the root suite, reach for.
  ;;
  ;; They live here rather than beside their callers because ports is the lowest
  ;; unit every caller depends on -- model, pty and input all name nerimux-ports,
  ;; and the root suite sits above everything. Exporting them is what turns "the
  ;; model tests use a POSIX fixture" into a declaration instead of an accident
  ;; of one shared test package.
  ;;
  ;; Neither fixture uses nerimux-ports itself; the placement is about
  ;; reachability, not about subject matter.
  (:export #:with-temporary-posix-environment-variable
           #:with-stubbed-fdefinition
           #:with-pipe-fds
           #:write-octets-to-fd
           #:write-byte-to-fd
           #:read-octets-from-fd))
