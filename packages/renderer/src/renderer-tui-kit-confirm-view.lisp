(in-package #:nerimux/renderer)

(defstruct confirm-view
  "Data for one full-screen confirm or failure view."
  (operation "" :type string)
  (fields nil :type list)
  (prompt-p t :type boolean))

(defconstant +confirm-view-min-inner-width+
  20)

(defun %confirm-view-field-line (field)
  (format nil "~A: ~A" (car field) (cdr field)))

(defun %confirm-view-prompt-line (view)
  (if (confirm-view-prompt-p view)
      "y execute   n cancel"
      "press any key to continue"))

(defun %confirm-view-content-lines (view)
  "VIEW's content as plain (unstyled) text, one string per line -- used only
   to size the box (%CONFIRM-VIEW-BOX-RECTANGLE): colour does not change
   display width, so the styled draw below measures nothing itself."
  (append (mapcar #'%confirm-view-field-line (confirm-view-fields view))
          (list "")
          (list (%confirm-view-prompt-line view))))

(defun %confirm-view-box-rectangle (rows cols lines title)
  (let* ((content-width
          (reduce #'max (mapcar #'%display-width lines) :initial-value 0))
         (title-width (+ 2 (%display-width title)))
         (inner-width
          (max +confirm-view-min-inner-width+ content-width title-width))
         (width (min cols (+ inner-width 4)))
         (height (min rows (+ (length lines) 2)))
         (x (%center-coord cols width))
         (y (%center-coord rows height)))
    (cl-tui-kit/core:make-rectangle x y width height)))

;;; ── Styles (Dracula) ─────────────────────────────────────────────────────
;;;
;;; A confirm view is always about a consequential action (delete/lock/quit)
;;; or a failure, so its heading is styled danger red unconditionally rather
;;; than reading a severity field the struct does not have. FIELDS is
;;; (LABEL . VALUE): LABEL is the "key" role +SGR-ACCENT+ names elsewhere
;;; (renderer-style.lisp), VALUE stays in the surface's default style.
(defun %confirm-view-heading-style ()
  (cl-tui-kit/core:make-style :bold
                              t
                              :foreground
                              (cl-tui-kit/core:rgb-color 255 85 85)))

(defun %confirm-view-key-style ()
  (cl-tui-kit/core:make-style :foreground
                              (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %draw-confirm-view-field (surface row col field width)
  (cl-tui-kit/core:surface-draw-styled-text surface
                                            col
                                            row
                                            (list
                                             (cl-tui-kit/core:make-text-span
                                              (format nil "~A: " (car field))
                                              :style
                                              (%confirm-view-key-style))
                                             (cl-tui-kit/core:make-text-span
                                              (princ-to-string (cdr field))))
                                            :max-width
                                            width))

(defun %render-confirm-view-box (surface rectangle view)
  "Render RECTANGLE's border (an empty BOX-WIDGET child: per-line colour
   needs more than one style per row, which a TEXT-WIDGET cannot give), then
   draw VIEW's fields and prompt line directly onto the surface inside it."
  (let ((box
         (cl-tui-kit/widgets:make-box-widget
          (cl-tui-kit/widgets:make-text-widget "" :id :nerimux-confirm-body)
          :id
          :nerimux-confirm-box
          :border-kind
          :single)))
    (cl-tui-kit/widgets:render-widget box surface rectangle))
  (let* ((inner (%box-widget-inner-rectangle rectangle))
         (col (cl-tui-kit/core:rectangle-x inner))
         (width (cl-tui-kit/core:rectangle-width inner))
         (row (cl-tui-kit/core:rectangle-y inner)))
    (dolist (field (confirm-view-fields view))
      (%draw-confirm-view-field surface row col field width)
      (incf row))
    (incf row)
    (cl-tui-kit/core:surface-draw-text surface
                                       col
                                       row
                                       (%confirm-view-prompt-line view)
                                       :max-width
                                       width)))

(defun %stamp-confirm-view-title (surface rectangle title)
  (let* ((inner-width (max 0 (- (cl-tui-kit/core:rectangle-width rectangle) 4)))
         (text (%display-clip (format nil " ~A " title) inner-width)))
    (cl-tui-kit/core:surface-draw-text surface
                                       (+
                                        (cl-tui-kit/core:rectangle-x rectangle)
                                        2)
                                       (cl-tui-kit/core:rectangle-y rectangle)
                                       text
                                       :style
                                       (%confirm-view-heading-style))))

(defun render-confirm-view-to-tui-string (view rows cols)
  "Render VIEW as a full-screen bordered confirmation or failure frame."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (cl-tui-kit/core:make-surface cols rows))
         (lines (%confirm-view-content-lines view))
         (rectangle
          (%confirm-view-box-rectangle rows
                                       cols
                                       lines
                                       (confirm-view-operation view))))
    (%render-confirm-view-box surface rectangle view)
    (%stamp-confirm-view-title surface rectangle (confirm-view-operation view))
    (%surface-to-ansi-frame surface)))
