(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(dolist (spec '((:asdf/plan "TRAVERSE-ACTION")
                (:asdf/plan "MAP-DIRECT-DEPENDENCIES")
                (:asdf/plan "COMPUTE-ACTION-STAMP")
                (:asdf/action "COMPONENT-DEPENDS-ON")
                (:asdf/action "INPUT-FILES")
                (:asdf/action "OPERATION-DONE-P")
                (:asdf/action "COMPONENT-OPERATION-TIME")))
  (let ((symbol (find-symbol (second spec) (first spec))))
    (when (and symbol (fboundp symbol))
      (eval `(trace ,symbol)))))

(asdf/session:call-with-asdf-session
 (lambda ()
   (setf (asdf/session:asdf-upgraded-p
          (asdf/session:toplevel-asdf-session))
         t)
   (let* ((system (asdf:find-system "asdf"))
          (operation (asdf:make-operation 'asdf:load-op)))
     (format t "BEFORE-PLAN~%")
     (finish-output)
     (let ((plan (asdf/plan:make-plan nil operation system)))
       (format t "AFTER-PLAN ACTIONS=~S~%" (asdf/plan:plan-actions plan))
       (finish-output)
       (asdf/plan:perform-plan plan)
       (format t "AFTER-PERFORM~%")
       (finish-output)))))
