(in-package #:nerimux/test)

(describe "window record declarations"
  (it "expands records in declaration order without evaluating them"
    (let* ((expansion
             (macroexpand-1
              '(nerimux/model::define-window-records
                (first-record "first" (value 1))
                ((second-record (:constructor make-second-record))
                 "second"
                 (value 2)))))
           (definitions (rest expansion)))
      (expect (first expansion) :to-equal 'progn)
      (expect (mapcar #'first definitions) :to-equal '(defstruct defstruct))
      (expect (mapcar #'second definitions)
              :to-equal
              '(first-record
                (second-record (:constructor make-second-record)))))))
