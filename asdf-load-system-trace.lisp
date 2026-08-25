(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(require :sb-posix)

(trace asdf/operate:load-system
       asdf/operate:operate
       asdf/action:perform
       asdf/plan:perform-plan
       asdf/plan:make-plan
       asdf/plan:traverse-action
       asdf/plan:plan-actions
       asdf/action:compute-action-stamp
       asdf/find-system:find-system)

(let* ((root (first (uiop:split-string (uiop:getenv "NERIMUX_SIBLING_REGISTRY")
                                       :separator ":")))
       (path (merge-pathnames "cl-weave.asd"
                              (uiop:ensure-directory-pathname root))))
  (with-open-file (stream path)
    (let ((*package* (find-package :asdf-user))
          (*load-truename* path)
          (*load-pathname* path))
      (read stream nil :eof)
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            do (eval form))))
  (format t "Before load-system~%")
  (finish-output)
  (asdf:load-system "cl-weave")
  (format t "After load-system~%")
  (finish-output))
