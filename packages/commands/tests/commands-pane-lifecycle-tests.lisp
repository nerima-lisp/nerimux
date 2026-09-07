(in-package #:nerimux/test/commands)

(describe "commands-suite"

  (it "workspace-agent-stop-failure-retains-ownership-for-retry"
    (let* ((worktree (nerimux/workspace-model:make-worktree :id "retry"))
           (pane (make-pane :id 94 :fd 71 :pid 72 :agent-kind :codex))
           (calls 0))
      (nerimux/pane:worktree-add-pane worktree pane)
      (let ((nerimux/ports:*close-pty*
              (lambda (fd pid)
                (assert (= 71 fd))
                (assert (= 72 pid))
                (when (= 1 (incf calls)) (error "termination failed"))
                (values 9 :signaled))))
        (sb-thread:join-thread (nerimux/commands:stop-worktree-agent worktree) :timeout 5)
        (expect (= 71 (pane-fd pane)))
        (expect (= 72 (pane-pid pane)))
        (expect (null (nerimux/pane:pane-stop-requested pane)))
        (expect (not (nerimux/pane:pane-process-exited-p pane)))
        (sb-thread:join-thread (nerimux/commands:stop-worktree-agent worktree) :timeout 5)
        (expect (= 2 calls))
        (expect (nerimux/pane:pane-process-exited-p pane)))))

  (it "workspace-agent-stop-is-async-confirmed-and-close-once"
    (let* ((worktree (nerimux/workspace-model:make-worktree :id "stop"))
           (pane (make-pane :id 93 :fd 61 :pid 62 :agent-kind :codex))
           (entered (sb-thread:make-semaphore))
           (release (sb-thread:make-semaphore))
           (calls 0)
           (worker nil))
      (nerimux/pane:worktree-add-pane worktree pane)
      (let ((nerimux/ports:*close-pty*
              (lambda (fd pid)
                (assert (= 61 fd))
                (assert (= 62 pid))
                (incf calls)
                (sb-thread:signal-semaphore entered)
                (assert (sb-thread:wait-on-semaphore release :timeout 5))
                (values 9 :signaled))))
        (unwind-protect
             (progn
               (setf worker (nerimux/commands:stop-worktree-agent worktree))
               (expect (sb-thread:wait-on-semaphore entered :timeout 5))
               (expect (null (nerimux/pane:pane-process-exited-p pane)))
               (expect (eq :running (nerimux/pane:worktree-agent-state worktree)))
               (expect (null (nerimux/commands:stop-worktree-agent worktree)))
               (sb-thread:signal-semaphore release)
               (sb-thread:join-thread worker :timeout 5)
               (setf worker nil)
               (close-pane-pty pane)
               (expect (= 1 calls))
               (expect (nerimux/pane:pane-process-exited-p pane))
               (expect (eq :exited (nerimux/pane:worktree-agent-state worktree)))
               (expect (eq pane (nerimux/workspace-model:worktree-agent-pane worktree))))
          (sb-thread:signal-semaphore release)
          (when worker (sb-thread:join-thread worker :timeout 5))))))


  (it "close-pane-pty-passes-fd-then-pid"
    (let ((pane (make-pane :id 91 :x 0 :y 0 :width 20 :height 5
                           :fd 41 :pid 42 :screen (make-screen 20 5)))
          (received :never-called))
      (let ((nerimux/ports:*close-pty*
              (lambda (master-fd child-pid)
                (setf received (list master-fd child-pid)))))
        (close-pane-pty pane))
      (expect (equal (list 41 42) received))))

  (it "retire-pane-pty-clears-identifiers-before-closing"
    (let ((pane (make-pane :id 92 :x 0 :y 0 :width 20 :height 5
                           :fd 51 :pid 52 :screen (make-screen 20 5)))
          (observed :never-called))
      (let ((nerimux/ports:*close-pty*
              (lambda (master-fd child-pid)
                (setf observed (list master-fd child-pid
                                     (pane-fd pane) (pane-pid pane))))))
        (nerimux/commands:retire-pane-pty pane))
      (expect (equal (list 51 52 -1 -1) observed))
      (expect (= -1 (pane-fd pane)))
      (expect (= -1 (pane-pid pane))))))
