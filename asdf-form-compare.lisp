(defparameter *end* (gensym "END"))

(defun read-forms (pathname)
  (with-open-file (stream (truename pathname))
    (let ((*package* (find-package :asdf-user))
          (forms nil))
      (loop for form = (read stream nil *end*)
            until (eq form *end*)
            do (push form forms))
      (nreverse forms))))

(let* ((main (third (read-forms "nerimux.asd")))
       (metadata (second (read-forms "asdf-metadata-module-probe.asd")))
       (main-options (cddr main))
       (metadata-options (cddr metadata)))
  (format t "MAIN=~S~%" (list (car main) (second main)))
  (format t "MAIN-OPTIONS-COUNT=~D METADATA-OPTIONS-COUNT=~D~%"
          (/ (length main-options) 2)
          (/ (length metadata-options) 2))
  (loop for (key value) on main-options by #'cddr
        for other = (getf metadata-options key)
        do (format t "KEY=~S MAIN-TYPE=~S OTHER-TYPE=~S EQUAL=~S~%"
                   key (type-of value) (type-of other) (equal value other)))
  (format t "MAIN-COMPONENTS=~S~%"
          (list (length (getf main-options :components))
                (first (getf main-options :components))))
  (format t "METADATA-COMPONENTS=~S~%"
          (getf metadata-options :components))
  (format t "MAIN-DEPENDS=~S~%" (getf main-options :depends-on))
  (format t "METADATA-DEPENDS=~S~%" (getf metadata-options :depends-on)))
