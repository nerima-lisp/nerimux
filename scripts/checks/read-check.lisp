;;;; Whole-tree structure check for nerimux.
;;;;
;;;; Reads every *.lisp and *.asd under the current directory with
;;;; *READ-SUPPRESS* bound to T.  Under that binding the reader still tracks list
;;;; structure, strings, char literals and #| |# blocks, but interns nothing and
;;;; evaluates no #. form — so a file can be checked for balanced delimiters
;;;; without any package in the system being defined and without loading ASDF.
;;;; Unbalanced parens surface as END-OF-FILE.
;;;;
;;;; Exits non-zero when any file fails, so it cannot report a false green.
(defun check-file (path)
  (handler-case (with-open-file 
                    (s path :direction :input :external-format :utf-8)
                  (let ((*read-suppress* t)
                        (*package* (find-package :cl-user))
                        (forms 0))
                    (loop for form = (read s nil :%eof)
                          until (eq form :%eof)
                          do (incf forms))
                    (list :ok path forms)))
    (error (e)
      (list :fail path (princ-to-string e)))))

(let* ((files (append (directory "**/*.lisp") (directory "*.asd")))
       (sorted (sort files #'string< :key #'namestring))
       (bad '())
       (n 0))
  (dolist (f sorted)
    (let ((r (check-file f)))
      (incf n)
      (when (eq (first r) :fail)
        (push r bad))))
  (when (zerop n)
    (format t "~&NO FILES MATCHED — check the working directory~%")
    (finish-output)
    (sb-ext:quit :unix-status 2))
  (format t "~&checked ~D files~%" n)
  (if bad
      (progn
        (format t "~&FAILURES (~D):~%" (length bad))
        (dolist (b (reverse bad))
          (format t "  ~A~%    ~A~%" (second b) (third b)))
        (finish-output)
        (sb-ext:quit :unix-status 1))
      (progn
        (format t "~&ALL FILES READ CLEANLY~%")
        (finish-output)
        (sb-ext:quit :unix-status 0))))
