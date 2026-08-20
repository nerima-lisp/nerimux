;;;; Test isolation helpers for nerimux.

(in-package #:nerimux/test)

(defmacro with-isolated-hooks (&body body)
  "Run BODY with a fresh *hook-registry* table so lisp-function hooks don't
   leak between tests."
  `(let ((nerimux/hooks:*hook-registry* (make-hash-table :test #'equal)))
     ,@body))

(defmacro with-isolated-config (&body body)
  "Run BODY with the mutable config specials dynamically rebound to copies,
   so directives applied in a test never leak into other suites.
   Isolates: global-options (copy), server-options (copy).
   Both the status-bar row count and the default shell are derived from options
   (`status' and `default-shell'), not from cached specials, so isolating
   global-options isolates them too -- no separate bindings needed."
  `(let ((nerimux/options:*global-options*
          (let ((h (make-hash-table :test #'equal)))
            (maphash (lambda (k v) (setf (gethash k h) v))
                     nerimux/options:*global-options*)
            h))
         (nerimux/options:*server-options*
          (let ((h (make-hash-table :test #'equal)))
            (maphash (lambda (k v) (setf (gethash k h) v))
                     nerimux/options:*server-options*)
            h)))
     ,@body))

(defmacro with-temp-config-file ((path-var &rest lines) &body body)
  "Write LINES to a temporary config file, bind PATH-VAR, run BODY, then delete it."
  (let ((path-sym (gensym "PATH")))
    `(let ((,path-sym (merge-pathnames
                       (format nil "nerimux-test-~D.conf" (random 1000000))
                       (host-kit:temporary-directory))))
       (unwind-protect
            (progn
              (with-open-file (out ,path-sym :direction :output
                                             :if-exists :supersede
                                             :if-does-not-exist :create)
                ,@(mapcar (lambda (line) `(write-line ,line out)) lines)
                (finish-output out))
              (let ((,path-var ,path-sym))
                ,@body))
         (when (probe-file ,path-sym)
           (delete-file ,path-sym))))))
