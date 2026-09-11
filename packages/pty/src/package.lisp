(defpackage #:nerimux/pty
  (:use #:cl)
  (:documentation
   "INFRASTRUCTURE layer: the pseudo-terminal device itself.  Forks a shell under a
    PTY, moves octets across the master fd, drives termios raw mode and TIOCSWINSZ
    geometry, and multiplexes readiness with select(2), nerimux needs to poll PTY,
    socket, and stdin fds together, which is the one libc call sb-posix does not
    expose.  Supplies the concrete operations that install-pty-port stores into
    nerimux/ports.")
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
