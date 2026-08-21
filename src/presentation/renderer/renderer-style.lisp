(in-package #:nerimux/renderer)

;;;; Fixed SGR constants for the nerimux renderer.
;;;;
;;;; R2.4 deleted the tmux style-string parser (parse-style-string,
;;;; %split-style-tokens, %classify-color-name, %color-name-to-sgr-number,
;;;; %color-name-to-cell-color, %window-style-default-colors,
;;;; %border-color-sgr, style-to-sgr, %status-sgr-from-style,
;;;; %effective-status-style) along with the option system it existed to
;;;; read: every style this renderer ever applied came from a `*-style`
;;;; option, and with no config file and no `set-option` there is no longer
;;;; a runtime string to parse.  Each call site now holds its own resolved
;;;; SGR string as a defconstant, computed once here by hand from the value
;;;; parse-style-string + style-to-sgr used to produce for that option's
;;;; fixed (or, per docs/notes/workspace-requirements.md §1.4, decided)
;;;; value — see renderer-borders.lisp, renderer-pane.lisp,
;;;; renderer-pane-search.lisp, and renderer-statusbar.lisp.  Emitting a
;;;; constant to the stream is renderer-format.lisp's existing %emit-sgr /
;;;; reset-attrs; no replacement "output side" composer was needed.
;;;;
;;;; Load order: renderer-format → renderer-style-data → renderer-style → renderer-pane → renderer.
;;;; All files share the nerimux/renderer package (no defpackage here).

(defconstant +sgr-default-status+
    (if (boundp '+sgr-default-status+)
        (symbol-value '+sgr-default-status+)
        "44;97")
  "Default status-bar SGR string: blue background (44) + bright white text (97).
   The `status-style` option (domain/options, deleted by R2.2) defaulted to
   the empty string, which parse-style-string/style-to-sgr always resolved
   to exactly this pair — it is now simply the status bar's fixed style.")
