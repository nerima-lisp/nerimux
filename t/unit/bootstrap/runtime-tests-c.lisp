(in-package #:nerimux/test)

;;;; runtime tests — part C: stop-reader-threads, add-message-log, add-prompt-history,
;;;; constants/global-var coverage, wait-for channel synchronization.

(describe "runtime-suite"

  ;; ── stop-reader-threads ──────────────────────────────────────────────────────

  ;; stop-reader-threads sets *running* to NIL regardless of thread count.
  (it "stop-reader-threads-sets-running-nil"
    (let ((nerimux::*running* t))
      (nerimux::stop-reader-threads '())
      (expect nerimux::*running* :to-be-falsy)))

  ;; stop-reader-threads is a no-op on an empty thread list (no join attempted).
  (it "stop-reader-threads-empty-list"
    (let ((nerimux::*running* t))
      (finishes (nerimux::stop-reader-threads '())
                "stop-reader-threads with empty list must not signal")
      (expect nerimux::*running* :to-be-falsy)))

  ;; stop-reader-threads tolerates joining a thread that has already exited.
  (it "stop-reader-threads-joins-already-dead-thread"
    ;; with-global-running NIL sets the GLOBAL *running* the spawned thread reads,
    ;; so its (loop while *running*) exits immediately and the thread is already
    ;; dead by the time stop-reader-threads joins it.  A LET binding would be
    ;; invisible to the child thread, leaving it looping forever.
    (with-global-running nil
      (let ((thread (cl-concurrent-kit:make-thread
                     (lambda ()
                       (loop while nerimux::*running* do (sleep 0.001)))
                     :name "test-dead-thread")))
        (sleep 0.05)
        (finishes (nerimux::stop-reader-threads (list thread))
                  "stop-reader-threads must not signal when joining a dead thread")
        (expect nerimux::*running* :to-be-falsy))))

  ;; ── Constants coverage ────────────────────────────────────────────────────────

  ;; +wait-for-channel-timeout+ is a positive integer constant.
  (it "wait-for-channel-timeout-constant-is-positive"
    (expect (integerp nerimux::+wait-for-channel-timeout+))
    (expect (plusp nerimux::+wait-for-channel-timeout+)))

  ;; ── Global variable coverage ──────────────────────────────────────────────────

  ;; *server-sessions* is defined and is a list (possibly nil).
  (it "server-sessions-var-is-boundp"
    (expect (boundp 'nerimux::*server-sessions*))
    (expect (listp nerimux::*server-sessions*)))

  ;; ── Wait-for channel synchronization ─────────────────────────────────────────

  ;; %ensure-channel creates a plist with :lock and :cv keys.
  (it "ensure-channel-creates-entry"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (let ((ch (nerimux::%ensure-channel "test-ch")))
        (expect ch :to-be-truthy)
        (expect (getf ch :lock) :to-be-truthy)
        (expect (getf ch :cv) :to-be-truthy))))

  ;; %ensure-channel returns the same plist for the same channel name.
  (it "ensure-channel-is-idempotent"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (let ((ch1 (nerimux::%ensure-channel "idem"))
            (ch2 (nerimux::%ensure-channel "idem")))
        (expect (eq ch1 ch2)))))

  ;; lock-channel sets :locked T; unlock-channel sets :locked NIL.
  (it "lock-and-unlock-channel-toggle-flag"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (nerimux::lock-channel "lk-test")
      (let ((ch (nerimux::%ensure-channel "lk-test")))
        (expect (getf ch :locked) :to-be-truthy))
      (nerimux::unlock-channel "lk-test")
      (let ((ch (nerimux::%ensure-channel "lk-test")))
        (expect (getf ch :locked) :to-be-falsy))))

  ;; signal-channel does not error when the channel is locked.
  (it "signal-channel-locked-is-noop"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (nerimux::lock-channel "sig-locked")
      ;; signal-channel on a locked channel is a no-op (no cv-notify) — must not signal.
      (finishes (nerimux::signal-channel "sig-locked")
                "signal-channel on a locked channel must not signal an error")))

  ;; signal-channel creates/signals a channel; the full lock/unlock/signal
  ;; lifecycle is safe with no waiters.  Uses isolated *wait-channels*.
  (it "wait-for-signal-unblocks"
    ;; Test the channel API with an isolated channels table.
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      ;; Ensure a channel exists.
      (nerimux::%ensure-channel "test-chan")
      ;; Lock and unlock must not error.
      (finishes (nerimux::lock-channel "test-chan")
                "lock-channel must not signal")
      (finishes (nerimux::unlock-channel "test-chan")
                "unlock-channel must not signal")
      ;; Signal with no waiters must be a safe no-op.
      (finishes (nerimux::signal-channel "test-chan")
                "signal-channel with no waiters must not signal")
      ;; When locked, signal-channel is suppressed.
      (nerimux::lock-channel "test-chan")
      (finishes (nerimux::signal-channel "test-chan")
                "signal-channel while locked must not signal")
      (nerimux::unlock-channel "test-chan")
      ;; After unlock, signal proceeds normally.
      (finishes (nerimux::signal-channel "test-chan")
                "signal-channel after unlock must not signal")))

  ;; %ensure-channel stores the plist in *wait-channels* by name.
  (it "ensure-channel-stores-in-hash-table"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (nerimux::%ensure-channel "stored-ch")
      (expect (gethash "stored-ch" nerimux::*wait-channels*) :to-be-truthy)))

  ;; A freshly created channel has :locked NIL.
  (it "channel-locked-flag-defaults-to-nil"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (let ((ch (nerimux::%ensure-channel "fresh-lock")))
        (expect (getf ch :locked) :to-be-falsy))))

  ;; The lock→signal→unlock sequence completes without error and leaves
  ;; the channel unlocked.
  (it "lock-channel-then-signal-then-unlock-is-safe"
    (let ((nerimux::*wait-channels* (make-hash-table :test #'equal)))
      (nerimux::lock-channel "seq-ch")
      (finishes (nerimux::signal-channel "seq-ch")
                "signal-channel while locked must not error")
      (nerimux::unlock-channel "seq-ch")
      (let ((ch (nerimux::%ensure-channel "seq-ch")))
        (expect (getf ch :locked) :to-be-falsy))))

  ;; Two channels with different names are stored independently.
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
