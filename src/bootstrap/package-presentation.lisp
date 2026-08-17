;;; Presentation and input packages.

(defpackage #:cl-tmux/prompt
  (:use #:cl)
  (:documentation
   "PRESENTATION layer: the transient interactive UI that sits on top of the panes.
    Four kinds of overlay share the package because at most one of them is up at a
    time and the renderer draws them from the same pass — the single-line command
    prompt with its editing, history, and vi-normal state; message and list overlays;
    popups running their own pane; and menus.  Holds state and edit operations only:
    deciding what a submitted prompt means is the event layer's job.")
  (:export
   #:prompt #:make-prompt #:prompt-p
   #:prompt-label #:prompt-buffer #:prompt-cursor-index #:prompt-on-submit
   #:prompt-on-change #:prompt-on-cancel #:prompt-numeric-only
   #:prompt-close-on-focus-out #:prompt-clear
   #:prompt-vi-normal-p #:prompt-single-key
   #:with-active-prompt
   #:*prompt* #:prompt-active-p #:prompt-start
   #:prompt-input #:prompt-backspace #:prompt-clear #:prompt-text
   #:prompt-notify-change
   #:prompt-cursor-bol #:prompt-cursor-eol
   #:prompt-cursor-back #:prompt-cursor-forward
   #:prompt-kill-to-end #:prompt-kill-to-start #:prompt-kill-word-back
   #:prompt-history-prev #:prompt-history-next
   #:prompt-delete-char
   #:*overlay* #:*overlay-scroll-offset* #:*display-panes-active*
   #:overlay-active-p #:overlay-shown-at #:show-overlay #:show-transient-overlay
   #:show-display-panes-overlay
   #:clear-overlay #:overlay-lines
   #:overlay-scroll #:*overlay-shown-at*
   #:+default-popup-width+ #:+default-popup-height+
   #:popup #:make-popup #:popup-p
   #:popup-width #:popup-height
   #:popup-screen #:popup-pane #:popup-title #:popup-close-on-exit
   #:*active-popup*
   #:show-popup #:close-popup #:popup-active-p
   #:menu #:make-menu #:menu-p
   #:menu-title #:menu-items #:menu-selected-index
   #:menu-x #:menu-y
   #:menu-keep-open
   #:*active-menu*
   #:show-menu #:close-menu #:menu-active-p))

(defpackage #:cl-tmux/renderer
  (:use #:cl
        #:cl-tmux/model #:cl-tmux/terminal #:cl-tmux/prompt)
  (:import-from #:cl-concurrent-kit #:with-lock-held)
  (:documentation
   "PRESENTATION layer: the only package that writes to the real terminal.  Composites
    every pane's emulator screen, the borders between them, the status bar, and any
    active overlay into one full repaint, emitted as raw ANSI/VT100 escapes with no
    curses dependency and flushed as a single write to avoid tearing.  Also owns
    style-string parsing and the true-colour downsampling used when the outer
    terminal cannot show 24-bit colour.")
  (:export
   #:render-session
   #:render-session-to-string
   #:render-session-to-tui-string
   #:render-workspace-overview-to-string
   #:render-workspace-overview-to-tui-string
   #:render-workspace-attention-to-string
   #:render-workspace-attention-to-tui-string
   #:benchmark-workspace-overview
   #:clear-display
   #:enable-mouse-reporting
   #:disable-mouse-reporting
   #:extended-keys-level
   #:enable-extended-keys
   #:disable-extended-keys
   #:enable-focus-reporting
   #:disable-focus-reporting
   #:parse-style-string
   #:style-to-sgr
   #:%popup-border-charset
   ;; Terminal colour-capability downsampling hook, set from the -2 startup
   ;; flag (main-startup-flags.lisp); see renderer-format.lisp.
   #:*color-downsample-fn*
   #:%rgb-int-to-256))

;; No :import-from for the sibling kits — input.lisp writes
;; cl-tty-kit:fd-read-octets qualified in full, which is what keeps the
;; descriptor-level surface legible. (It formerly wrote cffi: forms here; cffi
;; is no longer a dependency.)
(defpackage #:cl-tmux/input
  (:use #:cl
        #:cl-tmux/config #:cl-tmux/pty)
  (:documentation
   "INFRASTRUCTURE layer: keyboard input, read from fd 0 rather than from a Lisp
    stream.  A multiplexer has to see each keystroke the moment it arrives and has to
    distinguish 'nothing yet' from end of input, neither of which a buffered stream
    offers — so reads go through select(2) and a one-byte read(2).  Declared beside
    the renderer because it is the input half of the same terminal.")
  (:export
   #:with-raw-mode
   #:read-byte-nonblock))
