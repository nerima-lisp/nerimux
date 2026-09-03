(in-package #:nerimux/test)

(describe "renderer-help-transient-agreement-suite"

  (it "every menu key the help advertises actually opens a transient"
    (let* ((section (find "Menus (?)" nerimux/renderer::+help-view-sections+
                          :key #'first :test #'string=))
           (advertised (mapcar #'car (second section))))
      (expect (plusp (length advertised)))
      (dolist (key advertised)
        (expect (assoc (char key 0) nerimux::+transient-definitions+
                       :test #'char=)))))
)
