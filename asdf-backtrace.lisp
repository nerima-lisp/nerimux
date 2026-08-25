(require :asdf)

(trace require
       asdf:load-system
       asdf:search-for-system-definition
       asdf/find-system:find-system
       asdf/find-system:locate-system
       asdf/system-registry:registered-system
       asdf/source-registry:sysdef-source-registry-search)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(let ((main-thread (sb-thread:main-thread)))
  (sb-thread:make-thread
   (lambda ()
     (sleep 3)
     (sb-thread:interrupt-thread
      main-thread
      (lambda ()
        (format *error-output* "~%INTERRUPTED~%")
        (sb-debug:backtrace 100)
        (finish-output *error-output*)
        (sb-ext:quit :code 42)))))

  (let ((root (first (uiop:split-string (uiop:getenv "NERIMUX_SIBLING_REGISTRY")
                                       :separator ":"))))
    (format t "BEFORE-LOAD~%")
    (finish-output)
    (let ((*package* (find-package :asdf-user)))
      (load (merge-pathnames "cl-weave.asd"
                             (uiop:ensure-directory-pathname root))))
    (format t "AFTER-WEAVE~%")
    (finish-output)
    (require :sb-cover)
    (format t "AFTER-COVER~%")
    (finish-output)
    (format t "BEFORE-POSIX~%")
    (finish-output)
    (require :sb-posix)
    (format t "AFTER-POSIX~%")
    (finish-output)))
