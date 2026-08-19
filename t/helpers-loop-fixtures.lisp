(in-package #:nerimux/test)

;;;; Event-loop isolation fixtures.

(defmacro with-global-running (value &body body)
  "Run BODY with the GLOBAL value of nerimux::*running* set to VALUE, restoring
   the prior global value afterward.

   Why not (let ((nerimux::*running* value)) ...)?  A LET establishes a
   thread-LOCAL dynamic binding visible only in the current thread.  Reader and
   status-timer threads spawned inside BODY do NOT inherit the parent's dynamic
   bindings; they observe the GLOBAL value of *running*.  A LET binding is
   therefore invisible to them: they never see the stop signal, loop forever,
   outlive join-thread's timeout, and leak into later suites as background work.
   Mutating the global with SETF is what those threads actually observe, so any
   test that spawns a reader/timer thread must drive *running* through this
   macro rather than a LET."
  (let ((saved (gensym "SAVED-RUNNING")))
    `(let ((,saved nerimux::*running*))
       (setf nerimux::*running* ,value)
       (unwind-protect (progn ,@body)
         (setf nerimux::*running* ,saved)))))

(defun stop-nerimux-threads ()
  "Stop and join every PTY-reader / status-timer / background-shell thread that
   a test may have spawned, so none leaks into a later test.

   Dispatching :split-*, :new-window, :new-session or :respawn-pane spawns a real
   pane and calls START-READER-THREAD; that reader loops while the GLOBAL
   *running* is true.  We clear the global so the loops exit, join the named
   threads (bounded), then restore *running* to T for the next test.  Threads
   are matched by name, so no global registry is required.

   IMPORTANT: after signaling *running*=NIL we SLEEP before restoring it.
   Reader/timer loops only observe *running* between poll cycles (readers poll
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
                        (search "nerimux-status-timer" name)
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

   Also isolates prompt/overlay/menu/popup state so that UI state created by
   one test does not leak into subsequent event-loop tests."
  `(let ((nerimux::*dirty* nil)
         (nerimux::*last-mouse-click* nil)
         (nerimux::*key-table* nil)
         ;; Tests feed key bytes microseconds apart, a rate no real terminal
         ;; produces for typed keys.  Reset key history to avoid triggering the
         ;; assume-paste-time heuristic on every second key.
         (nerimux::*last-ground-key-time* nil)
         (nerimux::*server-marked-pane* nil)
         (nerimux::*client-read-only* nil)
         (nerimux/prompt:*prompt* nil)
         (nerimux/prompt:*overlay* nil)
         (nerimux/prompt:*overlay-scroll-offset* 0)
         (nerimux/prompt:*overlay-shown-at* 0)
         (nerimux/prompt:*display-panes-active* nil)
         (nerimux/prompt:*active-menu* nil)
         (nerimux/prompt:*active-popup* nil))
     (with-global-running t
       (unwind-protect (progn ,@body)
         (stop-nerimux-threads)))))
