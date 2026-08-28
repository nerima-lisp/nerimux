;;;; Package bootstrap for nerimux.
;;;;
;;;; Keep the package declarations in fragment files loaded here so ASDF's
;;;; serial source order can continue to rely on this single entry point.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *package-fragments-loaded* nil)
  (unless *package-fragments-loaded*
    ;; ASDF may load a fasl from its cache, so prefer the system source root.
    ;; Direct source loads fall back from src/bootstrap/package.lisp to the
    ;; repository root before resolving fragment paths.
    (let* ((source-path (or *load-pathname* *compile-file-pathname*))
           (root (or (handler-case (asdf:system-source-directory :nerimux)
                       (asdf:missing-component () nil))
                     (and source-path (merge-pathnames #P"../../" source-path))))
           (base (merge-pathnames #P"src/" root)))
      (load (merge-pathnames #P"bootstrap/package-version.lisp" base))
      (load (merge-pathnames #P"bootstrap/package-core.lisp" base))
      (load (merge-pathnames #P"bootstrap/package-terminal-types.lisp" base))
      (load (merge-pathnames #P"bootstrap/package-terminal.lisp" base))
      (load (merge-pathnames #P"bootstrap/package-domain-ports.lisp" base))
      (load (merge-pathnames #P"bootstrap/package-domain-model.lisp" base))
      (load (merge-pathnames #P"bootstrap/package-presentation.lisp" base))
      (load (merge-pathnames #P"bootstrap/package-application.lisp" base)))
    (setf *package-fragments-loaded* t)))

(in-package #:nerimux)

(defmacro define-message-dispatch-fn (fn-name lambda-list docstring &rest rules)
  "Build a named message-dispatch function from a declarative rule table."
  `(defun ,fn-name ,lambda-list ,docstring
     (cond
       ,@(mapcar (lambda (rule)
                   (destructuring-bind (condition &rest body) rule
                     `(,condition ,@body))) rules))))

(defmacro define-multi-msg-dispatch (&rest rules)
  "Build the multi-client message dispatcher from declarative rules."
  `(define-message-dispatch-fn %handle-multi-client-message
       (type payload session conn)
       "Dispatch one message of TYPE/PAYLOAD from client CONN."
       ,@rules))

(defmacro define-key-rules (name (session-var conn-var payload-var) &rest clauses)
  "Build a key-payload dispatcher from declarative rules."
  (let* ((docstring (and (stringp (first clauses)) (first clauses)))
         (rest1 (if docstring (rest clauses) clauses))
         (let-form (and (consp (first rest1)) (eq (caar rest1) :let)
                        (first rest1)))
         (bindings (second let-form))
         (rules (if let-form (rest rest1) rest1)))
    `(defun ,name (,session-var ,conn-var ,payload-var)
       ,@(when docstring (list docstring))
       (declare (ignorable ,session-var ,conn-var ,payload-var))
       (let* ,bindings
         (cond
           ,@(mapcar (lambda (rule)
                       (destructuring-bind (pattern &rest body) rule
                         `(,(cond ((eq pattern t) t)
                                  ((characterp pattern)
                                   `(%client-key-p ,payload-var ,pattern))
                                  ((integerp pattern)
                                   `(%client-byte-p ,payload-var ,pattern))
                                  (t pattern))
                           ,@body))) rules))))))

(defmacro define-command-rules
    (name (session-var conn-var cmd-var target-var args-var) &rest clauses)
  "Build a UI-command dispatcher from declarative rules."
  (let* ((docstring (and (stringp (first clauses)) (first clauses)))
         (rules (if docstring (rest clauses) clauses)))
    `(defun ,name (,session-var ,conn-var ,cmd-var ,target-var ,args-var)
       ,@(when docstring (list docstring))
       (declare (ignorable ,session-var ,conn-var ,cmd-var ,target-var ,args-var))
       (cond
         ,@(mapcar (lambda (rule)
                     (destructuring-bind (pattern &rest body) rule
                       `(,(cond ((eq pattern t) t)
                                ((and (consp pattern) (every #'keywordp pattern))
                                 `(member ,cmd-var ',pattern :test #'eq))
                                ((keywordp pattern) `(eq ,cmd-var ,pattern))
                                (t pattern))
                         ,@body))) rules)))))

(declaim (notinline nerimux/model:window-tree
                    (setf nerimux/model:window-tree)))
