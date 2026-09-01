(in-package #:nerimux/terminal/sgr)

(defun %apply-sgr-parameters (screen parameters)
  "Consume PARAMETERS iteratively and apply each SGR arm to SCREEN."
  (let ((tail parameters))
    (loop while tail
          do (let ((parameter (first tail)))
               (cond
                 ((consp parameter)
                   (%apply-sgr-group screen parameter)
                   (setf tail (rest tail)))
                 ((member parameter '(38 48 58))
                  (setf tail (%apply-sgr-color-arm screen tail)))
                 (t
                   (%dispatch-sgr-code screen parameter)
                   (setf tail (rest tail))))))
    (values)))

(defun apply-sgr (screen params)
  "Apply SGR parameter values PARAMS to SCREEN; NIL means reset."
  (%apply-sgr-parameters screen (or params '(0))))
