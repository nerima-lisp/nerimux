(defpackage #:nerimux/test/vcs
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
  (:import-from #:nerimux/test/ports
                #:with-stubbed-fdefinition)
  (:import-from #:nerimux/pane
                #:make-pane
                #:pane-worktree)
  (:export #:%vcs-operations-existing-path
           #:%vcs-operations-fake-worktree
           #:%vcs-operations-status-snapshot))
