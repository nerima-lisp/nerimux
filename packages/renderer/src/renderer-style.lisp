(in-package #:nerimux/renderer)

;;;; Theme palette and fixed SGR constants for the nerimux renderer.
;;;;
;;;; R2.4 deleted the style-string parser along with the option system it
;;;; existed to read; every style the renderer applies is a fixed constant
;;;; declared here.  The overview redesign (section-based tree, magit-style)
;;;; replaced the earlier xterm-256 palette with Dracula truecolour (38;2;
;;;; R;G;B / 48;2;R;G;B): the old "indexed colours only" rationale here
;;;; referenced a -2 downsampling flag that R2.4-era work deleted along with
;;;; the option system that set it, so there is no longer a downsampling
;;;; consumer to protect from a 24-bit SGR -- %FRAME-GRID-APPLY-SGR
;;;; (renderer-tui-kit-frame-grid.lisp) already parses the 38/48;2 extended
;;;; form the ANSI/tui-kit round trip depends on.
;;;;
;;;; Load order: renderer-format → renderer-style-data → renderer-style →
;;;; workspace and pane composition modules (all of which reference these
;;;; constants).  All files share the nerimux/renderer package.
;;; ── Palette (Dracula, truecolour) ────────────────────────────────────────────
;;;
;;; bg 40,42,54 · current-line 68,71,90 · fg 248,248,242 · comment 98,114,164
;;; · cyan 139,233,253 · green 80,250,123 · orange 255,184,108 · pink
;;; 255,121,198 · purple 189,147,249 · red 255,85,85 · yellow 241,250,140.
(defmacro %define-sgr-constant (name value documentation)
  "DEFCONSTANT with the boundp guard this codebase uses for string constants."
  `(defconstant ,name
     (if (boundp ',name)
         (symbol-value ',name)
         ,value)
     ,documentation))

(%define-sgr-constant +sgr-accent+
                      "38;2;139;233;253"
                      "Accent foreground (Dracula cyan): focused items, key hints, panel titles.")

(%define-sgr-constant +sgr-accent-bold+
                      "1;38;2;139;233;253"
                      "Bold accent foreground -- +SGR-ACCENT+, bolded.")

(%define-sgr-constant +sgr-branch+
                      "1;38;2;139;233;253"
                      "Branch/worktree names: bold Dracula cyan.")

(%define-sgr-constant +sgr-ok+
                      "38;2;80;250;123"
                      "Healthy state (CLEAN): Dracula green.")

(%define-sgr-constant +sgr-warn+
                      "38;2;241;250;140"
                      "Needs-attention state (DIRTY, PRUNABLE, unread output): Dracula yellow.")

(%define-sgr-constant +sgr-alert+
                      "1;38;2;255;85;85"
                      "Broken state (CONFLICT, MISSING, exited pane): bold Dracula red.")

(%define-sgr-constant +sgr-ahead+ "38;2;80;250;123" "AHEAD n: Dracula green.")

(%define-sgr-constant +sgr-behind+
                      "38;2;255;184;108"
                      "BEHIND n: Dracula orange.")

(%define-sgr-constant +sgr-locked+ "38;2;255;184;108" "LOCKED: Dracula orange.")

(%define-sgr-constant +sgr-muted+
                      "38;2;98;114;164"
                      "Secondary text: labels, legends, notifications -- Dracula comment.")

(%define-sgr-constant +sgr-muted-italic+
                      "3;38;2;98;114;164"
                      "Secondary text, italic: transient notifications, placeholders.")

(%define-sgr-constant +sgr-faint+
                      "2;38;2;98;114;164"
                      "Tertiary text: scroll positions, UNKNOWN state, disabled hints -- dimmed
   Dracula comment.")

(%define-sgr-constant +sgr-line+
                      "38;2;68;71;90"
                      "Panel separators and inactive pane borders: Dracula current-line, as a
   foreground colour.")

(%define-sgr-constant +sgr-header-chip+
                      "1;38;2;40;42;54;48;2;189;147;249"
                      "The `nerimux` header chip: dark (Dracula bg) text on Dracula purple.")

(%define-sgr-constant +sgr-mode-chip+
                      "1;38;2;189;147;249;48;2;68;71;90"
                      "The footer/key-panel mode chip: Dracula purple text on the current-line
   background.")

(%define-sgr-constant +sgr-section+
                      "1;38;2;189;147;249"
                      "Section headings (Attention/Active/Repositories) in the overview tree:
   bold Dracula purple.")

;;; ── Status bar ──────────────────────────────────────────────────────────────
(%define-sgr-constant +sgr-default-status+
                      "48;2;40;42;54;38;2;248;248;242"
                      "Status-bar base SGR: Dracula bg with Dracula fg text.
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
