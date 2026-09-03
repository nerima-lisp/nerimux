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
   Pane borders never carry a status label (§1.4, R6.6: border is a plain line,
   the active pane's border colored, no title row) — the pane's geometry is
   always the full allocated rectangle, with no row reserved.

   THE PTY RESIZE IS GUARDED ON THE DIMENSIONS, not just on the fd.  set-pty-size
   now reaches cl-tty-kit:set-terminal-size, whose %assert-terminal-dimension
   demands POSITIVE integers and signals before the ioctl is attempted; the cffi
   path it replaced passed a 0x0 winsize straight through and dropped the -1
   return on the floor.  This is a caller that can receive a zero HEIGHT
   directly — a degenerate layout (a window relayout to zero rows, a split
   leaving a pane no room) would signal out of what is otherwise a pure geometry
   update.  Skipping the resize keeps the pre-migration behaviour: the kernel is
   simply not told about a window that has no area to report.  The slot update
   and the screen-resize below still happen, so the pane's own geometry stays
   consistent with the layout that asked for it."
  (%update-pane-geometry pane x y width height)
  (when (and (> (pane-fd pane) 0) (plusp width) (plusp height))
    (resize-pty (pane-fd pane) height width))
  (let ((screen (pane-screen pane)))
    (with-lock-held ((screen-lock screen)) (screen-resize screen width height))))
