(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(load (truename "nerimux.asd"))

(let ((root (asdf:registered-system "nerimux"))
      (seen (make-hash-table :test (function eq))))
  (labels ((walk (component depth)
             (let ((children (ignore-errors
                               (asdf:component-children component))))
               (format t "~V@T~S TYPE=~S CHILDREN=~D~%"
                       depth
                       (asdf:component-name component)
                       (type-of component)
                       (length children))
               (unless (gethash component seen)
                 (setf (gethash component seen) t)
                 (dolist (child children)
                   (walk child (+ depth 2)))))))
    (walk root 0)))

(finish-output)
