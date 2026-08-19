(in-package #:nerimux/test)

;;;; channel helper and list capping contracts

(describe "runtime-suite"

  ;;; ── %cap-list ─────────────────────────────────────────────────────────────────

  ;; %cap-list returns the list unchanged when its length is <= limit.
  (it "cap-list-returns-list-unchanged-when-under-limit"
    (let ((lst '(1 2 3)))
      (expect (equal '(1 2 3) (nerimux::%cap-list lst 5)))
      (expect (equal '(1 2 3) (nerimux::%cap-list lst 3)))))

  ;; %cap-list returns a subseq of at most LIMIT elements when the list is longer.
  (it "cap-list-truncates-when-over-limit"
    (let ((lst '(a b c d e)))
      (expect (equal '(a b c) (nerimux::%cap-list lst 3)))))

  ;; %cap-list returns NIL for NIL input (empty list).
  (it "cap-list-returns-nil-for-nil-input"
    (expect (null (nerimux::%cap-list nil 5))))

  ;; %cap-list returns NIL when limit is 0.
  (it "cap-list-returns-nil-for-zero-limit"
    (expect (null (nerimux::%cap-list '(1 2 3) 0))))

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
