(in-package #:nerimux/terminal/actions)

(defun reset-terminal-modes (screen)
  "Reset all terminal mode flags and scroll region to their VT100 defaults.
   Covers: cursor visibility, autowrap, charset, and the scroll region."
  (setf (screen-cursor-visible screen) t
        (screen-scroll-top screen) 0
        (screen-scroll-bottom screen) (1- (screen-height screen))
        (screen-charset screen) :ascii
        (screen-g0-charset screen) :ascii
        (screen-g1-charset screen) :ascii
        (screen-g2-charset screen) :ascii
        (screen-g3-charset screen) :ascii
        (screen-single-shift screen) nil
        (screen-active-g screen) :g0
        (screen-tab-stops screen) :default
        (screen-origin-mode screen) nil
        (screen-autowrap screen) t
        (screen-insert-mode screen) nil
        (screen-newline-mode screen) nil
        (screen-reverse-screen screen) nil
        (screen-pending-wrap screen) nil)
  (clrhash (screen-line-sizes screen)))

(defun ris-action (screen)
  "RIS — ESC c: hard terminal reset.
   Clears the entire cell grid, homes the cursor, resets all SGR attributes,
   cursor visibility, and restores the scroll region to the full screen height."
  (erase-region screen
                0
                0
                (1- (screen-width screen))
                (1- (screen-height screen)))
  (set-cursor screen 0 0)
  (reset-sgr-pen screen)
  (reset-terminal-modes screen))

(defun decstr-action (screen)
  "DECSTR — CSI ! p: soft terminal reset.  Restores modes and the SGR pen to their
   power-on defaults but, unlike RIS, does NOT clear the screen or move the cursor.
   Resets the SGR pen, the terminal modes (charset / origin / autowrap / insert /
   scroll region / cursor visibility / pending wrap / tab stops via
   reset-terminal-modes), application cursor keys, bracketed-paste mode, and the
   DECSC saved-cursor (a later DECRC then homes, per xterm)."
  (reset-sgr-pen screen)
  (reset-terminal-modes screen)
  (setf (screen-app-cursor-keys screen) nil
        (screen-bracketed-paste screen) nil
        (screen-saved-cursor screen) nil))

(defun decaln-action (screen)
  "DECALN — ESC # 8: fill the entire screen with 'E' (the VT100 screen-alignment
   test pattern, used by vttest and terminal conformance suites), then home the
   cursor.  Each cell becomes a default-attribute 'E'."
  (dotimes (y (screen-height screen))
    (dotimes (x (screen-width screen))
      (setf (screen-cell screen x y) (make-cell :char #\E))))
  (set-cursor screen 0 0)
  (setf (screen-dirty-p screen) t))
