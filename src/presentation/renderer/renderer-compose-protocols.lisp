(in-package #:nerimux/renderer)

;;;; Outer-terminal control for the nerimux renderer.
;;;;
;;;; One function: clear-display, called by the client at raw-mode setup
;;;; (src/bootstrap/client.lisp).  It is not part of the frame-compositing
;;;; pipeline, which is why no render entry point reaches this file.
;;;;
;;;; The reporting toggles that used to live here -- enable/disable for mouse
;;;; (?1000/?1002/?1006), extended keys (CSI > 4 ; N m) and focus events (?1004)
;;;; -- were removed on 2026-08-20.  Each emitted a sequence to the outer
;;;; terminal on behalf of a caller that no longer exists: the `mouse' option's
;;;; side-effect handler went with the config key-table store, and the
;;;; extended-keys and focus paths went with the prefix-key keystroke pipeline.  They
;;;; were exported and unit-tested but called from no production code, so the
;;;; tests were the only thing keeping them alive.  Reintroduce them next to a
;;;; caller, not on their own.

(defun clear-display ()
  "Erase the entire terminal and move cursor home."
  (format t "~C[2J~C[H" +esc+ +esc+)
  (force-output))
