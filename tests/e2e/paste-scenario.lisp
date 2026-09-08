(defconstant +e2e-paste-size+
  1048576)

(defconstant +e2e-paste-transfer-timeout-seconds+
  300)

(defconstant +e2e-paste-result-timeout-seconds+
  30)

(defconstant +e2e-paste-chunk-size+
  4096)

(defun %paste-worktree ()
  (let ((worktree
          (merge-pathnames "git-attach/worktree/"
                           (uiop:ensure-directory-pathname
                            (or (sb-ext:posix-getenv "TMPDIR") "/tmp/")))))
    (if (probe-file worktree)
        (namestring (truename worktree))
        (%prepare-bare-worktree))))

(defun %make-paste-payload ()
  (let ((payload (make-array +e2e-paste-size+
                             :element-type '(unsigned-byte 8))))
    (dotimes (index +e2e-paste-size+ payload)
      (setf (aref payload index)
            (+ 32 (mod (+ (* index 73) (ash index -8)) 95))))))

(defun %paste-sha256-file (pathname)
  (multiple-value-bind (exit-code stdout stderr timed-out)
      (run-program-bounded "sha256sum" (list (namestring pathname))
                           :timeout-seconds 20 :search t)
    (unless (and (eql exit-code 0) (not timed-out))
      (error "sha256sum failed: exit=~S timeout=~S stderr=~S"
             exit-code timed-out stderr))
    (let ((digest (subseq stdout 0 (position #\Space stdout))))
      (unless (and (= (length digest) 64)
                   (every (lambda (character)
                            (or (digit-char-p character)
                                (find character "abcdef")))
                          digest))
        (error "sha256sum returned an invalid digest: ~S" digest))
      digest)))

(defun %write-paste-payload-file (pathname payload)
  (with-open-file (stream pathname
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create
                          :element-type '(unsigned-byte 8))
    (write-sequence payload stream)))

(defun %write-paste-sequence (fd payload)
  (let ((deadline (+ (get-internal-real-time)
                     (* +e2e-paste-transfer-timeout-seconds+
                        internal-time-units-per-second))))
    (pty-write fd (format nil "~C[200~~" #\Escape))
    (loop for start from 0 below (length payload) by +e2e-paste-chunk-size+
          for end = (min (length payload) (+ start +e2e-paste-chunk-size+))
          do (when (> (get-internal-real-time) deadline)
               (error "paste transfer exceeded ~D seconds after ~D bytes"
                      +e2e-paste-transfer-timeout-seconds+ start))
             (pty-write fd (subseq payload start end)))
    (pty-write fd (format nil "~C[201~~" #\Escape))))

(defun run-paste-scenario (binary)
  (let* ((worktree (%paste-worktree))
         (payload (%make-paste-payload))
         (sent-path (merge-pathnames "paste-sent.bin"
                                     (uiop:ensure-directory-pathname
                                      (sb-ext:posix-getenv "TMPDIR"))))
         (sent-digest nil)
         (ready-marker "NMX_PASTE_READY")
         (command
           (format nil
                   "printf '~C[?2004l'; stty raw -echo; printf 'NMX_PASTE_%s\n' READY; dd iflag=fullblock bs=~D count=1 of=\"$TMPDIR/paste-received.bin\" status=none; set -- $(sha256sum \"$TMPDIR/paste-received.bin\"); printf '\nNMX_PASTE_SHA_%s\n' \"$1\"~%"
                   #\Escape
                   +e2e-paste-size+)))
    (%write-paste-payload-file sent-path payload)
    (setf sent-digest (%paste-sha256-file sent-path))
    (let ((digest-marker (format nil "NMX_PASTE_SHA_~A" sent-digest)))
      (assert (null (search ready-marker command)))
      (assert (null (search digest-marker command)))
      (multiple-value-bind (fd pid)
          (forkpty-with-shell 24 80
                              :start-dir worktree
                              :default-command (format nil "exec ~S attach" binary)
                              :environment (sb-ext:posix-environ))
        (unwind-protect
             (let ((startup-acc (%make-accumulator))
                   (acc (%make-accumulator)))
               (%wait-for-startup-render fd +e2e-startup-timeout-seconds+
                                         startup-acc)
               (pty-write fd command)
               (let ((ready (%wait-for-marker fd ready-marker
                                              +e2e-marker-timeout-seconds+ acc)))
                 (when ready
                   (%write-paste-sequence fd payload))
                 (let ((matched
                         (and ready
                              (%wait-for-marker fd digest-marker
                                                +e2e-paste-result-timeout-seconds+
                                                acc))))
                   (pty-write fd (make-array 2 :element-type '(unsigned-byte 8)
                                              :initial-contents
                                              (list 17 (char-code #\d))))
                   (multiple-value-bind (exit-code exit-kind)
                       (%wait-for-child-exit-draining
                        fd +e2e-detach-timeout-seconds+ acc)
                     (if (and matched (eq :exited exit-kind) (zerop exit-code))
                         (values t
                                 (format nil
                                         "~D-byte bracketed paste matched SHA-256 ~A"
                                         +e2e-paste-size+ sent-digest))
                         (values nil
                                 (format nil
                                         "ready=~A sha256=~A exit-kind=~A exit-code=~A captured=~D bytes"
                                         ready matched exit-kind exit-code
                                         (fill-pointer acc))))))))
          (pty-close fd pid))))))
