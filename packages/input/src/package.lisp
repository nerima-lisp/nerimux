;; No :import-from for the sibling kits — input.lisp writes
;; cl-tty-kit:fd-read-octets qualified in full, which is what keeps the
;; descriptor-level surface legible. (It formerly wrote cffi: forms here; cffi
;; is no longer a dependency.)
(defpackage #:nerimux/input
            (:use #:cl #:nerimux/ports #:nerimux/pty)
            (:documentation
             "INFRASTRUCTURE layer: keyboard input, read from fd 0 rather than from a Lisp
    stream.  A multiplexer has to see each keystroke the moment it arrives and has to
    distinguish 'nothing yet' from end of input, neither of which a buffered stream
    offers — so reads go through select(2) and a one-byte read(2).  Declared beside
    the renderer because it is the input half of the same terminal.")
            (:export #:with-raw-mode #:read-byte-nonblock))
