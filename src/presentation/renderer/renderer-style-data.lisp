(in-package #:nerimux/renderer)

;;;; Declarative renderer style data.
;;;;
;;;; This file held the style-string parser's declarative dispatch
;;;; tables (style tokens, SGR attribute codes, colour names).  R2.4 deleted
;;;; the parser: every style this renderer applies is now a fixed SGR
;;;; constant declared next to the code that emits it (renderer-style.lisp,
;;;; renderer-borders.lisp, renderer-pane.lisp, renderer-pane-search.lisp,
;;;; renderer-statusbar.lisp), so there is no longer a string to classify or
;;;; split into tokens.  Kept as an empty file — not removed from
;;;; nerimux.asd's :serial component list here — because that list is
;;;; outside this file's ownership; see the R2 renderer report.
;;;;
;;;; Load order: renderer-format → renderer-style-data → renderer-style → pane and composition modules.
;;;; All files share the nerimux/renderer package (no defpackage here).

(defvar +sgr-copy-mode-match+
    "48;5;179;38;5;235"
  "SGR for a copy-mode search match: amber background, dark text.")
(defvar +sgr-copy-mode-current-match+
    "48;5;117;38;5;235"
  "SGR for the copy-mode search match under the cursor: accent background,
   dark text.")
