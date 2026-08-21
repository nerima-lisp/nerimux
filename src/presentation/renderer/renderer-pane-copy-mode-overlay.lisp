(in-package #:nerimux/renderer)

;;;; Copy-mode position overlay rendering.

(defun %copy-mode-position-overlay-text (pane)
  "Position text for PANE's copy-mode overlay: \"[POS/LIMIT]\", with
   \" /TERM\" appended while a search is active.

   R6.8 (docs/notes/workspace-requirements.md) replaces the 200+ character
   copy-mode-position-format template and the mode-style-indirected
   copy-mode-position-style with direct string composition — both options
   are gone along with domain/format and domain/options (R2.3/R2.2).

   docs/notes/workspace-requirements.md §R6.8 illustrates the target as
   \"[12/3400] /pattern 2/7\", i.e. with a \"current match/total matches\"
   ordinal.  This omits that ordinal: nothing in this codebase counts
   matches across the whole scrollback today — %all-match-ranges
   (renderer-pane-search.lisp) only scans the currently visible viewport,
   once per frame, purely to paint highlights, and has no per-match index.
   Adding a real counter means indexing the whole search, which is new
   domain-level tracking, not a template→string-composition swap; it is
   left to R6.8's own implementation rather than faked here as a constant."
  (let* ((screen (pane-screen pane))
         (pos    (screen-copy-offset screen))
         (limit  (length (screen-scrollback screen)))
         (term   (screen-copy-search-term screen)))
    (format nil "[~D/~D]~@[ /~A~]"
            pos limit (and term (plusp (length term)) term))))

(defun %render-copy-mode-position-overlay (stream pane origin-x origin-y pane-width)
  "Render the copy-mode position banner as a right-aligned overlay slice.
   Suppressed when the entry asked to hide it (copy-mode -H)."
  (when (and (screen-copy-mode-p (pane-screen pane))
             (not (screen-copy-hide-position (pane-screen pane)))
             (plusp pane-width))
    (let ((overlay-text (%copy-mode-position-overlay-text pane)))
      (when (plusp (length overlay-text))
        (reset-attrs stream)
        (move-to stream origin-y origin-x)
        (write-string (%compose-aligned-line overlay-text +sgr-default-status+ pane-width)
                      stream)
        (reset-attrs stream)))))
