(in-package #:nerimux/renderer)

(defun %emit-bell (buffer)
  "Write the audible BEL character to BUFFER.
   visual-bell (domain/options, deleted R2.2) defaulted to \"off\", which
   %visual-bell-audible-p always classified as audible — with no config to
   set it \"on\" (silent), the bell is unconditionally audible now; §1.1
   retires the visual-bell machinery outright, folding this function to the
   one live branch instead of leaving a dead dispatch on a deleted option."
  (write-char (code-char 7) buffer))

(defun %discard-background-bells (session active-window)
  "Consume pending BEL flags for non-active panes.
   Their raw BEL sequence is retained on the pane notification queue and is
   sent by the server as a binary notification frame."
  (dolist (win (session-windows session))
    (unless (eq win active-window)
      (dolist (pane (window-panes win))
        (when (pane-screen pane)
          (screen-consume-bell (pane-screen pane)))))))

(defun %render-bell-and-cursor (buffer active-pane)
  "Clear the active pane's consumed BEL flag and restore cursor visibility.
   The raw BEL is sent through the notification wire message, so emitting it
   in the rendered frame would duplicate the host notification."
  (when active-pane
    (screen-consume-bell (pane-screen active-pane)))
  (when 
      (or (null active-pane) (screen-cursor-visible (pane-screen active-pane)))
    (cursor-visible buffer)
    (when active-pane
      (set-cursor-shape buffer (screen-cursor-shape (pane-screen active-pane))))))

(defun %drain-screen-queue (buffer panes queue-reader queue-writer emit)
  "Drain queue contents for each pane, clearing it either way; the drained
   content is written into BUFFER only when EMIT is true.
   QUEUE-READER reads the current queue from a screen object.
   QUEUE-WRITER clears the queue on a screen object after draining it.
   The actual read-and-clear is delegated to the terminal LOGIC layer via
   nerimux/terminal:screen-drain-queue so this presentation-layer code never
   mutates a screen slot directly."
  (dolist (pane panes)
    (let ((screen (pane-screen pane)))
      (when screen
        (with-lock-held ((screen-lock screen))
                        (let ((queued
                               (screen-drain-queue screen
                                                   queue-reader
                                                   queue-writer)))
                          (when emit
                            (dolist (seq queued)
                              (write-string seq buffer)))))))))

(defun %render-passthrough (buffer panes)
  "Drain each pane's passthrough-queue, discarding it without emitting.
   allow-passthrough (domain/options, deleted R2.2) defaulted to \"off\" with
   no config to turn it \"on\"/\"all\", so this never wrote to BUFFER even
   before R2 — the queue still had to be drained every frame so a pane that
   keeps emitting DCS-passthrough sequences cannot grow it without bound."
  (%drain-screen-queue buffer
                       panes
                       #'screen-passthrough-queue
                       (lambda (screen value)
                         (setf (screen-passthrough-queue screen) value))
                       nil))

(defun %render-clipboard (buffer panes)
  "Drain each pane's clipboard-queue into BUFFER (OSC 52).
   set-clipboard (domain/server-options, deleted R2.2) defaulted to \"on\"
   with no config to turn it \"off\", so emission was always on; the
   `set-clipboard` scope mismatch this fixes (the option lives in the
   server-scoped option table, but the deleted call site read the
   session-scoped one, silently falling through to its own passed-in
   default \"on\" every time) never changed the outcome, so it is not a
   behaviour change — see the R2 renderer report."
  (%drain-screen-queue buffer
                       panes
                       #'screen-clipboard-queue
                       (lambda (screen value)
                         (setf (screen-clipboard-queue screen) value))
                       t))
