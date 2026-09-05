(in-package #:nerimux)

(defmacro %with-unavailable-socket-as-nil (&body body)
  `(handler-case (progn ,@body)
     (sb-ext:timeout () nil)
     (sb-bsd-sockets:socket-error () nil)
     (file-error () nil)
     (stream-error () nil)))
