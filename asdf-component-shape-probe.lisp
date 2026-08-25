(require :asdf)

(defparameter *end* (gensym "END"))

(with-open-file (stream (truename "nerimux.asd"))
  (let ((*package* (find-package :asdf-user))
        (forms nil))
    (loop repeat 3
          do (push (read stream nil *end*) forms))
    (setf forms (nreverse forms))
    (let* ((main (third forms))
           (src (first (getf (cddr main) :components)))
           (child (first (getf (cddr src) :components)))
           (components (getf (cddr child) :components))
           (fresh '((:file "package")))
           (child-copy (copy-tree child)))
      (format t "MAIN-TYPE=~S SRC-TYPE=~S CHILD-TYPE=~S~%"
              (type-of main) (type-of src) (type-of child))
      (format t "CHILD=~S~%" child)
      (format t "COMPONENTS=~S FRESH=~S~%" components fresh)
      (format t "EQUAL=~S TREE-EQUAL=~S EQUALP=~S EQ=~S~%"
              (equal components fresh)
              (tree-equal components fresh)
              (equalp components fresh)
              (eq components fresh))
      (format t "COMPONENTS-LENGTH=~S LIST-LENGTH=~S FRESH-LENGTH=~S~%"
              (length components) (list-length components) (length fresh))
      (format t "COMPONENT-TAILS=~S~%"
              (loop for tail on components
                    collect (list (type-of tail) (consp tail)
                                  (eq tail components)
                                  (eq (car tail) (car components)))))
      (format t "COPY-EQUAL=~S COPY-EQ=~S COPY-COMPONENTS-EQ=~S~%"
              (equal child child-copy)
              (eq child child-copy)
              (eq (getf (cddr child) :components)
                  (getf (cddr child-copy) :components)))
      (format t "HAS-CIRCLE=~S~%"
              (handler-case
                  (progn
                    (let ((*print-circle* t)) (write child :stream nil))
                    nil)
                (error () t))))))
