(in-package #:nerimux/test)

;;;; Copy-mode screen fixtures.
;;;;
;;;; Split out of helpers-terminal-builders.lisp when domain/terminal became
;;;; nerimux-terminal. COPY-MODE-SCREEN calls nerimux/commands::copy-mode-enter,
;;;; so a terminal test system carrying it would need an edge from DOMAIN up to
;;;; APPLICATION that the source deliberately does not have. No terminal test
;;;; uses either definition; the callers are the commands tests and one renderer
;;;; test.

(defun copy-mode-screen (&key (w 20) (h 5) (content "") cursor mark selecting)
  "Return a copy-mode screen pre-filled with CONTENT and optional copy state."
  (let ((screen (make-screen w h)))
    (unless (string= content "")
      (feed screen content))
    (nerimux/commands::copy-mode-enter screen)
    (when cursor
      (setf (nerimux/terminal/types:screen-copy-cursor screen) cursor))
    (when mark
      (setf (nerimux/terminal/types:screen-copy-mark screen) mark))
    (when selecting
      (setf (nerimux/terminal/types:screen-copy-selecting screen) selecting))
    screen))

(defmacro with-copy-mode-cursor ((screen-var row col &key (w 20) (h 5)) &body body)
  "Bind SCREEN-VAR to a fresh copy-mode screen with cursor at (ROW . COL)."
  `(let ((,screen-var (copy-mode-screen :w ,w :h ,h :cursor (cons ,row ,col))))
     ,@body))
