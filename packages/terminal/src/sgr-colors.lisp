(in-package #:nerimux/terminal/sgr)

(declaim (inline %encode-truecolor-rgb))
(defun %encode-truecolor-rgb (red green blue)
  "Clamp and encode RGB components in the terminal true-colour representation."
  (logior +true-color-flag+
          (ash (clamp (or red 0) 0 255) 16)
          (ash (clamp (or green 0) 0 255) 8)
          (clamp (or blue 0) 0 255)))

(declaim (inline %set-truecolor))
(defun %set-truecolor (screen setter parameter-list)
  "Store the true-colour triple in PARAMETER-LIST and return its unconsumed tail."
  (funcall setter
           (%encode-truecolor-rgb (third parameter-list)
                                  (fourth parameter-list)
                                  (fifth parameter-list))
           screen)
  (nthcdr 5 parameter-list))

(declaim (inline %consume-256-color-param))
(defun %consume-256-color-param (screen setter parameter-tail)
  "Store a 256-colour parameter and return its unconsumed tail."
  (funcall setter (clamp (third parameter-tail) 0 255) screen)
  (cdddr parameter-tail))

(defun %sgr-lead-setter (lead)
  "Return the colour setter selected by extended-colour LEAD."
  (case lead
    (38 #'(setf screen-cur-fg))
    (48 #'(setf screen-cur-bg))
    (58 #'(setf screen-cur-ul-color))))

(defun %apply-sgr-group (screen group)
  "Apply one colon-delimited SGR parameter GROUP to SCREEN."
  (let ((lead (first group))
        (kind (second group))
        (setter (%sgr-lead-setter (first group))))
    (cond
      ((and setter (eql kind 2) (>= (length group) 5))
       (let ((rgb (last group 3)))
         (funcall setter
                  (%encode-truecolor-rgb (first rgb) (second rgb) (third rgb))
                  screen)))
      ((and setter (eql kind 5) (>= (length group) 3))
       (funcall setter (clamp (or (car (last group)) 0) 0 255) screen))
      (t (%dispatch-sgr-code screen lead)))))

(defun %apply-sgr-color-arm (screen tail)
  "Apply an extended-colour arm at TAIL and return its unconsumed tail."
  (let* ((lead (first tail))
         (kind (second tail))
         (setter (%sgr-lead-setter lead)))
    (cond
      ((and setter (eql kind 5) (third tail))
       (%consume-256-color-param screen setter tail))
      ((and setter (eql kind 2) (cddr tail))
       (%set-truecolor screen setter tail))
      (t
       (%dispatch-sgr-code screen lead)
       (rest tail)))))
