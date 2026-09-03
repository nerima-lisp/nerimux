(defpackage #:nerimux/test/net
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
