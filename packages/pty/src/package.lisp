;; No :import-from for the sibling kits: every descriptor-level operator in
;; src/infrastructure/pty/ is written qualified (cl-tty-kit:, process-kit:,
;; sb-posix:), which is what makes the system-call surface legible. This used to
;; say the same about cffi:, which nerimux no longer depends on.
(defpackage #:nerimux/pty
  (:use #:cl)
  (:documentation
   "INFRASTRUCTURE layer: the pseudo-terminal device itself.  Forks a shell under a
    PTY, moves octets across the master fd, drives termios raw mode and TIOCSWINSZ
    geometry, and multiplexes readiness with select(2) — nerimux needs to poll PTY,
    socket, and stdin fds together, which is the one libc call sb-posix does not
    expose.  Supplies the concrete adapters that install-pty-port stores into
    nerimux/ports.")
  (:export
   ;; PTY lifecycle
   #:forkpty-with-shell    ; (rows cols) → (values master-fd child-pid slave-path)
   #:pty-write             ; (fd data)   — write octets/string to PTY
   #:pty-read-blocking-into ; (fd buffer) → octet-vector or nil; reuses BUFFER
   #:pty-close             ; (fd pid)
   #:pty-child-exit-status ; (fd &optional duration) → (values code :exited|:signaled), signal code NIL
   #:set-pty-size          ; (fd rows cols)
   ;; Terminal raw mode
   #:enable-raw-mode!      ; (fd)
   #:disable-raw-mode!     ; (fd)
   ;; Multiplexed I/O
   #:select-fds            ; (fds timeout-us) → ready-fd-list
   ;; Terminal geometry
   #:terminal-size         ; () → (values rows cols)
   #:+default-term-rows+   ; fallback terminal rows when ioctl fails/is unavailable
   #:+default-term-cols+   ; fallback terminal columns when ioctl fails/is unavailable
   ;; Port adapter (installs nerimux/ports vars at server startup)
   #:install-pty-port))
