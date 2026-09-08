(defparameter *benchmark-repo-root*
  (truename (pathname (second sb-ext:*posix-argv*))))

(load (merge-pathnames "tests/e2e/helpers.lisp" *benchmark-repo-root*))

(defparameter *e2e-repo-root* *benchmark-repo-root*)
(load (merge-pathnames "tests/e2e/attach-scenario.lisp" *benchmark-repo-root*))

(use-package :nerimux/pty)

(defconstant +benchmark-timeout-seconds+ 8)
(defconstant +benchmark-buffer-size+ 65536)

(defun %benchmark-elapsed-milliseconds (start end)
  (* 1000.0d0 (/ (- end start) internal-time-units-per-second)))

(defun %benchmark-wait-for-first-output (fd start)
  (let ((deadline (+ start
                    (* +benchmark-timeout-seconds+
                       internal-time-units-per-second))))
    (loop
      (when (> (get-internal-real-time) deadline)
        (return nil))
      (when (select-fds (list fd) nerimux/ports:+poll-timeout-us+)
        (let ((chunk
                (pty-read-blocking-into
                 fd
                 (make-array +benchmark-buffer-size+
                             :element-type '(unsigned-byte 8)))))
          (when chunk
            (return t)))))))

(defun %benchmark-command (binary mode)
  (if (string= mode "attach")
      (format nil "exec ~S attach" binary)
      "printf 'NMX_CONTROL_FRAME\\n'"))

(defun %benchmark-one (binary mode)
  (let ((elapsed nil))
    (call-with-isolated-e2e-environment
     (lambda (root)
       (declare (ignore root))
       (let ((worktree (%prepare-bare-worktree))
             (start nil))
         (multiple-value-bind (fd pid)
             (progn
               (setf start (get-internal-real-time))
               (forkpty-with-shell
                24 80
                :start-dir worktree
                :default-command (%benchmark-command binary mode)
                :environment (sb-ext:posix-environ)))
           (unwind-protect
                (when (%benchmark-wait-for-first-output fd start)
                  (setf elapsed
                        (%benchmark-elapsed-milliseconds
                         start
                         (get-internal-real-time))))
             (pty-close fd pid)))))
     :cleanup
     (when (string= mode "attach")
       (lambda (root)
         (declare (ignore root))
         (ignore-errors
           (run-program-bounded binary '("kill" "--force")
                                  :timeout-seconds 10)))))
    elapsed))

(let* ((binary (third sb-ext:*posix-argv*))
       (mode (fourth sb-ext:*posix-argv*)))
  (format t "mode=~A binary=~A~%" mode binary)
  (finish-output)
  (loop for sample from 1 to 5
        for elapsed = (%benchmark-one binary mode)
        do (format t "sample-~D=~,3F ms~%" sample (or elapsed -1.0))
           (finish-output)))
