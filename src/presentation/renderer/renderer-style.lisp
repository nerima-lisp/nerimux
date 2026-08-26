(in-package #:nerimux/renderer)

;;;; Theme palette and fixed SGR constants for the nerimux renderer.
;;;;
;;;; R2.4 deleted the style-string parser along with the option system it
;;;; existed to read; every style the renderer applies is a fixed constant
;;;; declared here.  The UI modernisation pass replaced the original
;;;; hand-resolved option values (blue-on-white status bar, green active
;;;; border) with a coherent xterm-256 palette: indexed colours only, so the
;;;; frame renders identically on 256-colour and truecolour terminals and
;;;; never leaks a 24-bit SGR that -2 downsampling would have to rewrite.
;;;;
;;;; Load order: renderer-format → renderer-style-data → renderer-style →
;;;; workspace and pane composition modules (all of which reference these
;;;; constants).  All files share the nerimux/renderer package.

;;; ── Palette (xterm-256 indices) ─────────────────────────────────────────────

(defmacro %define-sgr-constant (name value documentation)
  "DEFCONSTANT with the boundp guard this codebase uses for string constants."
  `(defconstant ,name
       (if (boundp ',name) (symbol-value ',name) ,value)
     ,documentation))

(%define-sgr-constant +sgr-accent+ "38;5;117"
  "Accent foreground (sky blue): focused items, key hints, panel titles.")
(%define-sgr-constant +sgr-accent-bold+ "1;38;5;117"
  "Bold accent foreground.")
(%define-sgr-constant +sgr-branch+ "1;38;5;183"
  "Branch/worktree names: bold lavender.")
(%define-sgr-constant +sgr-ok+ "38;5;114"
  "Healthy state (CLEAN): soft green.")
(%define-sgr-constant +sgr-warn+ "38;5;179"
  "Needs-attention state (DIRTY, PRUNABLE, unread output): amber.")
(%define-sgr-constant +sgr-alert+ "1;38;5;203"
  "Broken state (CONFLICT, MISSING, exited pane): bold coral red.")
(%define-sgr-constant +sgr-ahead+ "38;5;116"
  "AHEAD n: teal.")
(%define-sgr-constant +sgr-behind+ "38;5;215"
  "BEHIND n: orange.")
(%define-sgr-constant +sgr-locked+ "38;5;111"
  "LOCKED: periwinkle.")
(%define-sgr-constant +sgr-muted+ "38;5;245"
  "Secondary text: labels, legends, notifications.")
(%define-sgr-constant +sgr-muted-italic+ "3;38;5;245"
  "Secondary text, italic: transient notifications, placeholders.")
(%define-sgr-constant +sgr-faint+ "38;5;240"
  "Tertiary text: scroll positions, UNKNOWN state, disabled hints.")
(%define-sgr-constant +sgr-line+ "38;5;238"
  "Panel separators and inactive pane borders: near-background gray.")
(%define-sgr-constant +sgr-header-chip+ "1;38;5;235;48;5;117"
  "The `nerimux` header chip: dark text on the accent colour.")
(%define-sgr-constant +sgr-mode-chip+ "1;38;5;117;48;5;237"
  "The footer mode chip: accent text on a raised gray.")

;;; ── Status bar ──────────────────────────────────────────────────────────────

(%define-sgr-constant +sgr-default-status+ "48;5;235;38;5;250"
  "Status-bar base SGR: near-black bar (bg 235) with soft white text.
   Replaces the pre-theme \"44;97\" (blue background + bright white) that the
   deleted `status-style` option used to resolve to.")

;;; ── Inline styling helper ───────────────────────────────────────────────────

(defun %sgr-wrap (text sgr &optional (restore "0"))
  "TEXT wrapped in ESC[SGRm … ESC[RESTOREm.  RESTORE defaults to a plain
   reset; pass (concatenate 'string \"0;\" base) to fall back to a base style
   such as the status bar's.  The result embeds zero-width escapes, so it
   must only flow into SGR-aware sinks (%VISIBLE-LENGTH / %VISIBLE-TRUNCATE
   consumers), never into %DISPLAY-CLIP."
  (format nil "~C[~Am~A~C[~Am" +esc+ sgr text +esc+ restore))

(defun %status-wrap (text sgr)
  "TEXT in SGR, restoring the status bar's base style afterwards."
  (%sgr-wrap text sgr (concatenate 'string "0;" +sgr-default-status+)))

(defun %worktree-state-token-sgr (token)
  "The palette SGR for one %WORKTREE-STATUS-TOKENS entry, or NIL for a token
   that should stay in the surrounding text colour."
  (cond
    ((string= token "CLEAN") +sgr-ok+)
    ((string= token "DIRTY") +sgr-warn+)
    ((string= token "PRUNABLE") +sgr-warn+)
    ((string= token "CONFLICT") +sgr-alert+)
    ((string= token "MISSING") +sgr-alert+)
    ((string= token "LOCKED") +sgr-locked+)
    ((string= token "BARE") +sgr-muted+)
    ((string= token "UNKNOWN") +sgr-faint+)
    ;; Repository-level states (workspace overview) share this table.
    ((string= token "ready") +sgr-ok+)
    ((string= token "NO-WORKTREE") +sgr-faint+)
    ((and (>= (length token) 5) (string= (subseq token 0 5) "AHEAD")) +sgr-ahead+)
    ((and (>= (length token) 6) (string= (subseq token 0 6) "BEHIND")) +sgr-behind+)
    (t nil)))
