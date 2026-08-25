(require :asdf)

(setf asdf/source-registry:*source-registry*
      (make-hash-table :test (function equal)))

(defun load-asd-name (name)
  (let ((root (first (uiop:split-string (uiop:getenv "NERIMUX_SIBLING_REGISTRY")
                                      :separator ":"))))
    (format t "~&Loading ~A ~A~%" root name)
    (finish-output)
    (let ((*package* (find-package :asdf-user)))
      (load (merge-pathnames name
                             (uiop:ensure-directory-pathname root))))
    (format t "~&Loaded ~A~%" name)
    (finish-output)))

(defun load-cl-weave ()
  (load-asd-name "cl-weave.asd"))

(defun require-module (name)
  (format t "~&Requiring ~A~%" name)
  (finish-output)
  (require name)
  (format t "~&Required ~A~%" name)
  (format t "~&Registry ~S initialized ~S~%"
          asdf/source-registry:*source-registry*
          (asdf/source-registry:source-registry-initialized-p))
  (let ((symbol (find-symbol "REGISTERED-SYSTEMS" :asdf)))
    (when (and symbol (fboundp symbol))
      (format t "~&Registered count ~D~%"
              (length (funcall symbol)))
      (format t "~&Registered names ~S~%" (funcall symbol))))
  (finish-output))

(defun reset-registry ()
  (setf asdf/source-registry:*source-registry*
        (make-hash-table :test (function equal)))
  (format t "~&Registry reset initialized ~S~%"
          (asdf/source-registry:source-registry-initialized-p))
  (finish-output))

(let ((mode (uiop:getenv "NERIMUX_PROBE_MODE")))
  (cond
    ((string= mode "posix-only")
     (require-module :sb-posix))
    ((string= mode "cover-only")
     (require-module :sb-cover))
    ((string= mode "posix-find-cover")
     (require-module :sb-posix)
     (format t "~&Before find sb-cover~%")
     (finish-output)
     (asdf:find-system "sb-cover" nil)
     (format t "~&After find sb-cover~%")
     (finish-output))
    ((string= mode "posix-load-probe")
     (require-module :sb-posix)
     (format t "~&Loading project probe~%")
     (finish-output)
     (let ((*package* (find-package :asdf-user)))
       (load (truename "asdf-load-asd-probe.asd")))
     (format t "~&Loaded project probe~%")
     (finish-output))
    ((string= mode "posix-trace-weave")
     (require-module :sb-posix)
     (reset-registry)
     (trace asdf/find-system:find-system
            asdf/find-system:locate-system
            asdf:search-for-system-definition
            asdf/parse-defsystem:register-system-definition
            asdf/parse-defsystem::find-system-if-being-defined
            asdf/parse-defsystem::parse-dependency-defs
            asdf/parse-defsystem::resolve-dependency-spec
            asdf/parse-defsystem::set-asdf-cache-entry
            asdf/source-registry:sysdef-source-registry-search
            asdf/system-registry:registered-system
            asdf/system-registry:register-system)
     (load-cl-weave))
    ((string= mode "posix-weave-cover")
     (require-module :sb-posix)
     (reset-registry)
     (load-cl-weave)
     (require-module :sb-cover))
    ((string= mode "posix-cover-weave")
     (require-module :sb-posix)
     (require-module :sb-cover)
     (reset-registry)
     (load-cl-weave))
    ((string= mode "cover-posix-weave")
     (require-module :sb-cover)
     (require-module :sb-posix)
     (reset-registry)
     (load-cl-weave))
    (t
     (when (member mode '("reverse" "reverse-both") :test #'string=)
       (load-cl-weave))
     (when (member mode '("cover" "both" "reverse-both") :test #'string=)
       (require-module :sb-cover))
     (when (member mode '("posix" "both" "reverse-both") :test #'string=)
       (require-module :sb-posix))
     (when (member mode '("reset" "cover" "posix" "both" "reverse-both")
                       :test #'string=)
       (reset-registry))
     (load-cl-weave))))
