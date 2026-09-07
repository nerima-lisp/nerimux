(in-package #:nerimux/terminal/types)

(defun screen-clear-dirty (screen)
  "Clear the dirty flag on SCREEN, marking it as freshly rendered.
   The renderer calls this after every successful frame paint so the next
   PTY write can re-arm the flag via (setf (screen-dirty-p …) t)."
  (setf (screen-dirty-p screen) nil))

(defun screen-consume-bell (screen)
  "Return T and clear SCREEN's bell-pending flag when a BEL is pending.
   Returns NIL without side effects when no bell is pending.

   The renderer (nerimux/renderer-compose) calls this once per frame to relay
   a BEL to the outer terminal; the atomic test-and-clear here ensures the bell
   is delivered exactly once even when multiple frames race."
  (when (screen-bell-pending screen)
    (setf (screen-bell-pending screen) nil)
    t))

(defun screen-record-notification (screen raw-bytes text)
  "Record one terminal notification as RAW-BYTES plus display TEXT.
   The raw sequence is copied before it is retained because the parser uses an
   adjustable continuation buffer while it consumes an OSC sequence."
  (push (cons (coerce raw-bytes '(simple-array (unsigned-byte 8) (*)))
              text)
        (screen-notification-queue screen))
  screen)

(defun screen-drain-notification-queue (screen)
  "Return SCREEN's notification entries oldest-first and clear the queue."
  (prog1 (nreverse (screen-notification-queue screen))
    (setf (screen-notification-queue screen) nil)))

(defun screen-drain-queue (screen queue-reader queue-writer)
  "Atomically read and clear a push-accumulated queue slot on SCREEN, returning
   the queued items in push order (oldest first).
   QUEUE-READER reads the current (reverse-chronological) list from SCREEN.
   QUEUE-WRITER is called with SCREEN and NIL to clear the slot.
   Used by the renderer to drain the passthrough-queue and clipboard-queue
   without mutating SCREEN's slots directly from the presentation layer."
  (let ((queued (nreverse (funcall queue-reader screen))))
    (funcall queue-writer screen nil)
    queued))

(declaim (inline reset-sgr-pen))

(defun reset-sgr-pen (screen)
  "Reset all five SGR pen slots of SCREEN to VT100 power-on defaults:
   foreground / background = +default-color+ (terminal default), all
   attribute bits clear.  Inlined for use in the hot SGR dispatch path."
  (setf (screen-cur-fg screen) +default-color+
        (screen-cur-bg screen) +default-color+
        (screen-cur-attrs screen) 0
        (screen-cur-attrs2 screen) 0
        (screen-cur-ul-color screen) 0))
