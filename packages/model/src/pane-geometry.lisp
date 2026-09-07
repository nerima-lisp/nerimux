(in-package #:nerimux/pane)

(defun %update-pane-geometry (pane x y width height)
  "Update PANE's position and dimension slots to X, Y, WIDTH, HEIGHT.
   Pure data mutation — no I/O side effects."
  (setf (pane-x pane) x
        (pane-y pane) y
        (pane-width pane) width
        (pane-height pane) height))

(defun pane-reposition (pane x y width height)
  "Move and resize PANE to X,Y with WIDTH x HEIGHT.
   Updates the geometry slots, then resizes the underlying PTY and virtual screen.
   Pane borders do not reserve a title row, so the geometry covers the full
   allocated rectangle.  PTY resizing is performed only for positive
   dimensions; the screen geometry is updated for every layout."
  (%update-pane-geometry pane x y width height)
  (when (and (> (pane-fd pane) 0) (plusp width) (plusp height))
    (resize-pty (pane-fd pane) height width))
  (let ((screen (pane-screen pane)))
    (with-lock-held ((screen-lock screen)) (screen-resize screen width height))))
