(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(defun load-asd-file (path)
  (format t "~&Loading ASD ~A~%" path)
  (finish-output)
  (let ((*package* (find-package :asdf-user)))
    (load path))
  (format t "~&Loaded ASD ~A~%" path)
  (finish-output))

(let* ((project-root
         (uiop:pathname-directory-pathname (truename "nerimux.asd")))
       (sibling-roots
         (remove-if (function (lambda (path) (string= path "")))
                    (uiop:split-string (or (uiop:getenv "NERIMUX_SIBLING_REGISTRY") "")
                                       :separator ":"))))
  (require :sb-cover)
  (require :sb-posix)
  (loop for root in sibling-roots
        for name in '("cl-weave" "cl-cli" "cl-date-kit" "cl-parser-kit"
                      "cl-tty-kit" "cl-process-kit" "cl-log-kit"
                      "cl-boundary-kit" "cl-concurrent-kit" "cl-regex-kit"
                      "cl-codec-kit" "cl-host-kit" "cl-tui-kit" "cl-vcs-kit")
        do (load-asd-file (merge-pathnames (format nil "~A.asd" name)
                                           (uiop:ensure-directory-pathname root))))
  (load-asd-file (merge-pathnames "nerimux.asd" project-root)))

(format t "~&ASD registration complete~%")
(finish-output)
(format t "~&Loading test system~%")
(finish-output)
(asdf:load-system "nerimux/test")
(format t "~&TEST SYSTEM LOADED~%")
(finish-output)
