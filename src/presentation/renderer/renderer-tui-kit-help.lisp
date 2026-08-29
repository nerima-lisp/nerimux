(in-package #:nerimux/renderer)

;;;; The `?` full-screen help view (FR-005): a static, Dracula-styled key
;;;; reference. Sibling of renderer-tui-kit-confirm-view.lisp -- a bordered
;;;; box spanning the whole frame instead of a centred one, and content drawn
;;;; as styled spans (section headings in +sgr-section+'s Dracula purple, keys
;;;; in +sgr-accent+'s Dracula cyan) rather than confirm-view's plain
;;;; text-widget lines, since a single row here mixes both colours.
;;;;
;;;; Content is hardcoded (this project has no config to read it from, R2.4)
;;;; and verified against the live dispatch tables it documents:
;;;; %HANDLE-CLIENT-NORMAL-KEY-PAYLOAD (server-multi-dispatch-command-
;;;; input.lisp) for Overview, %WORKSPACE-PREFIX-DISPATCH (server-multi-
;;;; dispatch-prefix.lisp) for the C-q prefix table, and
;;;; %TRANSITION-CLIENT-UI-MODE (server-multi-dispatch-command-workspace.lisp)
;;;; for each mode's enter/leave key.

(defparameter +help-view-sections+
  '(("Overview"
     (("j/k" . "move") ("J/K" . "section") ("Enter" . "open/dive")
      ("Tab" . "expand") ("h/l" . "fold") ("/" . "filter")
      ("n" . "new worktree") ("X" . "delete") ("L/U" . "lock/unlock")
      ("r" . "refresh") ("o" . "overview") ("d" . "detail")
      ("i" . "input") ("c" . "copy") (":" . "command")
      ("C-p" . "picker") ("?" . "help")))
    ("Prefix C-q"
     (("-" . "split down") ("|" . "split right") ("x" . "close pane")
      ("z" . "zoom") ("h/j/k/l" . "focus") ("n/p" . "cycle window")
      ("F" . "fetch repo") ("C-f" . "fetch org") ("d" . "detach")
      ("Q" . "quit server")))
    ("Modes"
     (("normal" . "default mode; i/c/:/C-p enter input/copy/command/picker")
      ("input" . "enter: i -- leave: C-q C-q (no key exit of its own)")
      ("copy" . "enter: c -- leave: q")
      ("command" . "enter: : -- leave: Enter submits, Esc cancels")
      ("picker" . "enter: C-p -- leave: Enter selects, Esc cancels"))))
  "The help view's static content: (SECTION-HEADING BINDINGS), BINDINGS a
   list of (KEY . DESCRIPTION).")

;;; ── Styles ───────────────────────────────────────────────────────────────
;;;
;;; Built from the same Dracula RGB triples as +SGR-SECTION+/+SGR-ACCENT+
;;; (renderer-style.lisp), as CL-TUI-KIT/CORE:STYLE objects rather than SGR
;;; parameter strings -- this view draws styled spans directly onto the
;;; surface (%MAKE-WORKSPACE-TREE-THEME's :ACCENT role, renderer-tui-kit-
;;; widgets.lisp, is the same pattern), not through the plain-ANSI path those
;;; string constants serve.

(defun %help-view-heading-style ()
  (cl-tui-kit/core:make-style
   :bold t
   :foreground (cl-tui-kit/core:rgb-color 189 147 249)))

(defun %help-view-key-style ()
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 139 233 253)))

;;; ── Layout ───────────────────────────────────────────────────────────────

(defun %help-view-binding-text (key description)
  (format nil "~A ~A" key description))

(defun %help-view-section-item-width (bindings)
  "One item's column width: its longest 'KEY DESCRIPTION' pair plus a 2-column
   gutter, so a section of short Overview/Prefix bindings packs several per
   row while Modes' long descriptions still get a row of their own -- no
   fixed magic-number column width to keep in sync with the content above."
  (+ 2 (reduce #'max bindings
               :key (lambda (binding)
                      (%display-width
                       (%help-view-binding-text (car binding) (cdr binding))))
               :initial-value 0)))

(defun %help-view-section-columns (bindings available-width)
  (max 1 (min 3 (floor (max 1 available-width)
                       (%help-view-section-item-width bindings)))))

