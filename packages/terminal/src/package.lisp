(defpackage #:nerimux/terminal/actions
  (:use #:cl #:nerimux/terminal/types)
  (:documentation
   "DOMAIN layer, the BEHAVIOUR half of the terminal emulator.  Every mutation of a
    SCREEN lands here: cursor motion and tab stops, character writing, scrolling and
    the scrollback ring, erase and DEC rectangle operations, line and character
    insert/delete, scroll regions, alternate screen, charset designation, and the
    RIS/DECSTR/DECALN resets.  Callers above state what happened; this package
    decides what that does to the grid.")
  (:export
   #:cursor-up
   #:cursor-down
   #:cursor-right
   #:cursor-left
   #:set-cursor
   #:cursor-lf
   #:cursor-nl
   #:cursor-ht
   #:cursor-cht
   #:cursor-cbt
   #:set-tab-stop
   #:clear-tab-stops
   #:cursor-bs
   #:cursor-ri
   #:cursor-cr
   #:cursor-nel
   #:cursor-down/scroll
   #:write-char-at-cursor
   #:write-codepoint
   #:combining-char-p
   #:scroll-up-one
   #:scroll-down-one
   #:scroll-screen-to-history
   #:trim-scroll-history
   #:clear-scrollback
   #:trim-below-cursor
   #:+max-scrollback-lines+
   #:focus-event-report
   #:erase-region
   #:erase-display
   #:erase-line
   #:decera
   #:decfra
   #:deccra
   #:delete-chars
   #:insert-chars
   #:insert-lines
   #:delete-lines
   #:decstbm
   #:dec-pm-set
   #:dec-pm-reset
   #:enter-alt-screen
   #:exit-alt-screen
   #:reset-terminal-modes
   #:ris-action
   #:decstr-action
   #:decaln-action
   #:save-cursor
   #:restore-cursor
   #:screen-display-cell
   #:set-cursor-shape
   #:set-bell-pending
   #:set-ansi-mode
   #:reset-ansi-mode
   #:designate-charset
   #:invoke-charset
   #:screen-invoked-charset
   #:set-screen-title
   #:push-title-stack
   #:pop-title-stack
   #:reset-osc-default-fg
   #:reset-osc-default-bg
   #:set-screen-cwd))

(defpackage #:nerimux/terminal/sgr
  (:use #:cl)
  (:import-from #:nerimux/terminal/types
                #:+attr-bold+
                #:+attr-dim+
                #:+attr-italic+
                #:+attr-underline+
                #:+attr-blink+
                #:+attr-reverse+
                #:+attr-conceal+
                #:+attr-strikethrough+
                #:+attr2-double-underline+
                #:+attr2-overline+
                #:+true-color-flag+
                #:+default-color+
                #:screen
                #:screen-cur-fg
                #:screen-cur-bg
                #:screen-cur-attrs
                #:screen-cur-attrs2
                #:screen-cur-ul-color
                #:reset-sgr-pen
                #:clamp)
  (:documentation
   "DOMAIN layer: SGR (Select Graphic Rendition) parameter interpretation, kept apart
    from the rest of CSI because it is the one sequence whose parameters form a
    stream rather than a fixed arity.  APPLY-SGR folds a parameter list into the
    screen's pen; %PEN-TO-SGR-PARAMS runs the mapping backwards so DECRQSS can
    report the pen as the parameters that would reproduce it.")
  (:export
   #:%dispatch-sgr-code
   #:apply-sgr
   #:%pen-to-sgr-params))

(defpackage #:nerimux/terminal/csi
            (:use #:cl
                  #:nerimux/terminal/types
                  #:nerimux/terminal/actions
                  #:nerimux/terminal/sgr)
            (:documentation
             "DOMAIN layer: the CSI rule table.  Maps a parsed control sequence — final byte,
    private-marker, and parameters — onto the nerimux/terminal/actions call it means,
    and generates the replies the host expects back (DSR/CPR cursor reports, DA1/DA2
    device attributes, DECRQM mode state, XTWINOPS size reports).  Declarative on
    purpose: the sequence set is a specification, not an algorithm.")
            (:export #:execute-csi))

(defpackage #:nerimux/terminal/parser
  (:use #:cl
        #:nerimux/terminal/types
        #:nerimux/terminal/actions
        #:nerimux/terminal/csi)
  (:documentation
   "DOMAIN layer: the byte-level VT100 state machine, written in continuation-passing
    style.  Each state — ground, escape, CSI, OSC, DCS, UTF-8 continuation, charset
    designator — is a closure that takes the next byte and returns the next state,
    and the only place that state is stored is the screen's PARSER slot.  That is
    what lets a pane be fed one octet at a time from a PTY and resume mid-sequence
    across reads.")
  (:export
   #:ground-state
   #:escape-state
   #:make-csi-k
   #:make-utf8-k
   #:osc-state
   #:make-charset-designator-k
   #:*osc52-handler*
   #:osc52-clipboard-sequence
   #:csi-final-byte-before-p
   #:csi-final-byte-p))

(defpackage #:nerimux/terminal/emulator
            (:use #:cl #:nerimux/terminal/types)
            (:documentation
             "DOMAIN layer: the emulator's entry point, and nothing else.  SCREEN-PROCESS-BYTES
    drives a run of raw PTY octets through the CPS parser loop.  It is a package of
    its own so the layers above depend on the act of feeding bytes rather than on the
    state machine that consumes them.")
            (:export #:screen-process-bytes))

(defpackage #:nerimux/terminal
  (:use #:cl
        #:nerimux/terminal/types
        #:nerimux/terminal/actions
        #:nerimux/terminal/sgr
        #:nerimux/terminal/csi
        #:nerimux/terminal/parser
        #:nerimux/terminal/emulator)
  (:documentation
   "DOMAIN layer: the terminal facade.  The six sub-packages above split the emulator
    by mechanism, which is the right seam for the emulator's own authors and the
    wrong one for its callers.  This package re-exports the subset the model, the
    renderer, and the command layer are meant to reach — construction, geometry,
    cursor, grid and viewport access, copy-mode scrollback, and the mode flags the
    renderer must honour — so that no caller outside src/domain/terminal/ needs to
    know which sub-package a name came from.  Adding a name here is a deliberate
    widening of the emulator's public surface.")
  (:export
   #:make-screen
   #:screen-width
   #:screen-height
   #:screen-cursor-x
   #:screen-cursor-y
   #:screen-dirty-p
   #:screen-clear-dirty
   #:screen-cursor-visible
   #:screen-cursor-shape
   #:screen-insert-mode
   #:screen-origin-mode
   #:screen-alt-cells
   #:screen-scroll-top
   #:screen-scroll-bottom
   #:screen-newline-mode
   #:screen-reverse-screen
   #:screen-bracketed-paste
   #:screen-app-cursor-keys
   #:screen-title
   #:screen-cwd
   #:screen-lock
   #:screen-resize
   #:screen-process-bytes
   #:screen-cell
   #:screen-display-cell
   #:screen-copy-mode-p
   #:screen-copy-hide-position
   #:screen-copy-offset
   #:screen-scrollback
   #:screen-scrollback-wrapped
   #:screen-prompt-marks
   #:screen-history-trimmed
   #:screen-line-sizes
   #:screen-copy-mark
   #:screen-copy-mark-offset
   #:screen-copy-cursor
   #:screen-copy-selecting
   #:screen-copy-exit-on-bottom
   #:screen-copy-mode-entered-by-mouse-p
   #:cell-char
   #:cell-fg
   #:cell-bg
   #:cell-attrs
   #:cell-attrs2
   #:cell-ul-color
   #:cell-combining
   #:cell-width
   #:cell-hyperlink
   #:screen-autowrap
   #:screen-pending-wrap
   #:screen-charset
   #:screen-cur-attrs2
   #:screen-cur-ul-color
   #:screen-response-queue
   #:screen-passthrough-queue
   #:screen-clipboard-queue
   #:combining-char-p
   #:screen-bell-pending
   #:screen-consume-bell
   #:screen-drain-queue
   #:screen-copy-search-term
   #:screen-copy-search-index
   #:screen-copy-search-total
   #:screen-copy-search-direction
   #:screen-copy-line-selection-p
   #:screen-copy-rect-select-p
   #:+max-scrollback-lines+))
