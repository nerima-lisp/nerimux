(in-package #:nerimux/test)

;;;; Event-loop isolation fixtures.
(defmacro with-global-running (value &body body)
  "Run BODY with the GLOBAL value of nerimux::*running* set to VALUE, restoring
   the prior global value afterward.

   Why not (let ((nerimux::*running* value)) ...)?  A LET establishes a
   thread-LOCAL dynamic binding visible only in the current thread.  Reader
   threads spawned inside BODY do NOT inherit the parent's dynamic
   bindings; they observe the GLOBAL value of *running*.  A LET binding is
   therefore invisible to them: they never see the stop signal, loop forever,
   outlive join-thread's timeout, and leak into later suites as background work.
   Mutating the global with SETF is what those threads actually observe, so any
   test that spawns a reader thread must drive *running* through this macro
   rather than a LET."
  (let ((saved (gensym "SAVED-RUNNING")))
    `(let ((,saved nerimux::*running*))
       (setf nerimux::*running* ,value)
       (unwind-protect 
           (progn
             ,@body)
         (setf nerimux::*running* ,saved)))))

(defun stop-nerimux-threads ()
  "Stop and join every PTY-reader / background-shell thread a test may have
   spawned, so none leaks into a later test.

   Dispatching :split-*, :new-window, :new-session or :respawn-pane spawns a real
   pane and calls START-READER-THREAD; that reader loops while the GLOBAL
   *running* is true.  We clear the global so the loops exit, join the named
   threads (bounded), then restore *running* to T for the next test.  Threads
   are matched by name, so no global registry is required.

   IMPORTANT: after signaling *running*=NIL we SLEEP before restoring it.
   Reader loops only observe *running* between poll cycles (readers poll
   every +pty-poll-timeout-us+ ~= 50 ms).  Without the pause, *running* could
   flip back to T while a reader is still mid-poll and it would never stop.
   Sleeping ~3 poll cycles gives every reader a chance to observe the stop and
   exit before the bounded join."
  (let ((targets
          (remove-if-not
           (lambda (th)
             (let ((name (cl-concurrent-kit:thread-name th)))
               (and (stringp name)
                    (or (search "pty-reader" name)
                        (search "shell-bg" name)))))
           ;; cl-concurrent-kit deliberately wraps no thread-enumeration call --
           ;; it is a debugging facility, not a concurrency primitive -- so this
           ;; reaches for SB-THREAD directly, as runtime.lisp already does.
           (sb-thread:list-all-threads))))
    (when targets
      (setf nerimux::*running* nil)
      (sleep 0.15)
      (dolist (th targets)
        (ignore-errors (nerimux::%join-thread-with-timeout th 2)))
      (setf nerimux::*running* t))))

(defmacro with-loop-state (&body body)
  "Run BODY with the event-loop specials isolated, then stop any reader/timer
   threads BODY spawned (e.g. by dispatching a :split that creates a real pane).

   *running* is driven through its GLOBAL value (via WITH-GLOBAL-RUNNING) rather
   than a LET, because reader threads spawned during BODY read the global; a LET
   binding would be invisible to them and they would leak into later tests.
   STOP-NERIMUX-THREADS joins them before returning.

   Prompt/overlay/menu/popup state used to be isolated here too, as was the
   read-only attach flag; both went with the deletions in R1."
  `(let ((nerimux::*dirty* nil))
     (with-global-running t
                          (unwind-protect 
                              (progn
                                ,@body)
                            (stop-nerimux-threads)))))
