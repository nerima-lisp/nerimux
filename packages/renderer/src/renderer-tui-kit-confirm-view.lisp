(in-package #:nerimux/renderer)

(defun %bottom-panel-rectangle (rows cols content-rows)
  "A full-width panel anchored at the bottom edge of a ROWS x COLS frame,
   tall enough for CONTENT-ROWS plus its two border rows. Every modal this
   renderer draws over a view -- the confirm view, the transients, the text
   prompts, the read view's search box -- is one of these, so they all share
   the geometry rather than each inventing a rectangle."
  (let ((height (min rows (+ content-rows 2))))
    (cl-tui-kit/core:make-rectangle 0 (- rows height) cols height)))

(defun %panel-inner-rectangle (rectangle)
  "RECTANGLE inside its border. Unlike %BOX-WIDGET-INNER-RECTANGLE this keeps
   no padding ring: a panel is sized to its content, so padding would be a
   blank line nobody asked for."
  (cl-tui-kit/core:rectangle-inset rectangle
                                   (cl-tui-kit/core:make-padding :all 1)))

(defun %panel-text-rectangle (rectangle)
  "RECTANGLE with a one-column margin either side, for content read as text
   rather than drawn as a widget: a line flush against the border is hard to
   read and hard to tell from the border itself."
  (cl-tui-kit/core:rectangle-inset rectangle
                                   (cl-tui-kit/core:make-padding :left 1
                                                                 :right 1
                                                                 :top 0
                                                                 :bottom 0)))

(defun %panel-base-surface (base-frame rows cols)
  "The surface a panel draws onto: the view underneath it, read back from its
   own rendered frame, so the panel hides only the rows it covers. A blank
   surface when the caller has no frame to hand over."
  (if base-frame
      (%surface-from-ansi-frame base-frame rows cols)
      (cl-tui-kit/core:make-surface cols rows)))

(defun %stamp-panel-title (surface rectangle title &optional style)
  (let* ((inner-width (max 0 (- (cl-tui-kit/core:rectangle-width rectangle) 4)))
         (text (%display-clip (format nil " ~A " title) inner-width)))
    (cl-tui-kit/core:surface-draw-text surface
                                       (+
                                        (cl-tui-kit/core:rectangle-x rectangle)
                                        2)
                                       (cl-tui-kit/core:rectangle-y rectangle)
                                       text
                                       :style
                                       style)))

(defun %draw-panel-frame (surface rectangle title &optional title-style)
  "Clear RECTANGLE, draw its border and label it TITLE; answer the rectangle
   the panel's content goes in."
  (cl-tui-kit/core:surface-clear surface rectangle)
  (cl-tui-kit/core:surface-draw-border surface rectangle :kind :single)
  (%stamp-panel-title surface rectangle title title-style)
  (%panel-inner-rectangle rectangle))

(defstruct confirm-view
  "Data for one confirm or failure panel."
  (operation "" :type string)
  (fields nil :type list)
  (prompt-p t :type boolean))

(defun %confirm-view-field-line (field)
  (format nil "~A: ~A" (car field) (cdr field)))

(defun %confirm-view-prompt-line (view)
  (if (confirm-view-prompt-p view)
      "y execute   n/q/Esc cancel"
      "press any key to continue"))

(defun %confirm-view-content-lines (view)
  "VIEW's content as plain (unstyled) text, one string per line -- used only
   to size the panel (%BOTTOM-PANEL-RECTANGLE): colour does not change
   display width, so the styled draw below measures nothing itself."
  (append (mapcar #'%confirm-view-field-line (confirm-view-fields view))
          (list "")
          (list (%confirm-view-prompt-line view))))

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

(defun %draw-confirm-view-content (surface rectangle view)
  "Draw VIEW's fields and prompt line into RECTANGLE, which is the panel
   inside its border."
  (let ((col (cl-tui-kit/core:rectangle-x rectangle))
        (width (cl-tui-kit/core:rectangle-width rectangle))
        (row (cl-tui-kit/core:rectangle-y rectangle)))
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

(defun render-confirm-view-to-tui-string (view rows cols &optional base-frame)
  "Render VIEW as a bordered panel anchored at the frame's bottom edge, tall
   enough for its fields and prompt and no taller. BASE-FRAME, when the caller
   passes the frame of the view being confirmed, stays visible above it."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (%panel-base-surface base-frame rows cols))
         (lines (%confirm-view-content-lines view))
         (rectangle (%bottom-panel-rectangle rows cols (length lines))))
    (%draw-confirm-view-content surface
                                (%panel-text-rectangle
                                 (%draw-panel-frame surface
                                                    rectangle
                                                    (confirm-view-operation view)
                                                    (%confirm-view-heading-style)))
                                view)
    (%surface-to-ansi-frame surface)))
