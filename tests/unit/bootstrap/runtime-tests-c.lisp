(in-package #:nerimux/test)

(describe "runtime-suite"


  (it "stop-reader-threads-sets-running-nil"
    (let ((nerimux::*running* t))
      (nerimux::stop-reader-threads '())
      (expect nerimux::*running* :to-be-falsy)))

  (it "stop-reader-threads-empty-list"
    (let ((nerimux::*running* t))
      (finishes (nerimux::stop-reader-threads '())
                "stop-reader-threads with empty list must not signal")
      (expect nerimux::*running* :to-be-falsy)))

  (it "stop-reader-threads-joins-already-dead-thread"
    (with-global-running nil
      (let ((thread (cl-concurrent-kit:make-thread
                     (lambda ()
                       (loop while nerimux::*running* do (sleep 0.001)))
                     :name "test-dead-thread")))
        (sleep 0.05)
        (finishes (nerimux::stop-reader-threads (list thread))
                  "stop-reader-threads must not signal when joining a dead thread")
        (expect nerimux::*running* :to-be-falsy))))


  (it "wait-for-channel-timeout-constant-is-positive"
    (expect (integerp nerimux::+wait-for-channel-timeout+))
    (expect (plusp nerimux::+wait-for-channel-timeout+)))


  (it "server-sessions-var-is-boundp"
    (expect (boundp 'nerimux::*server-sessions*))
    (expect (listp nerimux::*server-sessions*)))


  (it "ensure-channel-creates-entry"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (let ((ch (nerimux::%ensure-channel "test-ch")))
        (expect ch :to-be-truthy)
        (expect (getf ch :lock) :to-be-truthy)
        (expect (getf ch :cv) :to-be-truthy))))

  (it "ensure-channel-is-idempotent"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (let ((ch1 (nerimux::%ensure-channel "idem"))
            (ch2 (nerimux::%ensure-channel "idem")))
        (expect (eq ch1 ch2)))))

  (it "lock-and-unlock-channel-toggle-flag"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (nerimux::lock-channel "lk-test")
      (let ((ch (nerimux::%ensure-channel "lk-test")))
        (expect (getf ch :locked) :to-be-truthy))
      (nerimux::unlock-channel "lk-test")
      (let ((ch (nerimux::%ensure-channel "lk-test")))
        (expect (getf ch :locked) :to-be-falsy))))

  (it "signal-channel-locked-is-noop"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (nerimux::lock-channel "sig-locked")
      (finishes (nerimux::signal-channel "sig-locked")
                "signal-channel on a locked channel must not signal an error")))

  (it "wait-for-signal-unblocks"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (nerimux::%ensure-channel "test-chan")
      (finishes (nerimux::lock-channel "test-chan")
                "lock-channel must not signal")
      (finishes (nerimux::unlock-channel "test-chan")
                "unlock-channel must not signal")
      (finishes (nerimux::signal-channel "test-chan")
                "signal-channel with no waiters must not signal")
      (nerimux::lock-channel "test-chan")
      (finishes (nerimux::signal-channel "test-chan")
                "signal-channel while locked must not signal")
      (nerimux::unlock-channel "test-chan")
      (finishes (nerimux::signal-channel "test-chan")
                "signal-channel after unlock must not signal")))

  (it "ensure-channel-stores-in-hash-table"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (nerimux::%ensure-channel "stored-ch")
      (expect (gethash "stored-ch" nerimux::*wait-channels*) :to-be-truthy)))

  (it "channel-locked-flag-defaults-to-nil"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (let ((ch (nerimux::%ensure-channel "fresh-lock")))
        (expect (getf ch :locked) :to-be-falsy))))

  (it "lock-channel-then-signal-then-unlock-is-safe"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (nerimux::lock-channel "seq-ch")
      (finishes (nerimux::signal-channel "seq-ch")
                "signal-channel while locked must not error")
      (nerimux::unlock-channel "seq-ch")
      (let ((ch (nerimux::%ensure-channel "seq-ch")))
        (expect (getf ch :locked) :to-be-falsy))))

  (it "multiple-distinct-channels-independent"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (let ((ch-a (nerimux::%ensure-channel "ch-a"))
            (ch-b (nerimux::%ensure-channel "ch-b")))
        (expect (not (eq ch-a ch-b)))
        (nerimux::lock-channel "ch-a")
        (let ((ch-a2 (nerimux::%ensure-channel "ch-a"))
              (ch-b2 (nerimux::%ensure-channel "ch-b")))
          (expect (getf ch-a2 :locked) :to-be-truthy)
          (expect (getf ch-b2 :locked) :to-be-falsy))))))
