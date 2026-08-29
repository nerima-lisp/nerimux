(in-package #:nerimux/renderer)

;;;; The magit-style transient menu (FR-010). Deliberately NOT an overlay --
;;;; this project forbids popups -- so RENDER-TRANSIENT-PANEL draws straight
;;;; onto whatever surface the caller already owns, growing the bottom key
;;;; panel in place exactly the way the plain key hints already do in
;;;; renderer-workspace.lisp's %WORKSPACE-KEY-PANEL-CONTENT. Sibling of
;;;; renderer-tui-kit-confirm-view.lisp: bootstrap builds the TRANSIENT-VIEW
;;;; struct and owns every action's closure, this package only draws it.
;;;;
;;;; RENDER-TRANSIENT-FULL-SCREEN-TO-TUI-STRING is the HEIGHT FALLBACK only
;;;; (contract §3): when the frame cannot spare TRANSIENT-VIEW-HEIGHT rows for
;;;; the in-place panel, the caller reaches for this instead, which wraps the
;;;; identical content in a full-screen bordered box (confirm-view/help-view's
;;;; shape) rather than drawing anything different.

(defstruct transient-view
  "One open transient menu. ARGUMENTS is a list of (KEY FLAG DESCRIPTION
   ACTIVE-P TRANSIENT-KEY) and ACTIONS a list of (KEY DESCRIPTION HANDLER) --
   one element longer, in both cases, than the contract's documented (KEY FLAG
   DESCRIPTION ACTIVE-P) / (KEY DESCRIPTION) shape. This renderer only ever
   reads the first four / first two elements positionally (see the drawing
   helpers below), so the trailing element -- the flag's owning transient key,
   and the action's dispatch HANDLER, respectively -- rides along harmlessly
   for server-multi-dispatch-transient.lisp, which needs it to persist toggle
   state and run an action without a second lookup, and has no other slot to
   keep it in without a new cross-package export."
  (title "" :type string)
  (subtitle nil)
  (arguments nil :type list)
  (actions nil :type list))

;;; ── Styles (Dracula) ─────────────────────────────────────────────────────

(defun %transient-title-style ()
  (cl-tui-kit/core:make-style
   :bold t
   :foreground (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %transient-subtitle-style ()
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 98 114 164)))

(defun %transient-section-style ()
  (cl-tui-kit/core:make-style
   :bold t
   :foreground (cl-tui-kit/core:rgb-color 189 147 249)))

(defun %transient-key-style ()
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %transient-argument-active-style ()
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 80 250 123)))

(defun %transient-argument-inactive-style ()
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 98 114 164)))

;;; ── Layout ───────────────────────────────────────────────────────────────

