(in-package #:nerimux/test/terminal)

(describe "terminal-suite/csi-rule-composition"
  (it "composes non-empty rule sets in declaration order"
    (let* ((rule-set-names
             '(nerimux/terminal/csi::csi-screen-rules
               nerimux/terminal/csi::csi-device-rules
               nerimux/terminal/csi::csi-extended-rules))
           (rule-sets
             (mapcar (lambda (name)
                       (second (macroexpand-1 (list name))))
                     rule-set-names))
           (expansion
             (macroexpand-1
               `(nerimux/terminal/csi::define-composed-csi-rules
                  ,@rule-set-names))))
      (expect (every #'consp rule-sets))
      (expect (equal 'nerimux/terminal/csi::define-csi-rules
                     (first expansion)))
      (expect (equal (apply #'append rule-sets)
                     (rest expansion))))))
