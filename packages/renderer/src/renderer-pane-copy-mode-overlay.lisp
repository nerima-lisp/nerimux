(in-package #:nerimux/renderer)

(defun %copy-mode-position-overlay-text (pane)
  "Position text for PANE's copy-mode overlay (R6.8): \"[POS/LIMIT]\", plus
   \" /TERM\" while a search is active, plus \" INDEX/TOTAL\" naming which match
   the cursor is on — \"[12/3400] /pattern 2/7\".

   This replaces a 200+ character copy-mode-position-format template and the
   mode-style-indirected copy-mode-position-style with direct composition; both
   options went with domain/format and domain/options (R2.3/R2.2).

   The ordinal is read from the screen, not computed here. Counting matches is a
   full scan of the scrollback, and this runs on every frame."
  (let* ((screen (pane-screen pane))
         (pos    (screen-copy-offset screen))
         (limit  (length (screen-scrollback screen)))
         (term   (screen-copy-search-term screen))
         (active (when (and term (plusp (length term))) term))
         (index  (screen-copy-search-index screen))
         (total  (screen-copy-search-total screen)))
    (format nil "[~D/~D]~@[ /~A~]~@[ ~A~]"
            pos limit active
            (and active index (plusp total)
                 (format nil "~D/~D" index total)))))

(defun %render-copy-mode-position-overlay (stream pane
                                                  origin-x
                                                  origin-y
                                                  pane-width)
  "Render the copy-mode position banner as a right-aligned overlay slice.
   Suppressed when the entry asked to hide it (copy-mode -H)."
  (when 
      (and (screen-copy-mode-p (pane-screen pane))
           (not (screen-copy-hide-position (pane-screen pane)))
           (plusp pane-width))
    (let ((overlay-text (%copy-mode-position-overlay-text pane)))
      (when (plusp (length overlay-text))
        (reset-attrs stream)
        (move-to stream origin-y origin-x)
        (write-string
         (%compose-aligned-line overlay-text +sgr-default-status+ pane-width)
         stream)
        (reset-attrs stream)))))
