(require :asdf)

(sb-impl::module-provide-contrib :sb-posix)

(asdf:register-preloaded-system "sb-posix")

(setf asdf/source-registry:*source-registry* (make-hash-table :test
                                                              (function equal)))

(push (uiop:pathname-directory-pathname *load-truename*)
      asdf:*central-registry*)

(dolist 
    (dir
     (directory
      (merge-pathnames "packages/*/"
                       (uiop:pathname-directory-pathname *load-truename*))))
  (push dir asdf:*central-registry*))

(dolist 
    (dir
     (uiop:split-string (or (uiop:getenv "NERIMUX_SIBLING_REGISTRY") "")
                        :separator
                        ":"))
  (unless (string= dir "")
    (push (truename (uiop:ensure-directory-pathname dir))
          asdf:*central-registry*)))

(let ((system (or (uiop:getenv "NERIMUX_TEST_SYSTEM") "nerimux/test")))
  (format t "~&Running test system ~A~%" system)
  (finish-output)
  (handler-case (asdf:test-system system)
    (error (e)
      (format *error-output* "~&TESTS FAILED (~A): ~A~%" system e)
      (finish-output *error-output*)
      (uiop:quit 1))))

(uiop:quit 0)
