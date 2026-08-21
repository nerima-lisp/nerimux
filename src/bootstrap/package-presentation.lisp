;;; Presentation and input packages.

(defpackage #:nerimux/renderer
  (:use #:cl
        #:nerimux/model #:nerimux/terminal)
  (:import-from #:cl-concurrent-kit #:with-lock-held)
  (:documentation
   "PRESENTATION layer: the only package that writes to the real terminal.  Composites
    every pane's emulator screen, the borders between them, and the status bar into
    one full repaint, emitted as raw ANSI/VT100 escapes with no curses dependency and
    flushed as a single write to avoid tearing.  Also owns style-string parsing and
    the true-colour downsampling used when the outer terminal cannot show 24-bit
    colour.")
  (:export
   #:render-session
   #:render-session-to-string
   #:render-session-to-tui-string
   #:render-workspace-overview-to-string
   #:render-workspace-overview-to-tui-string
   #:clear-display
   #:parse-style-string
   #:style-to-sgr
   ;; Terminal colour-capability downsampling hook; see renderer-format.lisp.
   ;; Nothing installs it now that the startup flag that did was removed, so it
   ;; stays NIL and the renderer emits 24-bit colour unconditionally.
   #:*color-downsample-fn*
   #:%rgb-int-to-256))

;; No :import-from for the sibling kits — input.lisp writes
;; cl-tty-kit:fd-read-octets qualified in full, which is what keeps the
;; descriptor-level surface legible. (It formerly wrote cffi: forms here; cffi
;; is no longer a dependency.)
(defpackage #:nerimux/input
  (:use #:cl
        #:nerimux/config #:nerimux/pty)
  (:documentation
   "INFRASTRUCTURE layer: keyboard input, read from fd 0 rather than from a Lisp
    stream.  A multiplexer has to see each keystroke the moment it arrives and has to
    distinguish 'nothing yet' from end of input, neither of which a buffered stream
    offers — so reads go through select(2) and a one-byte read(2).  Declared beside
    the renderer because it is the input half of the same terminal.")
  (:export
   #:with-raw-mode
   #:read-byte-nonblock))
