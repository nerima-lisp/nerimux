(in-package #:nerimux)

(defmacro %probe-socket-connection (&body body)
  "Classify the result of a socket connection probe by condition kind."
  `(handler-case (progn ,@body)
     (sb-ext:timeout () :timeout)
     (sb-bsd-sockets:socket-error () :socket-error)
     (file-error () :file-error)
     (stream-error () :stream-error)))
