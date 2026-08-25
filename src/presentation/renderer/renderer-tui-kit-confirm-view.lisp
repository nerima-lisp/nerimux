(in-package #:nerimux/renderer)

(defstruct confirm-view
  "Data for one full-screen confirm or failure view."
  (operation "" :type string)
  (fields nil :type list)
  (prompt-p t :type boolean))

(defconstant +confirm-view-min-inner-width+ 20)

(defun %confirm-view-content-lines (view)
  (append
   (mapcar (lambda (field) (format nil "~A: ~A" (car field) (cdr field)))
           (confirm-view-fields view))
   (list "")
   (list (if (confirm-view-prompt-p view)
             "y execute   n cancel"
             "press any key to continue"))))

(defun %confirm-view-box-rectangle (rows cols lines title)
  (let* ((content-width (reduce #'max (mapcar #'%display-width lines)
                                :initial-value 0))
         (title-width (+ 2 (%display-width title)))
         (inner-width (max +confirm-view-min-inner-width+
                           content-width title-width))
         (width (min cols (+ inner-width 4)))
         (height (min rows (+ (length lines) 2)))
         (x (%center-coord cols width))
         (y (%center-coord rows height)))
    (cl-tui-kit/core:make-rectangle x y width height)))

(defun %render-confirm-view-box (surface rectangle lines)
  (let* ((body (cl-tui-kit/widgets:make-form-widget
                (mapcar #'cl-tui-kit/widgets:make-text-widget lines)
                :id :nerimux-confirm-body))
         (box (cl-tui-kit/widgets:make-box-widget
               body :id :nerimux-confirm-box :border-kind :single)))
    (cl-tui-kit/widgets:render-widget box surface rectangle)))

(defun %stamp-confirm-view-title (surface rectangle title)
  (let* ((inner-width (max 0 (- (cl-tui-kit/core:rectangle-width rectangle) 4)))
         (text (%display-clip (format nil " ~A " title) inner-width)))
    (cl-tui-kit/core:surface-draw-text
     surface
     (+ (cl-tui-kit/core:rectangle-x rectangle) 2)
     (cl-tui-kit/core:rectangle-y rectangle)
     text)))

(defun render-confirm-view-to-tui-string (view rows cols)
  "Render VIEW as a full-screen bordered confirmation or failure frame."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (surface (cl-tui-kit/core:make-surface cols rows))
         (lines (%confirm-view-content-lines view))
         (rectangle (%confirm-view-box-rectangle
                     rows cols lines (confirm-view-operation view))))
    (%render-confirm-view-box surface rectangle lines)
    (%stamp-confirm-view-title surface rectangle (confirm-view-operation view))
    (%surface-to-ansi-frame surface)))
