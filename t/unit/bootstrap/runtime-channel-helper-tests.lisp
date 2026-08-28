(in-package #:nerimux/test)

;;;; channel helper and list capping contracts

(describe "runtime-suite"

  ;;; ── with-channel-plist macro ──────────────────────────────────────────────────

  ;; with-channel-plist binds LK and CV to the :lock and :cv fields of a channel plist.
  (it "with-channel-plist-binds-lock-and-cv"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (let ((ch (nerimux::%ensure-channel "wplist-test")))
        (nerimux::with-channel-plist (lk cv ch)
          (expect (eq (getf ch :lock) lk))
          (expect (eq (getf ch :cv) cv))))))

  ;; with-channel-plist is defined as a macro.
  (it "with-channel-plist-is-a-macro"
    (expect (macro-function 'nerimux::with-channel-plist))))