(defun %transient-pad (text width)
  "TEXT padded with spaces to WIDTH display columns.  Never truncates -- every
   text this is called on is already sized into WIDTH by the column-width
   helpers below, so a shortfall here would signal a computation bug rather
   than genuinely overlong content."
  (let ((pad (- width (%display-width text))))
    (if (plusp pad)
        (concatenate 'string text (make-string pad :initial-element #\Space))
        text)))

(defun %transient-column-width (texts gutter)
  (+ gutter (reduce #'max texts :key #'%display-width :initial-value 0)))

(defun %transient-argument-key-text (entry)
  (format nil "-~C" (first entry)))

(defun %transient-draw-title-line (surface row col width view)
  (let ((spans (list (cl-tui-kit/core:make-text-span
                       (transient-view-title view)
                       :style (%transient-title-style)))))
    (when (transient-view-subtitle view)
      (setf spans
            (append spans
                    (list (cl-tui-kit/core:make-text-span
                           (format nil "  ~A" (transient-view-subtitle view))
                           :style (%transient-subtitle-style))))))
    (cl-tui-kit/core:surface-draw-styled-text surface col row spans :max-width width)))

(defun %transient-draw-section-heading (surface row col width text)
  (cl-tui-kit/core:surface-draw-styled-text
   surface col row
   (list (cl-tui-kit/core:make-text-span text :style (%transient-section-style)))
   :max-width width))

(defun %transient-draw-argument-row (surface row col width entry key-width desc-width)
  "ENTRY is (KEY FLAG DESCRIPTION ACTIVE-P . REST) -- see TRANSIENT-VIEW's
   docstring for why a longer list is fine here: DESCRIPTION (third) is what
   is shown, FLAG (second) is what server-multi-dispatch-transient.lisp
   assembles into the actual git argument list."
  (let* ((key-text (%transient-argument-key-text entry))
         (description (third entry))
         (active-p (fourth entry)))
    (cl-tui-kit/core:surface-draw-styled-text
     surface col row
     (list (cl-tui-kit/core:make-text-span
            (%transient-pad key-text key-width) :style (%transient-key-style))
           (cl-tui-kit/core:make-text-span (%transient-pad description desc-width))
           (cl-tui-kit/core:make-text-span
            (if active-p "[x]" "[ ]")
            :style (if active-p (%transient-argument-active-style)
                       (%transient-argument-inactive-style))))
     :max-width width)))

(defun %transient-draw-action-row (surface row col width entry key-width)
  "ENTRY is (KEY DESCRIPTION . REST) -- REST is the dispatch HANDLER, unread
   here; see TRANSIENT-VIEW's docstring."
  (let ((key-text (string (first entry)))
        (description (second entry)))
    (cl-tui-kit/core:surface-draw-styled-text
     surface col row
     (list (cl-tui-kit/core:make-text-span
            (%transient-pad key-text key-width) :style (%transient-key-style))
           (cl-tui-kit/core:make-text-span description))
     :max-width width)))

(defun transient-view-height (transient-view)
  "Rows TRANSIENT-VIEW wants: the title/subtitle line, an optional Arguments
   heading + one row per argument, the Actions heading + one row per action,
   and a trailing \"q back\" line. The caller clamps this against what the
   frame can actually spare; when it cannot,
   RENDER-TRANSIENT-FULL-SCREEN-TO-TUI-STRING is the fallback (contract §3)."
  (+ 1
     (if (transient-view-arguments transient-view)
         (1+ (length (transient-view-arguments transient-view)))
         0)
     1
     (length (transient-view-actions transient-view))
     1))

(defun render-transient-panel (surface rectangle transient-view)
  "Draw TRANSIENT-VIEW into RECTANGLE, top to bottom, clipping (rather than
   scrolling or erroring) once RECTANGLE runs out of rows -- same policy as
   %DRAW-HELP-VIEW-SECTION. This is the bottom key panel EXPANDED: no border,
   no background fill of its own, just the same styled rows a taller key
   panel would have drawn, so it composes with whatever the caller already
   put on the surface above RECTANGLE."
  (let* ((x (cl-tui-kit/core:rectangle-x rectangle))
         (y (cl-tui-kit/core:rectangle-y rectangle))
         (width (cl-tui-kit/core:rectangle-width rectangle))
         (max-row (1- (+ y (cl-tui-kit/core:rectangle-height rectangle))))
         (arguments (transient-view-arguments transient-view))
         (actions (transient-view-actions transient-view))
         (row y))
    (flet ((room-p () (<= row max-row))
           (heading-width () (max 0 (- width 1)))
           (item-width () (max 0 (- width 2))))
      (when (room-p)
        (%transient-draw-title-line surface row (1+ x) (heading-width) transient-view)
        (incf row))
      (when arguments
        (when (room-p)
          (%transient-draw-section-heading surface row (1+ x) (heading-width) "Arguments")
          (incf row))
        (let ((key-width (%transient-column-width
                           (mapcar #'%transient-argument-key-text arguments) 2))
              (desc-width (%transient-column-width (mapcar #'third arguments) 3)))
          (dolist (entry arguments)
            (when (room-p)
              (%transient-draw-argument-row surface row (+ x 2) (item-width)
                                             entry key-width desc-width)
              (incf row)))))
      (when (room-p)
        (%transient-draw-section-heading surface row (1+ x) (heading-width) "Actions")
        (incf row))
      (let ((key-width (%transient-column-width
                         (mapcar (lambda (entry) (string (first entry))) actions) 3)))
        (dolist (entry actions)
          (when (room-p)
            (%transient-draw-action-row surface row (+ x 2) (item-width) entry key-width)
            (incf row))))
      (when (room-p)
        (cl-tui-kit/core:surface-draw-styled-text
         surface (1+ x) row
         (list (cl-tui-kit/core:make-text-span "q" :style (%transient-key-style))
               (cl-tui-kit/core:make-text-span " back"))
         :max-width (heading-width))))))

;;; ── Full-screen height fallback ──────────────────────────────────────────

(defun %render-transient-view-box (surface rectangle)
  (let ((box (cl-tui-kit/widgets:make-box-widget
              (cl-tui-kit/widgets:make-text-widget "" :id :nerimux-transient-body)
              :id :nerimux-transient-box :border-kind :single)))
    (cl-tui-kit/widgets:render-widget box surface rectangle)))

(defun %stamp-transient-view-title (surface rectangle title)
  (let* ((inner-width (max 0 (- (cl-tui-kit/core:rectangle-width rectangle) 4)))
         (text (%display-clip (format nil " ~A " title) inner-width)))
    (cl-tui-kit/core:surface-draw-text
     surface
     (+ (cl-tui-kit/core:rectangle-x rectangle) 2)
     (cl-tui-kit/core:rectangle-y rectangle)
     text)))

(defun render-transient-full-screen-to-tui-string (transient-view rows cols)
  "Height-fallback path only (contract §3): the exact content
   RENDER-TRANSIENT-PANEL draws, inside a full-screen bordered box -- the
   border's own generic \"TRANSIENT\" title, since TRANSIENT-VIEW's own title
   already appears as the body's first line."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (cl-tui-kit/core:make-surface cols rows))
         (rectangle (cl-tui-kit/core:make-rectangle 0 0 cols rows)))
    (%render-transient-view-box surface rectangle)
    (%stamp-transient-view-title surface rectangle "TRANSIENT")
    (render-transient-panel surface (%box-widget-inner-rectangle rectangle) transient-view)
    (%surface-to-ansi-frame surface)))
