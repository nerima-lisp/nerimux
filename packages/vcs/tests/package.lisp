;;;; Test package for nerimux-vcs.

(defpackage #:nerimux/test/vcs
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
  ;; Legal because nerimux-vcs depends on nerimux-model, which depends on
  ;; nerimux-ports.
  (:import-from #:nerimux/test/ports
                #:with-stubbed-fdefinition)
  ;; The workspace model the adapter reads and writes. Legal because
  ;; nerimux-vcs depends on nerimux-model.
  (:import-from #:nerimux/pane
                #:make-pane
                #:pane-worktree)
  ;; Reached by a root integration test that drives a real repository path.
  (:export #:%vcs-operations-existing-path
           #:%vcs-operations-fake-worktree
           #:%vcs-operations-status-snapshot))
