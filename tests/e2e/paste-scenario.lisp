(defconstant +e2e-paste-size+
  1048576)

(defconstant +e2e-paste-transfer-timeout-seconds+
  300)

(defconstant +e2e-paste-result-timeout-seconds+
  30)

(defconstant +e2e-paste-chunk-size+
  256)

(defconstant +e2e-paste-receiver-block-size+
  4096)

(defconstant +e2e-paste-ack-interval-bytes+
  (* 64 1024))

(defconstant +e2e-paste-ack-poll-seconds+
  1/100)

(defconstant +e2e-paste-boundary+
  "NMX-PASTE-BOUNDARY-0123456789")

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

(defun %paste-file-size (pathname)
  (when (probe-file pathname)
    (with-open-file (stream pathname :element-type '(unsigned-byte 8))
      (file-length stream))))

(defun %read-paste-file-octets (pathname)
  (when (probe-file pathname)
    (with-open-file (stream pathname :element-type '(unsigned-byte 8))
      (let* ((bytes (make-array (file-length stream)
                                :element-type '(unsigned-byte 8)))
             (end (read-sequence bytes stream)))
        (if (= end (length bytes))
            bytes
            (subseq bytes 0 end))))))

(defun %wait-for-paste-received-size (pathname expected-bytes deadline)
  (loop for actual-bytes = (or (%paste-file-size pathname) 0)
        when (>= actual-bytes expected-bytes)
          return actual-bytes
        when (> (get-internal-real-time) deadline)
          do (error "paste receiver acknowledgement timed out: expected=~D bytes actual=~D bytes"
                    expected-bytes actual-bytes)
        do (sleep +e2e-paste-ack-poll-seconds+)))

(defun %write-paste-sequence (fd payload received-path deadline)
  (pty-write fd (format nil "~C[200~~" #\Escape))
  (loop for start from 0 below (length payload) by +e2e-paste-chunk-size+
        for end = (min (length payload) (+ start +e2e-paste-chunk-size+))
        do (when (> (get-internal-real-time) deadline)
             (error "paste transfer exceeded ~D seconds after ~D bytes"
                    +e2e-paste-transfer-timeout-seconds+ start))
           (pty-write fd (subseq payload start end))
           (when (or (= end (length payload))
                     (zerop (mod end +e2e-paste-ack-interval-bytes+)))
             (%wait-for-paste-received-size received-path end deadline)))
  (pty-write fd (format nil "~C[201~~" #\Escape))
  (pty-write fd +e2e-paste-boundary+))

(defun %drain-paste-output-once (fd acc)
  (when (select-fds (list fd) +e2e-poll-timeout-us+)
    (let ((chunk
            (pty-read-blocking-into
             fd
             (make-array +e2e-read-buf-size+
                         :element-type '(unsigned-byte 8)))))
      (when chunk
        (%accumulate-chunk acc chunk)))))

(defun %run-paste-writer-draining (fd payload received-path acc)
  (let* ((deadline (+ (get-internal-real-time)
                      (* +e2e-paste-transfer-timeout-seconds+
                         internal-time-units-per-second)))
         (joined-p nil)
         (writer
           (sb-thread:make-thread
            (lambda ()
              (handler-case
                  (progn
                    (%write-paste-sequence fd payload received-path deadline)
                    :completed)
                (serious-condition (condition) condition)))
            :name "e2e-paste-writer")))
    (unwind-protect
         (loop
           (%drain-paste-output-once fd acc)
           (unless (sb-thread:thread-alive-p writer)
             (let ((outcome (sb-thread:join-thread writer)))
               (setf joined-p t)
               (if (eq outcome :completed)
                   (return t)
                   (error "paste writer failed: ~A" outcome))))
           (when (> (get-internal-real-time) deadline)
             (error "paste writer exceeded ~D seconds"
                    +e2e-paste-transfer-timeout-seconds+)))
      (unless joined-p
        (when (sb-thread:thread-alive-p writer)
          (ignore-errors (sb-thread:terminate-thread writer)))
        (ignore-errors (sb-thread:join-thread writer))))))

(defun run-paste-scenario (binary)
  (let* ((worktree (%paste-worktree))
         (payload (%make-paste-payload))
         (tmpdir (uiop:ensure-directory-pathname
                  (sb-ext:posix-getenv "TMPDIR")))
         (sent-path (merge-pathnames "paste-sent.bin" tmpdir))
         (received-path (merge-pathnames "paste-received.bin" tmpdir))
         (boundary-path (merge-pathnames "paste-boundary.actual" tmpdir))
         (sent-digest nil)
         (ready-marker "NMX_PASTE_READY")
         (done-marker "NMX_PASTE_DONE")
         (command
           (format nil
                   "printf '~C[?2004l'; stty raw -echo; printf '\\r\\nNMX_PASTE_%s\\r\\n' READY; dd iflag=fullblock bs=~D count=~D of=\"$TMPDIR/paste-received.bin\" status=none; dd iflag=fullblock bs=~D count=1 of=\"$TMPDIR/paste-boundary.actual\" status=none; printf '\\r\\nNMX_PASTE_%s\\r\\n' DONE~%"
                   #\Escape
                   +e2e-paste-receiver-block-size+
                   (/ +e2e-paste-size+ +e2e-paste-receiver-block-size+)
                   (length +e2e-paste-boundary+))))
    (%write-paste-payload-file sent-path payload)
    (setf sent-digest (%paste-sha256-file sent-path))
    (assert (null (search ready-marker command)))
    (assert (null (search done-marker command)))
    (let ((expected-boundary
            (map '(simple-array (unsigned-byte 8) (*))
                 #'char-code
                 +e2e-paste-boundary+)))
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
                   (%run-paste-writer-draining fd payload received-path acc))
                 (let* ((done
                          (and ready
                               (or (%search-in-tail
                                    done-marker
                                    acc
                                    (max +e2e-search-window-bytes+
                                         (length done-marker)))
                                   (%wait-for-marker
                                    fd done-marker
                                    +e2e-paste-result-timeout-seconds+
                                    acc))))
                        (received-exists-p (not (null (probe-file received-path))))
                        (received-size (and received-exists-p
                                            (%paste-file-size received-path)))
                        (received-digest (and received-exists-p
                                              (%paste-sha256-file received-path)))
                        (boundary-bytes (%read-paste-file-octets boundary-path))
                        (boundary-size (and boundary-bytes
                                            (length boundary-bytes)))
                        (matched
                          (and done
                               received-exists-p
                               (= received-size +e2e-paste-size+)
                               (string= received-digest sent-digest)
                               (equalp boundary-bytes expected-boundary))))
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
                                         "ready=~A done=~A received=~A size=~S sha256=~S boundary-size=~S boundary-bytes=~S exit-kind=~A exit-code=~A captured=~D bytes"
                                         ready done
                                         (if received-exists-p :present :missing)
                                         received-size received-digest boundary-size
                                         (and boundary-bytes
                                              (coerce boundary-bytes 'list))
                                         exit-kind exit-code
                                         (fill-pointer acc))))))))
          (pty-close fd pid))))))