(defun %draw-help-view-heading (surface row col text width)
  (cl-tui-kit/core:surface-draw-styled-text
   surface col row
   (list (cl-tui-kit/core:make-text-span text :style (%help-view-heading-style)))
   :max-width width))

(defun %draw-help-view-binding (surface row col key description width)
  (cl-tui-kit/core:surface-draw-styled-text
   surface col row
   (list (cl-tui-kit/core:make-text-span key :style (%help-view-key-style))
         (cl-tui-kit/core:make-text-span (format nil " ~A" description)))
   :max-width width))

(defun %draw-help-view-section (surface row indent available-width max-row section)
  "Draw SECTION -- (HEADING BINDINGS) -- starting at ROW, indented INDENT
   columns, wrapping BINDINGS into %HELP-VIEW-SECTION-COLUMNS side-by-side
   item columns. Returns the next free row. Drawing stops (silently clipping
   any remainder) once ROW exceeds MAX-ROW -- the box's bottom border row --
   rather than overflowing it; this view has no scroll of its own."
  (destructuring-bind (heading bindings) section
    (when (<= row max-row)
      (%draw-help-view-heading surface row indent heading available-width)
      (incf row))
    (let* ((item-width (%help-view-section-item-width bindings))
           (columns (%help-view-section-columns bindings available-width)))
      (loop for start from 0 below (length bindings) by columns
            while (<= row max-row)
            do (loop for offset from 0 below columns
                     for index = (+ start offset)
                     while (< index (length bindings))
                     do (destructuring-bind (key . description)
                            (nth index bindings)
                          (%draw-help-view-binding
                           surface row (+ indent (* offset item-width))
                           key description item-width)))
               (incf row)))
    (1+ row)))

;;; ── Box chrome ───────────────────────────────────────────────────────────

(defun %render-help-view-box (surface rectangle)
  (let ((box (cl-tui-kit/widgets:make-box-widget
              (cl-tui-kit/widgets:make-text-widget "" :id :nerimux-help-body)
              :id :nerimux-help-box :border-kind :single)))
    (cl-tui-kit/widgets:render-widget box surface rectangle)))

(defun %stamp-help-view-title (surface rectangle title)
  (let* ((inner-width (max 0 (- (cl-tui-kit/core:rectangle-width rectangle) 4)))
         (text (%display-clip (format nil " ~A " title) inner-width)))
    (cl-tui-kit/core:surface-draw-text
     surface
     (+ (cl-tui-kit/core:rectangle-x rectangle) 2)
     (cl-tui-kit/core:rectangle-y rectangle)
     text)))

(defun %stamp-help-view-footer (surface rectangle hint)
  (let* ((width (cl-tui-kit/core:rectangle-width rectangle))
         (text (%display-clip (format nil " ~A " hint) (max 0 (- width 4))))
         (x (max (+ (cl-tui-kit/core:rectangle-x rectangle) 2)
                 (- (+ (cl-tui-kit/core:rectangle-x rectangle) width)
                    2 (%display-width text)))))
    (cl-tui-kit/core:surface-draw-text
     surface x
     (+ (cl-tui-kit/core:rectangle-y rectangle)
        (1- (cl-tui-kit/core:rectangle-height rectangle)))
     text)))

(defun render-help-view-to-tui-string (rows cols)
  "Render the `?` full-screen help view: a Dracula-styled static reference
   covering the overview/detail keymap, the C-q prefix table, and each UI
   mode's enter/leave key."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (cl-tui-kit/core:make-surface cols rows))
         (rectangle (cl-tui-kit/core:make-rectangle 0 0 cols rows))
         (inner (%box-widget-inner-rectangle rectangle))
         (indent (cl-tui-kit/core:rectangle-x inner))
         (available-width (cl-tui-kit/core:rectangle-width inner))
         (max-row (max (cl-tui-kit/core:rectangle-y inner)
                       (1- (+ (cl-tui-kit/core:rectangle-y inner)
                              (cl-tui-kit/core:rectangle-height inner))))))
    (%render-help-view-box surface rectangle)
    (%stamp-help-view-title surface rectangle "HELP")
    (%stamp-help-view-footer surface rectangle "q / ? / Enter / Esc close")
    (let ((row (cl-tui-kit/core:rectangle-y inner)))
      (dolist (section +help-view-sections+)
        (setf row (%draw-help-view-section
                   surface row indent available-width max-row section))))
    (%surface-to-ansi-frame surface)))
