(in-package #:nerimux/terminal/actions)

;;;; Terminal modes — cursor save/restore (DECSC/DECRC) and cursor shape (DECSCUSR).
;;; ── DECSC / DECRC (cursor save & restore) ──────────────────────────────────
(defun save-cursor (screen)
  "DECSC (ESC 7): save the cursor position, full SGR pen, charset state, and origin mode.
   A correct DECSC saves more than just cursor position: also the pen
   (attrs/fg/bg), the charset designation (g0/g1/active), and the mode state
   (including origin mode) -- omitting any of these breaks apps that rely on
   DECSC/DECRC to round-trip full cursor state, not just x/y.
   Saves: cursor-x/y, cur-fg/bg/attrs/attrs2/ul-color, g0/g1/active charset, origin-mode."
  (setf (screen-saved-cursor screen) (list (screen-cursor-x screen)
                                           (screen-cursor-y screen)
                                           (screen-cur-fg screen)
                                           (screen-cur-bg screen)
                                           (screen-cur-attrs screen)
                                           (screen-cur-attrs2 screen)
                                           (screen-cur-ul-color screen)
                                           (screen-g0-charset screen)
                                           (screen-g1-charset screen)
                                           (screen-active-g screen)
                                           (screen-charset screen)
                                           (screen-origin-mode screen))))

(defun %restore-cursor-to-defaults (screen)
  "Restore cursor and SGR state to VT100 power-on defaults (no prior DECSC snapshot).
   Homes the cursor, resets the SGR pen, clears origin mode, and resets the G0/G1
   charset designations and the effective charset to :ascii."
  (set-cursor screen 0 0)
  (reset-sgr-pen screen)
  (setf (screen-origin-mode screen) nil
        (screen-g0-charset screen) :ascii
        (screen-g1-charset screen) :ascii
        (screen-g2-charset screen) :ascii
        (screen-g3-charset screen) :ascii
        (screen-single-shift screen) nil
        (screen-active-g screen) :g0
        (screen-charset screen) :ascii))

(defun %restore-cursor-from-snapshot (screen snapshot)
  "Restore cursor and SGR state from a DECSC SNAPSHOT (a list produced by SAVE-CURSOR).
   Applies cursor-x/y, SGR pen (fg/bg/attrs/attrs2/ul-color), charset designations
   (G0/G1/active-g/charset), and origin-mode from the snapshot in order."
  (destructuring-bind (cx cy
                          fg
                          bg
                          attrs
                          attrs2
                          ul-color
                          g0
                          g1
                          active-g
                          charset
                          origin-mode) snapshot
    (set-cursor screen cx cy)
    (setf (screen-cur-fg screen) fg
          (screen-cur-bg screen) bg
          (screen-cur-attrs screen) attrs
          (screen-cur-attrs2 screen) attrs2
          (screen-cur-ul-color screen) ul-color
          (screen-g0-charset screen) g0
          (screen-g1-charset screen) g1
          (screen-active-g screen) active-g
          (screen-charset screen) charset
          (screen-origin-mode screen) origin-mode)))

(defun restore-cursor (screen)
  "DECRC (ESC 8): restore the cursor position, SGR pen, charset state, and origin mode
   saved by DECSC.  With nothing previously saved, home the cursor and reset the
   SGR pen, charset, and origin mode to VT100 defaults."
  (if (null (screen-saved-cursor screen))
      (%restore-cursor-to-defaults screen)
      (%restore-cursor-from-snapshot screen (screen-saved-cursor screen))))

;;; ── DECSCUSR cursor shape ────────────────────────────────────────────────────
(defun set-cursor-shape (screen shape)
  "DECSCUSR: set the cursor shape to SHAPE (0-6, clamped).
   0 = default blinking block, 1 = blinking block, 2 = steady block,
   3 = blinking underline, 4 = steady underline, 5 = blinking bar,
   6 = steady bar."
  (setf (screen-cursor-shape screen) (clamp shape 0 6)))
