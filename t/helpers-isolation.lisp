;;;; Test isolation helpers for nerimux.

(in-package #:nerimux/test)

(defmacro with-isolated-hooks (&body body)
  "Run BODY with fresh *hook-registry* and *command-hooks* tables so neither
   lisp-function hooks nor command hooks (set-hook) leak between tests."
  `(let ((nerimux/hooks:*hook-registry* (make-hash-table :test #'equal))
         (nerimux/hooks:*command-hooks* (make-hash-table :test #'equal)))
     ,@body))

(defmacro with-isolated-config (&body body)
  "Run BODY with the mutable config specials dynamically rebound to copies,
   so directives applied in a test never leak into other suites.
   Isolates: key-tables, default-shell, status-height, prefix-key-code,
             global-options (copy), server-options (copy)."
  `(let ((nerimux/config:*key-tables*  (make-hash-table :test #'equal))
         (nerimux/config:*default-shell* nerimux/config:*default-shell*)
         (nerimux/config:*status-height* nerimux/config:*status-height*)
         (nerimux/config:*prefix-key-code*  nerimux/config:*prefix-key-code*)
         (nerimux/config:*prefix2-key-code* nerimux/config:*prefix2-key-code*)
         (nerimux/options:*global-options*
          (let ((h (make-hash-table :test #'equal)))
            (maphash (lambda (k v) (setf (gethash k h) v))
                     nerimux/options:*global-options*)
            h))
         (nerimux/options:*server-options*
          (let ((h (make-hash-table :test #'equal)))
            (maphash (lambda (k v) (setf (gethash k h) v))
                     nerimux/options:*server-options*)
            h)))
     (nerimux/config::initialize-default-key-tables)
     ,@body))

(defmacro with-isolated-key-tables (&body body)
  "Run BODY with a fresh *KEY-TABLES* inside WITH-ISOLATED-CONFIG isolation."
  `(let ((nerimux/config:*key-tables* (make-hash-table :test #'equal)))
     (with-isolated-config
       ,@body)))

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
