(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(require :sb-posix)

(let* ((root (first (uiop:split-string (uiop:getenv "NERIMUX_SIBLING_REGISTRY")
                                       :separator ":")))
       (path (merge-pathnames "cl-weave.asd"
                              (uiop:ensure-directory-pathname root))))
  (with-open-file (stream path)
    (let ((*package* (find-package :asdf-user))
          (first-form (read stream nil :eof)))
      (declare (ignore first-form))
      (loop for index from 2
            for form = (read stream nil :eof)
            until (eq form :eof)
            do (format t "~&Before form ~D ~S~%" index (car form))
               (finish-output)
               (let ((*load-truename* path)
                     (*load-pathname* path))
                 (eval form))
               (format t "~&After form ~D~%" index)
               (finish-output)))))

(format t "~&All forms evaluated~%")
(finish-output)
