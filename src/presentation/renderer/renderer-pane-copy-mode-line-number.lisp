(in-package #:nerimux/renderer)

;;;; Copy-mode line-number gutter rendering — retired by R2.2.
;;;;
;;;; docs/notes/workspace-requirements.md §1.4 fixes copy-mode-line-numbers
;;;; at "off" permanently (no config exists to turn it on), so the gutter
;;;; this file drew is unreachable: %copy-mode-line-number-gutter-width
;;;; always returned 0 for mode "off", which made every function below it —
;;;; the gutter-width computation, the per-row rendering, the line-number
;;;; text/style formulas — dead code with no live caller.  render-pane
;;;; (renderer-pane.lisp) now uses the pane's full width directly instead of
;;;; calling %copy-mode-pane-geometry.
;;;;
;;;; Kept as an empty file rather than removed from nerimux.asd's :serial
;;;; component list, which is outside this file's ownership; see the R2
;;;; renderer report.
