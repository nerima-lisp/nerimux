(in-package #:nerimux/test/commands)

;;;; Copy-mode screen fixtures.
;;;;
;;;; Lives with nerimux-commands: COPY-MODE-SCREEN calls
;;;; nerimux/commands::copy-mode-enter to put the screen into copy mode, so a
;;;; terminal test system carrying it would need an edge from DOMAIN up to
;;;; APPLICATION that the source deliberately does not have.

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
