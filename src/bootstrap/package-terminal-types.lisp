;;;; Terminal DATA layer manifest.
;;;;
;;;; Split out of package-terminal.lisp to keep both fragments inside the
;;;; 500-line limit.  The seam is the emulator's own: this file declares the
;;;; package that owns the SCREEN and CELL structs, package-terminal.lisp the
;;;; five layers that act on them plus the facade over all six.

(defpackage #:cl-tmux/terminal/types
  (:use #:cl)
  (:import-from #:cl-concurrent-kit #:make-lock)
  (:documentation
   "DOMAIN layer, the DATA half of the terminal emulator.  Defines the two structs
    the whole emulator is written against — CELL (character, colours, attribute
    bits, width) and SCREEN (the grid, the cursor, the SGR pen, scrollback, and the
    dozens of DEC/ANSI mode flags) — together with their attribute-bit constants and
    pure grid access.  Owns no behaviour beyond allocation and slot access; every
    mutation lives in cl-tmux/terminal/actions.")
  (:export
   ;; Attribute bit constants (LSB first, matching bit layout in cell.lisp)
   #:+attr-bold+
   #:+attr-dim+
   #:+attr-reverse+
   #:+attr-underline+
   #:+attr-blink+
   #:+attr-italic+
   #:+attr-conceal+
   #:+attr-strikethrough+
   ;; Extended attribute bits (attrs2 slot: double-underline, overline)
   #:+attr2-double-underline+
   #:+attr2-overline+
   ;; True-colour encoding sentinel (bit 24 of a colour slot)
   #:+true-color-flag+
   ;; Default-colour sentinel (SGR 39/49; distinct from palette 7/0)
   #:+default-color+
   ;; Fallback code point for invalid/undecodable input (U+FFFD)
   #:+unicode-replacement-char+
   ;; XTPUSHTITLE/XTPOPTITLE stack depth limit (matches xterm)
   #:+title-stack-max-depth+
   ;; Default terminal geometry constants (VT100 standard)
   #:+default-screen-width+
   #:+default-screen-height+
   ;; Grid allocation helper
   #:%make-blank-cells
   ;; Cell struct + helpers
   #:cell
   #:make-cell
   #:cell-p
   #:cell-char
   #:cell-fg
   #:cell-bg
   #:cell-attrs
   #:cell-attrs2
   #:cell-ul-color
   #:cell-combining
   #:cell-width
   #:cell-hyperlink
   #:blank-cell
   #:clamp
   #:safe-code-char
   ;; UTF-16 surrogate block (D800-DFFF): not Unicode scalar values, so no
   ;; well-formed UTF-8 encodes one and SBCL's encoder signals on one.
   #:+surrogate-first+
   #:+surrogate-last+
   #:surrogate-code-point-p
   ;; CHAR-WIDTH now delegates to CL-TTY-KIT:CHAR-WIDTH; the
   ;; DEFINE-WIDE-CHAR-RANGES macro that used to generate it, and its export, are
   ;; gone with the hand-rolled table.
   #:char-width
   ;; Screen struct + constructors
   #:screen
   #:%make-screen
   #:make-screen
   #:screen-p
   ;; Geometry / cursor / SGR-state accessors
   #:screen-width
   #:screen-height
   #:screen-cells
   #:screen-cursor-x
   #:screen-cursor-y
   #:screen-cur-fg
   #:screen-cur-bg
   #:screen-cur-attrs
   #:screen-cur-attrs2
   #:screen-cur-ul-color
   #:screen-scroll-top
   #:screen-scroll-bottom
   #:screen-parser
   #:screen-dirty-p
   #:screen-lock
   ;; Alternate-screen save slots
   #:screen-alt-cells
   #:screen-alt-cursor-x
   #:screen-alt-cursor-y
   ;; DECSC/DECRC saved cursor
   #:screen-saved-cursor
   ;; DECTCEM cursor visibility
   #:screen-cursor-visible
   ;; Copy / scrollback mode
   #:screen-copy-mode-p
   #:screen-copy-hide-position
   #:screen-copy-offset
   #:screen-scrollback
   #:screen-scrollback-wrapped
   #:screen-prompt-marks
   #:screen-history-trimmed
   #:screen-line-sizes
   ;; Copy-mode selection state
   #:screen-copy-mark
   #:screen-copy-mark-offset
   #:screen-copy-cursor
   #:screen-copy-selecting
   ;; copy-mode -e: auto-exit when scrolled to live bottom
   #:screen-copy-exit-on-bottom
   ;; Mouse-entered copy-mode suppresses gutter line numbers
   #:screen-copy-mode-entered-by-mouse-p
   ;; REP (repeat preceding char) support
   #:screen-last-char
   ;; DECSCUSR cursor shape
   #:screen-cursor-shape
   ;; BEL pending flag
   #:screen-bell-pending
   ;; Copy-mode search term (/ ? n N)
   #:screen-copy-search-term
   #:screen-copy-search-direction
   ;; Copy-mode line-selection flag (V)
   #:screen-copy-line-selection-p
   ;; Copy-mode rectangle-select flag (r)
   #:screen-copy-rect-select-p
   ;; IRM insert/replace mode
   #:screen-insert-mode
   #:screen-newline-mode
   #:screen-reverse-screen
   ;; Bracketed paste mode
   #:screen-bracketed-paste
   ;; Application cursor keys
   #:screen-app-cursor-keys
   ;; OSC 0/2 window title + XTPUSHTITLE/XTPOPTITLE stack
   #:screen-title
   #:screen-title-stack
   ;; OSC 7 current working directory
   #:screen-cwd
   ;; Mouse reporting mode
   #:screen-mouse-mode
   #:screen-mouse-sgr-mode
   ;; Auto-wrap mode (?7h / ?7l)
   #:screen-autowrap
   #:screen-pending-wrap
   #:screen-origin-mode
   ;; Focus event reporting (?1004h / ?1004l)
   #:screen-focus-events
   ;; Active character set (:ascii / :dec-graphics) + VT100 G0..G3 + shift state
   #:screen-charset
   #:screen-g0-charset
   #:screen-g1-charset
   #:screen-g2-charset
   #:screen-g3-charset
   #:screen-active-g
   #:screen-single-shift
   #:screen-tab-stops
   ;; Response queue for DA1/DA2 and similar replies
   #:screen-response-queue
   #:screen-passthrough-queue
   #:screen-clipboard-queue
   ;; OSC 10/11 default foreground/background colour constants (data layer)
   #:+osc-default-fg+
   #:+osc-default-bg+
   ;; OSC 10/11 default foreground/background colours
   #:screen-osc-default-fg
   #:screen-osc-default-bg
   ;; OSC 8 current hyperlink
   #:screen-current-hyperlink
   ;; OSC 4 / OSC 104 custom palette overrides
   #:screen-palette-overrides
   #:%palette-override-get
   #:%palette-override-set
   #:%palette-override-clear
   #:%palette-override-clear-all
   ;; Line-wrap flags (capture-pane -J)
   #:screen-wrapped-rows
   #:%mark-line-wrapped
   #:%line-wrapped-p
   #:%clear-line-wrapped
   #:%clear-all-line-wrapped
   #:%shift-line-wrapped-up
   ;; Grid helpers
   #:screen-cell
   #:screen-clear-dirty
   #:screen-resize
   ;; Bell consumption (logic layer — consume and clear bell-pending atomically)
   #:screen-consume-bell
   ;; Queue draining (logic layer — atomically read and clear a queue slot)
   #:screen-drain-queue
   ;; SGR pen reset (canonical, data layer; shared by actions and sgr layers)
   #:reset-sgr-pen))
