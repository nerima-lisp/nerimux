(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(dolist (name '(:call-with-asdf-session
                :upgrade-asdf
                :make-forcing
                :asdf-upgraded-p
                :ensure-source-registry
                :initialize-source-registry
                :compute-source-registry
                :flatten-source-registry
                :register-asd-directory
                :operate))
  (multiple-value-bind (symbol package)
      (find-symbol (symbol-name name)
                   (cond
                     ((member name '(:call-with-asdf-session :asdf-upgraded-p)
                              :test (function eq))
                      (find-package :asdf/session))
                     ((member name '(:upgrade-asdf)
                              :test (function eq))
                      (find-package :asdf/upgrade))
                     ((member name '(:make-forcing)
                              :test (function eq))
                      (find-package :asdf/forcing))
                     ((member name '(:ensure-source-registry
                                     :initialize-source-registry
                                     :compute-source-registry
                                     :flatten-source-registry
                                     :register-asd-directory)
                              :test (function eq))
                      (find-package :asdf/source-registry))
                     (t (find-package :asdf/operate))))
    (declare (ignore package))
    (when (and symbol (fboundp symbol))
      (eval `(trace ,symbol)))))

(format t "BEFORE-LOAD-SYSTEM~%")
(finish-output)
(asdf:load-system "asdf")
(format t "AFTER-LOAD-SYSTEM~%")
(finish-output)
