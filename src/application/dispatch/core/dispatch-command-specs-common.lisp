(in-package #:nerimux)

;;;; Shared helpers for dispatch command registry construction.

(defun %make-dispatch-command-spec (named-keyword arg-handler arg-names
                                    &key named-names public-name)
  ;; ARG-HANDLER is the fbound %cmd-*-arg symbol invoked for the scriptable,
  ;; argument-taking form of the command (see dispatch-commands-runner.lisp's
  ;; *arg-command-table*).  Pass NIL for a no-argument command: it is then
  ;; reached only through %dispatch-named-command (its :named-keyword), never
  ;; the arg-command table, while ARG-NAMES still surfaces it in
  ;; list-commands.  A non-NIL ARG-HANDLER MUST name a defined function —
  ;; the every-arg-command-handler-is-fbound test guards against typos.
  (append (list :named-keyword named-keyword
                :named-names (or named-names
                                 (and named-keyword
                                      (list (string-downcase
                                             (symbol-name named-keyword)))))
                :arg-handler arg-handler
                :arg-names arg-names)
          (when public-name
            (list :public-name public-name))))

(defun %dispatch-command-specs-from-entries (entries maker)
  (mapcar (lambda (entry)
            (apply maker entry))
          entries))
