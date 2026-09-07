(in-package #:nerimux/renderer)

(defun enable-host-modes ()
  "Enable the terminal modes required by an attached client."
  (format t "~C[?1049h~C[?2004h~C[?1004h" +esc+ +esc+ +esc+)
  (force-output))

(defun disable-host-modes ()
  "Disable the terminal modes required by an attached client."
  (format t "~C[?1004l~C[?2004l~C[?1049l" +esc+ +esc+ +esc+)
  (force-output))

(defun clear-display ()
  "Erase the entire terminal and move cursor home."
  (format t "~C[2J~C[H" +esc+ +esc+)
  (force-output))
