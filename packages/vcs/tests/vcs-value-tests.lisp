(in-package #:nerimux/test/vcs)

(describe "vcs value helpers"
          (it "reports whether the VCS package is loaded"
              (expect
               (eq (not (null (find-package :vcs-kit)))
                   (nerimux/vcs::vcs-package-available-p))))
          (it "normalizes values and splits repository specifications"
              (expect (string= "" (nerimux/vcs::%string-value nil)))
              (expect (string= "value" (nerimux/vcs::%string-value "value")))
              (expect (string= (namestring #P"/tmp/project") (nerimux/vcs::%string-value #P"/tmp/project")))
              (expect (string= "42" (nerimux/vcs::%string-value 42)))
              (expect (equal '("org" "project") (nerimux/vcs::%specification-parts "org//project/")))
              (expect (equal '("project") (nerimux/vcs::%specification-parts "/project/")))
              (expect (equal '("org" "project") (nerimux/vcs::%specification-parts "///org///project///")))
              (expect (null (nerimux/vcs::%specification-parts nil))))
          (it "strips C0 control characters and DEL, turning Tab into a single space (F5)"
              (expect (string= "a[31mb" (nerimux/vcs::%strip-control-characters (format nil "a~C[31mb" (code-char 27)))))
              (expect (string= "a b" (nerimux/vcs::%strip-control-characters (format nil "a~Cb" (code-char 9)))))
              (expect (string= "ab" (nerimux/vcs::%strip-control-characters (format nil "a~Cb" (code-char 127)))))
              (expect (notany (lambda (character) (< (char-code character) 32)) (nerimux/vcs::%strip-control-characters (map 'string #'code-char (loop for code from 0 below 32 collect code)))))
              (expect (string= "no controls" (nerimux/vcs::%strip-control-characters "no controls")))
              (expect (null (nerimux/vcs::%strip-control-characters nil))))
          (it "derives organization and repository names by specification shape"
              (dolist (case '(("host/org/project" "host" "org") ("host/org/project/extra" "host" "org") ("org/project" "local" "org") ("project" "local" "default") (nil "local" "default")))
                (destructuring-bind (spec organization name) case
                  (multiple-value-bind (actual-organization actual-name) (nerimux/vcs::%organization-and-name spec)
                    (expect (string= organization actual-organization))
                    (expect (string= name actual-name)))))))

(describe "vcs callback dispatch"
          (it "defers a callback through the supplied dispatcher"
              (let ((queued nil) (result nil))
                (nerimux/vcs::%dispatch-callback (lambda (thunk) (setf queued thunk)) (lambda (value) (setf result value)) :done)
                (expect (null result))
                (expect (functionp queued))
                (funcall queued)
                (expect (eq :done result)))))
