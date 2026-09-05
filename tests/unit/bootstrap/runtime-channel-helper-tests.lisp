(in-package #:nerimux/test)

(describe "runtime-suite"


  (it "with-channel-plist-binds-lock-and-cv"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (let ((ch (nerimux::%ensure-channel "wplist-test")))
        (nerimux::with-channel-plist (lk cv ch)
          (expect (eq (getf ch :lock) lk))
          (expect (eq (getf ch :cv) cv))))))

  (it "with-channel-plist-is-a-macro"
    (expect (macro-function 'nerimux::with-channel-plist))))
