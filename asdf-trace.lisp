(require :asdf)

(dolist (package-name '(:asdf :asdf/session :asdf/find-system :asdf/system
                        :asdf/system-registry :asdf/source-registry
                        :asdf/component :asdf/operation :asdf/plan
                        :uiop :uiop/pathname :uiop/filesystem :uiop/utility))
  (let ((package (find-package package-name)))
    (format t "PACKAGE ~A => ~A~%" package-name package)
    (when package
      (dolist (symbol-name '(:load-asd :operate :perform :perform-plan :load*
                             :call-with-asdf-session :define-op :locate-system
                             :search-for-system-definition :registered-system
                             :sysdef-central-registry-search
                             :sysdef-source-registry-search
                             :sysdef-preloaded-system-search
                             :sysdef-immutable-system-search
                             :system-source-file :component-operation-time
                             :get-file-stamp :ensure-pathname
                             :check-not-old-asdf-system
                             :definition-dependencies-up-to-date-p
                             :pathname-equal :physicalize-pathname
                             :probe-file*))
        (multiple-value-bind (symbol status)
            (find-symbol (symbol-name symbol-name) package)
          (when symbol
            (format t "  ~A ~A ~A~%" symbol status (fboundp symbol))))))))

(asdf:initialize-source-registry '(:source-registry :ignore-inherited-configuration))
(push (truename ".") asdf:*central-registry*)

(load (truename "asdf-load-asd-probe.asd"))
(format t "LOADED-PROBE~%")
(finish-output)

(dolist (spec '((:asdf/find-system :locate-system)
                (:asdf/find-system :check-not-old-asdf-system)
                (:asdf/find-system :definition-dependencies-up-to-date-p)
                (:asdf/system-registry :registered-system)
                (:asdf/system-registry :search-for-system-definition)
                (:asdf/system-registry :sysdef-central-registry-search)
                (:asdf/system-registry :sysdef-source-registry-search)
                (:asdf/system-registry :sysdef-preloaded-system-search)
                (:asdf/system-registry :sysdef-immutable-system-search)
                (:asdf/system :system-source-file)
                (:asdf/component :primary-system-name)
                (:asdf/component :component-operation-time)))
  (let* ((package (find-package (first spec)))
         (symbol (and package
                      (find-symbol (symbol-name (second spec)) package))))
    (when (and symbol (fboundp symbol))
      (eval (list 'trace symbol)))))

(format t "REGISTERED ~S~%"
        (funcall (find-symbol "REGISTERED-SYSTEM" :asdf/system-registry)
                 "asdf-load-asd-probe"))
(format t "BEFORE-FIND~%")
(finish-output)
(asdf:find-system "asdf-load-asd-probe" nil)
(format t "AFTER-FIND~%")
