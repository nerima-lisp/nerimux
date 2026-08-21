;;;; Terminal BEHAVIOUR layers and facade manifest.
;;;;
;;;; The DATA layer these all build on is package-terminal-types.lisp, which
;;;; package.lisp loads first.

;; This :use of a sibling package is kept deliberately; check-coding.sh reports it.
;; CODING_STANDARD.md asks for :import-from so a symbol's origin stays readable, and
;; the reason it gives is collision when a :use-d package adds an export in a later
;; release. Neither argument lands here. actions references 79 of terminal/types'
;; 126 exports, and they are the SCREEN and CELL slot accessors themselves: types
;; and actions are the data and behaviour halves of one struct, split so the grid
;; can be allocated and read without pulling in the mutation layer -- not two
;; modules with an interface between them. Enumerating 79 accessors would restate
;; the struct definition in a second place that must be edited in step with the
;; first, and would drift the first time a slot is added and the list is not. The
;; collision the standard guards against needs an independently released package;
;; these two are compiled from the same directory in the same system.
;;
;; This is the only sibling :use that was measured and kept. The others removed in
;; the same change (format, transport, sgr, and both #:cffi forms) turned out to
;; need between zero and twenty names.
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
   ;; Cursor movement
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
   ;; Character writing
   #:write-char-at-cursor
   #:write-codepoint
   #:combining-char-p
   ;; Scroll
   #:scroll-up-one
   #:scroll-down-one
   #:scroll-screen-to-history
   #:trim-scroll-history
   #:clear-scrollback
   #:trim-below-cursor
   #:+max-scrollback-lines+
   #:*history-limit-function*
   #:*alternate-screen-enabled-function*
   #:*scroll-on-clear-function*
   ;; Focus event reporting (?1004)
   #:focus-event-report
   ;; Erase
   #:erase-region
   #:erase-display
   #:erase-line
   ;; DEC Rectangle operations (DECERA/DECFRA/DECCRA)
   #:decera
   #:decfra
   #:deccra
   ;; Edit (insert/delete characters and lines)
   #:delete-chars
   #:insert-chars
   #:insert-lines
   #:delete-lines
   ;; Scroll region + DEC private modes + reset
   #:decstbm
   #:dec-pm-set
   #:dec-pm-reset
   #:enter-alt-screen
   #:exit-alt-screen
   #:reset-terminal-modes
   #:ris-action
   #:decstr-action
   #:decaln-action
   ;; DECSC / DECRC cursor save & restore
   #:save-cursor
   #:restore-cursor
   ;; Display projection (copy-mode scrollback)
   #:screen-display-cell
   ;; Terminal state action helpers (DISPATCH layer calls these instead of mutating structs)
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

;; sgr package: apply-sgr + the inverse %pen-to-sgr-params (DECRQSS reports)
(defpackage #:nerimux/terminal/sgr
  (:use #:cl)
  ;; SGR touches exactly one part of a screen -- the pen -- so the list is short
  ;; and, unlike the grid accessors, fixed by ECMA-48 rather than by our struct.
  (:import-from #:nerimux/terminal/types
                ;; Attribute bits (SGR 1-9, 21, 53)
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
                ;; Colour sentinels (SGR 38/48 true colour, 39/49 default)
                #:+true-color-flag+
                #:+default-color+
                ;; The pen itself
                #:screen
                #:screen-cur-fg
                #:screen-cur-bg
                #:screen-cur-attrs
                #:screen-cur-attrs2
                #:screen-cur-ul-color
                #:reset-sgr-pen
                ;; Helpers
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
  (:export
   #:execute-csi))

(defpackage #:nerimux/terminal/parser
  (:use #:cl
        #:nerimux/terminal/types
        #:nerimux/terminal/actions
        #:nerimux/terminal/csi)
  ;; nerimux/buffer is used for OSC 52 clipboard paste storage.
  ;; We reference it by qualified name to avoid circular deps.
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
   ;; CSI final-byte-range predicates (ECMA-48 §5.4) — shared with the
   ;; keystroke-escape decoder, which needs to recognise an in-progress vs.
   ;; complete CSI sequence while accumulating raw input bytes.
   #:csi-final-byte-before-p
   #:csi-final-byte-p))

(defpackage #:nerimux/terminal/emulator
  (:use #:cl
        #:nerimux/terminal/types)
  (:documentation
   "DOMAIN layer: the emulator's entry point, and nothing else.  SCREEN-PROCESS-BYTES
    drives a run of raw PTY octets through the CPS parser loop.  It is a package of
    its own so the layers above depend on the act of feeding bytes rather than on the
    state machine that consumes them.")
  (:export
   #:screen-process-bytes))

;;; ── Terminal umbrella (re-export facade) ─────────────────────────────────

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
   ;; Construction
   #:make-screen
   ;; Geometry
   #:screen-width
   #:screen-height
   ;; Cursor
   #:screen-cursor-x
   #:screen-cursor-y
   ;; Dirty flag
   #:screen-dirty-p
   #:screen-clear-dirty
   ;; DECTCEM cursor visibility
   #:screen-cursor-visible
   ;; DECSCUSR cursor shape
   #:screen-cursor-shape
   ;; IRM insert/replace mode
   #:screen-insert-mode
   #:screen-origin-mode
   #:screen-alt-cells
   #:screen-scroll-top
   #:screen-scroll-bottom
   #:screen-newline-mode
   #:screen-reverse-screen
   ;; Bracketed paste mode
   #:screen-bracketed-paste
   ;; Application cursor keys
   #:screen-app-cursor-keys
   ;; OSC 0/2 window title
   #:screen-title
   ;; OSC 7 current working directory
   #:screen-cwd
   ;; Mouse reporting mode
   ;; Lock (for renderer <-> reader-thread synchronisation)
   #:screen-lock
   ;; Resize the grid in place
   #:screen-resize
   ;; Feed raw PTY bytes into the emulator
   #:screen-process-bytes
   ;; Grid access
   #:screen-cell
   ;; Viewport projection honoring copy-mode scrollback
   #:screen-display-cell
   ;; Copy / scrollback mode (used by renderer status bar + commands)
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
   ;; Cell accessors
   #:cell-char
   #:cell-fg
   #:cell-bg
   #:cell-attrs
   #:cell-attrs2
   #:cell-ul-color
   #:cell-combining
   #:cell-width
   #:cell-hyperlink
   ;; Auto-wrap mode
   #:screen-autowrap
   #:screen-pending-wrap
   ;; Active character set
   #:screen-charset
   ;; SGR pen extras
   #:screen-cur-attrs2
   #:screen-cur-ul-color
   ;; Response queue
   #:screen-response-queue
   #:screen-passthrough-queue
   #:screen-clipboard-queue
   ;; Combining char predicate
   #:combining-char-p
   ;; BEL pending flag
   #:screen-bell-pending
   ;; Bell consumption (logic layer)
   #:screen-consume-bell
   ;; Queue draining (logic layer)
   #:screen-drain-queue
   ;; Copy-mode search term
   #:screen-copy-search-term
   #:screen-copy-search-direction
   ;; Copy-mode line-selection flag
   #:screen-copy-line-selection-p
   ;; Copy-mode rectangle-select flag
   #:screen-copy-rect-select-p
   ;; Scroll history limit callback (injected at startup)
   #:+max-scrollback-lines+
   #:*history-limit-function*
   #:*alternate-screen-enabled-function*
   #:*scroll-on-clear-function*))
