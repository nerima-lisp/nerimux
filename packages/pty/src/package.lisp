(defpackage #:nerimux/pty
  (:use #:cl)
  (:documentation
   "INFRASTRUCTURE layer for pseudo-terminal operations. It starts shell
    processes under PTYs, moves octets across PTY master fds, manages terminal
    mode and size, and provides the fd selector used to poll PTY, socket, and
    stdin descriptors together. SELECT-FDS returns readable descriptors as its
    first value for compatibility. With :WRITE-FDS, it also returns writable
    descriptors as its second value.")
  (:export
   #:forkpty-with-shell
   #:pty-write
   #:pty-read-blocking-into
   #:pty-close
   #:pty-child-exit-status
   #:set-pty-size
   #:enable-raw-mode!
   #:disable-raw-mode!
   #:select-fds
   #:terminal-size
   #:+default-term-rows+
   #:+default-term-cols+
   #:install-pty-port))
