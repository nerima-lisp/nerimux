(in-package #:nerimux/test)

(describe "client-suite"

  (it "client-functions-fbound-table"
    (dolist (sym '(nerimux::run-client
                   nerimux::%ensure-server-running
                   nerimux::run-attach-simple))
      (expect (fboundp sym)))))

(defmacro with-client-test-socket-pair ((writer-stream reader-stream) &body
                                                                      body)
  "Create a Unix-domain socket pair: listener→accept→connect.
   WRITER-STREAM and READER-STREAM are bidirectional binary streams.
   Writer side simulates the server sending frames; reader side reads them
   (matches the run-client perspective where the server writes and client reads)."
  (let ((path (gensym "PATH"))
        (lstnr (gensym "LSTNR"))
        (wsock (gensym "WSOCK"))
        (rsock (gensym "RSOCK")))
    `(let ((,path (%test-socket-path "client-dispatch-test")))
       (let ((,lstnr (make-listener ,path)))
         (unwind-protect 
             (let* ((,rsock (connect-to ,path))
                    (,wsock (accept-connection ,lstnr))
                    (,writer-stream (socket-stream ,wsock))
                    (,reader-stream (socket-stream ,rsock)))
               (unwind-protect 
                   (progn
                     ,@body)
                 (ignore-errors (close-socket ,wsock))
                 (ignore-errors (close-socket ,rsock))))
           (ignore-errors (close-socket ,lstnr))
           (ignore-errors (delete-file ,path)))))))

(defmacro with-guarded-socket-test (&body body)
  "Skip unless Unix-domain sockets are available, then run BODY under a 10-second
   timeout inside a socket-pair.  Eliminates the repeated three-line boilerplate:
     (unless (unix-socket-available-p) (skip ...))
     (sb-ext:with-timeout 10 ...)
     (with-client-test-socket-pair ...)
   that appeared in every socket-roundtrip test."
  (let ((server-side (gensym "SERVER-SIDE"))
        (client-side (gensym "CLIENT-SIDE")))
    `(progn
       (unless (unix-socket-available-p)
         (skip "Unix-domain socket unavailable (sandbox)"))
       (sb-ext:with-timeout 10
                            (with-client-test-socket-pair
                             (,server-side ,client-side)
                             (symbol-macrolet ((server-side ,server-side)
                                               (client-side ,client-side))
                               ,@body))))))

(defmacro with-guarded-socket-test/fd ((&key (server-sock (gensym "SSOCK"))
                                             (client-sock (gensym "CSOCK"))
                                             (server-stream (gensym "SSTREAM"))
                                             (client-stream (gensym "CSTREAM"))
                                             (client-fd (gensym "CFD"))) &body
                                                                         body)
  "Like with-guarded-socket-test but exposes socket objects and the client fd.
   Useful when a test needs (nerimux/net:socket-fd client) alongside the stream."
  (let ((path (gensym "PATH"))
        (lstnr (gensym "LSTNR")))
    `(progn
       (unless (unix-socket-available-p)
         (skip "Unix-domain socket unavailable (sandbox)"))
       (sb-ext:with-timeout 10
                            (let* ((,path
                                    (%test-socket-path "client-dispatch-test"))
                                   (,lstnr (make-listener ,path)))
                              (unwind-protect 
                                  (let* ((,client-sock (connect-to ,path))
                                         (,server-sock
                                          (accept-connection ,lstnr))
                                         (,server-stream
                                          (socket-stream ,server-sock))
                                         (,client-stream
                                          (socket-stream ,client-sock))
                                         (,client-fd
                                          (nerimux/net:socket-fd ,client-sock)))
                                    (declare (ignorable ,server-stream
                                                        ,client-stream
                                                        ,client-fd))
                                    (unwind-protect 
                                        (progn
                                          ,@body)
                                      (ignore-errors
                                       (close-socket ,server-sock))
                                      (ignore-errors
                                       (close-socket ,client-sock))))
                                (ignore-errors (close-socket ,lstnr))
                                (ignore-errors (delete-file ,path))))))))
