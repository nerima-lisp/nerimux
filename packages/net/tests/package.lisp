;;;; Test package for nerimux-net.

(defpackage #:nerimux/test/net
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
  ;; list; they move with the tests that use them. WITH-INCOMING-FRAME in
  ;; particular is a macro, so an unimported name is not a missing function at
  ;; run time -- its rule clauses read as function calls and the file fails to
  ;; compile, which is how the omission surfaced.
  (:import-from #:nerimux/protocol
                #:+msg-attach+ #:+msg-key+ #:+msg-resize+
                #:+msg-detach+ #:+msg-frame+ #:+msg-bye+ #:+msg-command+ #:+msg-reply+
                #:+header-size+
                #:encode-frame #:decode-frame
                #:msg-attach #:msg-key #:msg-resize #:msg-detach #:msg-frame #:msg-bye
                #:msg-command #:msg-reply
                #:encode-command-payload #:decode-command-payload
                #:u16-octets-pair
                #:decode-size #:decode-text #:to-octets)
  (:import-from #:nerimux/transport
                #:send-frame #:read-frame #:with-incoming-frame)
  (:import-from #:nerimux/net
                #:make-listener #:accept-connection #:connect-to
                #:socket-stream #:socket-fd #:close-socket
                #:unix-socket-available-p)
  ;; Reached by the root suite's integration tests, which drive a real listener.
  ;; nerimux-net depends on no other unit, so nothing is imported here: every
  ;; fixture this unit needs is defined inside it.
  (:export #:%test-socket-directory
           #:%test-socket-path
           #:with-test-listener
           #:with-temp-octet-file
           #:with-output-octet-stream
           #:write-frames-to-file
           #:round-trip-frame
           #:assert-round-tripped-frame-type
           #:assert-round-tripped-frame-payload
           #:assert-decoded-frame-type
           #:assert-decoded-frame-payload
           #:write-partial-frame-to-file
           #:with-temp-socket-path
           #:with-connected-sockets))
