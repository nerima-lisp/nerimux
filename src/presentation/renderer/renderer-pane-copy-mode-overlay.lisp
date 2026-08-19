(in-package #:nerimux/renderer)

;;;; Copy-mode position overlay rendering.

(defun %copy-mode-position-overlay-text (session pane)
  (let* ((ctx (nerimux/format:format-context-from-session session
                                                          (pane-window pane)
                                                          pane))
         (format-template (nerimux/options:get-option "copy-mode-position-format" ""))
         (style-template (nerimux/options:get-option "copy-mode-position-style" ""))
         (expanded-format (nerimux/format:expand-format format-template ctx))
         (expanded-style (nerimux/format:expand-format style-template ctx))
         (style-sgr (let ((trimmed (string-trim " " expanded-style)))
                      (unless (zerop (length trimmed))
                        (%status-sgr-from-style trimmed)))))
    (values expanded-format style-sgr)))

(defun %render-copy-mode-position-overlay (stream session pane origin-x origin-y pane-width)
  "Render the copy-mode position banner as a right-aligned overlay slice.
   Suppressed when the entry asked to hide it (copy-mode -H)."
  (when (and (screen-copy-mode-p (pane-screen pane))
             (not (screen-copy-hide-position (pane-screen pane)))
             (plusp pane-width))
    (multiple-value-bind (overlay-text style-sgr)
        (%copy-mode-position-overlay-text session pane)
      (when (plusp (length overlay-text))
        (reset-attrs stream)
        (move-to stream origin-y origin-x)
        (write-string (%compose-aligned-line overlay-text
                                             (or style-sgr (%status-sgr-from-style "default"))
                                             pane-width)
                      stream)
        (reset-attrs stream)))))
