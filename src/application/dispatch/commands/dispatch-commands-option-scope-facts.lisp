(in-package #:nerimux)

;;;; Option scope canonical facts.

(defmacro define-scope-accessor-table (&rest rules)
  "Build %SCOPE-GETTER, %SCOPE-SETTER, and %SCOPE-REMOVER from declarative
scope access rules. Each rule has (SCOPE GETTER-FORM SETTER-FORM REMOVER-FORM).
NAME, VALUE, DEFAULT, and TARGET are intentionally bound by the generated
functions so each fact row stays data-shaped."
  `(progn
     (defun %scope-getter (scope name target &optional default)
       (declare (ignorable target default))
       (ecase scope
         ,@(mapcar (lambda (rule)
                     (destructuring-bind (scope getter-form setter-form remover-form) rule
                       (declare (ignore setter-form remover-form))
                       `(,scope ,getter-form)))
                   rules)))
     (defun %scope-setter (scope name value target)
       (declare (ignorable target))
       (ecase scope
         ,@(mapcar (lambda (rule)
                     (destructuring-bind (scope getter-form setter-form remover-form) rule
                       (declare (ignore getter-form remover-form))
                       `(,scope ,setter-form)))
                   rules)))
     (defun %scope-remover (scope name target)
       (declare (ignorable target))
       (ecase scope
         ,@(mapcar (lambda (rule)
                     (destructuring-bind (scope getter-form setter-form remover-form) rule
                       (declare (ignore getter-form setter-form))
                       `(,scope ,remover-form)))
                   rules)))))

(define-scope-accessor-table
  (:pane
   (nerimux/options:get-option-for-pane name target)
   (nerimux/options:set-option-for-pane name value target)
   (remhash name (nerimux/model:pane-local-options target)))
  (:window
   (nerimux/options:get-option-for-window name target)
   (nerimux/options:set-option-for-window name value target)
   (remhash name (nerimux/model:window-local-options target)))
  (:global
   (nerimux/options:get-option name default)
   (nerimux/options:set-option name value)
   (remhash name nerimux/options:*global-options*))
  (:server
   (nerimux/options:get-server-option name default)
   (nerimux/options:set-server-option name value)
   (remhash name nerimux/options:*server-options*)))
