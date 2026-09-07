(in-package #:nerimux/test)

(describe "server-dispatch-helper-error-suite"
  (it "with-loop-safe-error-contains-a-send-timeout"
    (let ((ran nil))
      (expect (eq :contained
                  (nerimux::with-loop-safe-error (nil :on-error :contained)
                    (setf ran t)
                    (sb-ext:with-timeout 0.05 (sleep 5)))))
      (expect ran)))

  (it "with-loop-safe-error-contains-an-ordinary-error-and-binds-it"
    (expect (search "boom"
                    (nerimux::with-loop-safe-error
                        (condition :on-error (princ-to-string condition))
                      (error "boom")))))

  (it "with-loop-safe-error-does-not-swallow-storage-condition"
    (expect (eq :propagated
                (handler-case
                    (nerimux::with-loop-safe-error (nil :on-error :wrongly-caught)
                      (signal 'storage-condition))
                  (storage-condition () :propagated)))))
  )
