(in-package #:nerimux/commands)

(defun close-pane-pty (target)
  "Close TARGET's PTY, leaving PANE-FD/PANE-PID as they are.

   Deliberately does NOT retire the pane: %FORCE-KILL-PANES
   (server-multi-loop.lisp) closes every pane, waits out the SIGHUP grace
   period, and then reads PANE-PID back to escalate to SIGKILL on whichever
   child ignored the hangup.  Clearing the pid here would make that
   escalation silently target nothing and leave those children orphaned.
   Callers that are retiring a pane for good want RETIRE-PANE-PTY below."
  (nerimux/ports:close-pty (pane-fd target) (pane-pid target)))

(defun retire-pane-pty (target)
  "Close TARGET's PTY and mark the pane dead, publishing the dead marker
   BEFORE the close.

   The ordering is the point.  TARGET's reader thread polls (PANE-FD TARGET)
   afresh every +PTY-POLL-TIMEOUT-US+ from another thread, and nothing else
   stops it: %RUN-READER-STATES loops on the GLOBAL *RUNNING* flag, so
   STOP-READER-THREADS is a whole-server shutdown and there is no per-pane
   stop other than the fd going non-positive.  Closing first and clearing
   second would leave a window in which that thread reads a positive fd that
   is already closed -- and once the OS reuses that number for the next pane
   or client (POSIX hands out the lowest free descriptor), the consequence is
   not a harmless leak:

     * the orphaned reader polls and drains a descriptor belonging to someone
       else, stealing bytes that a read(2) delivers exactly once; and
     * when that descriptor reports EOF, READER-EOF-STATE runs for the
       retired pane -- its (> (PANE-FD PANE) 0) guard still passes on the
       stale number -- looks the fd up in *PTY-PROCESSES*, and closes what it
       finds there, which is a different, live pane's shell.

   Clearing first closes that window: the reader observes -1, stops, and can
   never act on a descriptor this pane no longer owns.  Clearing PANE-PID
   likewise keeps a later teardown from signalling a pid the OS may have
   recycled -- the same reasoning READER-EOF-STATE records for the EOF path."
  (let ((fd (pane-fd target))
        (pid (pane-pid target)))
    (setf (pane-fd target) -1
          (pane-pid target) -1)
    (nerimux/ports:close-pty fd pid)))
