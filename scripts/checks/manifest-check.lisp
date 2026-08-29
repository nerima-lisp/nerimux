;;;; Cross-check system/asdf-test-components.lisp against the files on disk.
;;;;
;;;; Two failure modes this catches, both of which kill the whole suite or hide
;;;; tests silently:
;;;;   MISSING  — the manifest names a component with no file behind it.  ASDF
;;;;              aborts loading nerimux/test, so every test disappears at once.
;;;;   ORPHAN   — a .lisp file under tests/ that no manifest entry names.  It is
;;;;              never loaded, so its tests silently stop running.
;;;;
;;;; The manifest is a plain DEFPARAMETER in CL-USER, so it loads without ASDF.

(load "system/asdf-test-components.lisp")

(defvar *declared* '())

(defun walk (node dir)
  (cond
    ((and (consp node) (eq (first node) :module))
     (let* ((name (second node))
            (plist (cddr node))
            (pathname (getf plist :pathname))
            (sub (or pathname name))
            (components (getf plist :components)))
       (dolist (c components) (walk c (concatenate 'string dir sub "/")))))
    ((and (consp node) (eq (first node) :file))
     (push (concatenate 'string dir (second node) ".lisp") *declared*))))

(dolist (top (symbol-value (find-symbol "*NERIMUX-TEST-COMPONENTS*" :cl-user)))
  (walk top ""))

(let* ((root (namestring (truename ".")))
       (declared (sort (copy-list *declared*) #'string<))
       (on-disk (sort (mapcar (lambda (p)
                                (let ((s (namestring p)))
                                  (subseq s (length root))))
                              ;; tests/pty belongs to nerimux/pty-test and tests/e2e is run by hand against a
                              ;; built binary; neither is in this manifest by design, so
                              ;; neither should be reported as an accident.
                              (remove-if (lambda (p)
                                           (let ((s (namestring p)))
                                             (or (search "/tests/pty/" s)
                                                 (search "/tests/e2e/" s))))
                                         (directory "tests/**/*.lisp")))
                      #'string<))
       (missing (remove-if (lambda (d) (member d on-disk :test #'string=)) declared))
       (orphan  (remove-if (lambda (d) (member d declared :test #'string=)) on-disk)))
  (format t "~&manifest entries: ~D~%files under tests/: ~D~%" (length declared) (length on-disk))
  (when (zerop (length declared))
    (format t "~&MANIFEST PARSED TO NOTHING — the walker is wrong, not the tree~%")
    (finish-output)
    (sb-ext:quit :unix-status 2))
  (when missing
    (format t "~&MISSING (manifest names it, file absent) — kills the whole suite:~%")
    (dolist (m missing) (format t "  ~A~%" m)))
  (when orphan
    (format t "~&ORPHAN (file present, manifest silent) — never loaded:~%")
    (dolist (o orphan) (format t "  ~A~%" o)))
  (finish-output)
  (sb-ext:quit :unix-status (if (or missing orphan) 1 0)))
