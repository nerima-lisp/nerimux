;;;; Declarative rule-table macros for the multi-client server's dispatchers.
;;;;
;;;; Moved out of package.lisp (W6): these have nothing to do with package
;;;; declaration, and package.lisp used to be the only file guaranteed to
;;;; load before every server-multi-dispatch-*.lisp consumer. Placed first in
;;;; bootstrap-server's component list for the same reason.

(in-package #:nerimux)

(defmacro define-worktree-command-entry (name command description)
  `(defun ,name (conn)
     ,(format nil "Enter command mode for the ~A worktree operation." description)
     (if (%client-operation-worktree conn)
         (%client-enter-command-mode conn ,command)
         (%client-notify conn ,(format nil "select a worktree to ~A" description)))
     t))

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
                         `(,(cond ((eql pattern t) t)
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
                       `(,(cond ((eql pattern t) t)
                                ((and (consp pattern) (every #'keywordp pattern))
                                 `(member ,cmd-var ',pattern :test #'eq))
                                ((keywordp pattern) `(eq ,cmd-var ,pattern))
                                (t pattern))
                         ,@body))) rules)))))
