;;;; Cross-check every declaration of a test file against the files on disk.
;;;;
;;;; Two failure modes this catches, both of which kill the whole suite or hide
;;;; tests silently:
;;;;   MISSING  — something names a component with no file behind it.  ASDF
;;;;              aborts loading that system, so its tests disappear at once.
;;;;   ORPHAN   — a .lisp file under tests/ or packages/*/tests/ that nothing
;;;;              names.  It is never loaded, so its tests silently stop
;;;;              running.
;;;;
;;;; There are two declaration sites, not one.  Root test files are enumerated
;;;; by system/asdf-test-components.lisp, a plain DEFPARAMETER in CL-USER that
;;;; loads without ASDF.  Each extracted unit enumerates its own test files in
;;;; packages/<name>/nerimux-<name>.asd instead.  Reading only the first would
;;;; report every unit's tests as ORPHAN — the invariant is "no test file goes
;;;; unloaded", not "the root manifest lists it".
;;;;
;;;; The .asd files are READ, never evaluated.  ASDF is required first only so
;;;; the reader can resolve the package-qualified symbols inside a :perform
;;;; form; nothing here calls into ASDF.

(require :asdf)

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

(defun test-system-form-p (form)
  "True for a (defsystem \"nerimux-<unit>/test\" ...) form.  Matched on the name
   suffix rather than on the operator's home package, because the file is read,
   not evaluated, so DEFSYSTEM here is whatever symbol the reader interned."
  (and (consp form)
       (symbolp (first form))
       (string= (symbol-name (first form)) "DEFSYSTEM")
       (stringp (second form))
       (let ((name (second form)))
         (and (> (length name) 5)
              (string= "/test" (subseq name (- (length name) 5)))))))

(dolist (asd (directory "packages/*/nerimux-*.asd"))
  (let ((unit-dir (let* ((s (namestring asd))
                         (slash (position #\/ s :from-end t)))
                    ;; "…/packages/text/nerimux-text.asd" -> "packages/text/"
                    (let ((dir (subseq s 0 (1+ slash))))
                      (subseq dir (search "packages/" dir))))))
    (with-open-file (in asd :external-format :utf-8)
      (loop for form = (read in nil :eof)
            until (eq form :eof)
            when (test-system-form-p form)
              do (let* ((plist (cddr form))
                        (pathname (getf plist :pathname))
                        (components (getf plist :components)))
                   (dolist (c components)
                     (walk c (concatenate 'string unit-dir
                                          (if pathname
                                              (concatenate 'string pathname "/")
                                              "")))))))))

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
                                         (append (directory "tests/**/*.lisp") (directory "packages/*/tests/**/*.lisp"))))
                      #'string<))
       (missing (remove-if (lambda (d) (member d on-disk :test #'string=)) declared))
       (orphan  (remove-if (lambda (d) (member d declared :test #'string=)) on-disk)))
  (format t "~&manifest entries: ~D~%files under tests/ and packages/*/tests/: ~D~%" (length declared) (length on-disk))
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
