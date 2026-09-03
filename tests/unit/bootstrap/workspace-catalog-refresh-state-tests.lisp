(in-package #:nerimux/test)

(describe "workspace-catalog-refresh-state-suite"

  (it "mark-then-settle-clears-the-refreshing-mark"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let* ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal)))
        (nerimux::%set-workspace-catalog-refresh-state organizations :mark)
        (expect (plusp (hash-table-count nerimux::*workspace-refreshing-ids*)))
        (nerimux::%set-workspace-catalog-refresh-state organizations :settle)
        (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
        (expect (zerop (hash-table-count nerimux::*workspace-stale-ids*))))))

  (it "settle-with-stale-p-moves-the-node-to-the-stale-set"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal)))
        (nerimux::%set-workspace-catalog-refresh-state organizations :mark)
        (nerimux::%set-workspace-catalog-refresh-state organizations :settle :stale-p t)
        (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
        (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*))))))

  (it "refresh-client-picker-on-complete-settles-refreshing-ids-not-re-marks-them"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
            (conn (nerimux::%make-client-conn))
            (captured-on-complete nil)
            (completed-organizations nil))
        (setf nerimux::*clients* (list conn))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key query on-catalog on-complete on-error
                                on-repository-error on-progress callback-dispatch)
                       (declare (ignore query on-error on-repository-error
                                        on-progress callback-dispatch))
                       (setf captured-on-complete on-complete)
                       (when on-catalog (funcall on-catalog organizations))))
               (nerimux::%refresh-client-picker
                conn :on-complete (lambda (value)
                                    (setf completed-organizations value)))
               (expect (plusp (hash-table-count nerimux::*workspace-refreshing-ids*)))
               (expect captured-on-complete)
               (funcall captured-on-complete organizations)
               (expect (eq organizations completed-organizations))
               (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  (it "refresh-client-picker-builds-items-without-vcs"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (conn (nerimux::%make-client-conn))
            (completed nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () nil))
               (nerimux::%refresh-client-picker
                conn :on-complete
                (lambda (received)
                  (setf completed received)))
               (expect (equal organizations completed))
               (expect (equal (length (nerimux/picker:build-global-picker-items
                                       organizations))
                              (length (nerimux::client-conn-picker-items conn)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available)))))

  (it "refresh-client-picker-settles-a-synchronous-startup-error"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let* ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
            (conn (nerimux::%make-client-conn))
            (nerimux::*clients* (list conn))
            (received-error nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (error "synthetic picker startup failure")))
               (nerimux::%refresh-client-picker
                conn :on-error
                (lambda (condition)
                  (setf received-error condition)))
               (expect (typep received-error 'error))
               (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
               (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  (it "refresh-client-picker-reports-a-live-asynchronous-error"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let* ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
             (nerimux::*dirty* nil)
             (nerimux/vcs::*workspace-organizations* organizations)
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
             (conn (nerimux::%make-client-conn))
             (nerimux::*clients* (list conn))
             (captured-on-error nil)
             (received-error nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key on-error &allow-other-keys)
                       (setf captured-on-error on-error)))
               (nerimux::%refresh-client-picker
                conn :on-error (lambda (condition)
                                 (setf received-error condition)))
               (expect captured-on-error)
               (funcall captured-on-error (make-condition 'error))
               (expect (typep received-error 'error))
               (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
               (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  (it "add-client-on-progress-callback-updates-workspace-scan-progress"
    (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
          (nerimux::*workspace-catalog-loaded-p* nil)
          (nerimux::*workspace-scan-progress* nil)
          (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
          (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
          (nerimux::*clients* nil)
          (nerimux::*dirty* nil)
          (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
          (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
          (captured-on-progress nil))
      (unwind-protect
           (with-test-listener (listener path (%test-socket-path "add-client-on-progress")
                                          :backlog 4)
             (let ((client nil)
                   (server-sock nil))
               (unwind-protect
                    (progn
                      (setf client (nerimux/net:connect-to path)
                            server-sock (nerimux/net:accept-connection listener))
                      (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                            (lambda () t)
                            (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                            (lambda (&key query on-catalog on-complete on-error
                                       on-repository-error on-progress callback-dispatch)
                              (declare (ignore query on-catalog on-complete on-error
                                               on-repository-error callback-dispatch))
                              (setf captured-on-progress on-progress)))
                      (when server-sock
                        (nerimux::%add-client server-sock)))
                 (when client (ignore-errors (nerimux/net:close-socket client)))
                 (when server-sock (ignore-errors (nerimux/net:close-socket server-sock))))))
        (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
              (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async) refresh-fn))
      (expect captured-on-progress)
      (funcall captured-on-progress 7)
      (expect (eql 7 nerimux::*workspace-scan-progress*))))

  (it "add-client-refresh-callbacks-settle-and-rebind-live-clients"
    (multiple-value-bind (organizations organization repository)
        (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
            (nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* nil)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
            (captured nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key on-catalog on-complete on-error on-repository-error
                                on-progress callback-dispatch &allow-other-keys)
                       (declare (ignore callback-dispatch))
                       (setf captured (list on-catalog on-complete on-error
                                            on-repository-error on-progress))))
               (with-stubbed-fdefinition
                   ((nerimux/net:socket-stream
                      (lambda (socket)
                        (declare (ignore socket))
                        (make-two-way-stream
                         (make-string-input-stream "")
                         (make-string-output-stream))))
                    (nerimux/net:socket-fd (lambda (socket)
                                             (declare (ignore socket))
                                             1))
                    (nerimux/net:close-socket (lambda (&rest args)
                                                (declare (ignore args)))))
                 (let ((conn (nerimux::%add-client :socket)))
                   (expect conn)
                   (expect captured)
                   (funcall (fifth captured) 3)
                   (funcall (first captured) organizations)
                   (funcall (fourth captured) repository (make-condition 'error))
                   (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*)))
                   (funcall (second captured) organizations)
                   (expect nerimux::*workspace-catalog-loaded-p*)
                   (expect (null nerimux::*workspace-scan-progress*))
                   (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
                   (expect (member organization
                                   (nerimux::client-conn-picker-items conn)
                                   :key #'nerimux/picker:picker-item-organization)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  (it "add-client-does-not-start-refresh-without-vcs"
    (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
          (nerimux::*workspace-catalog-loaded-p* nil)
          (nerimux::*clients* nil)
          (nerimux::*dirty* nil)
          (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
          (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
          (refresh-started nil))
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                   (lambda () nil)
                   (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (setf refresh-started t)))
             (with-stubbed-fdefinition
                 ((nerimux/net:socket-stream
                    (lambda (socket)
                      (declare (ignore socket))
                      (make-two-way-stream
                       (make-string-input-stream "")
                       (make-string-output-stream))))
                  (nerimux/net:socket-fd
                    (lambda (socket)
                      (declare (ignore socket))
                      1)))
               (let ((conn (nerimux::%add-client :socket)))
                 (expect conn)
                 (expect (null refresh-started))
                 (expect (null nerimux::*workspace-catalog-refresh-started-p*))
                 (expect (null nerimux::*workspace-catalog-loaded-p*))
                 (expect (member conn nerimux::*clients*)))))
        (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
              (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
              refresh-fn))))

  (it "add-client-synchronous-refresh-failure-settles-the-catalog-as-stale"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
            (nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* 3)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&rest args)
                       (declare (ignore args))
                       (error "synchronous refresh startup failure")))
               (with-stubbed-fdefinition
                   ((nerimux/net:socket-stream (lambda (socket)
                                                 (declare (ignore socket))
                                                 (make-two-way-stream
                                                  (make-string-input-stream "")
                                                  (make-string-output-stream))))
                    (nerimux/net:socket-fd (lambda (socket)
                                             (declare (ignore socket))
                                             1))
                    (nerimux/net:close-socket (lambda (&rest args)
                                                (declare (ignore args)))))
                 (let ((conn (nerimux::%add-client :socket)))
                   (expect conn)
                   (expect nerimux::*workspace-catalog-loaded-p*)
                   (expect (null nerimux::*workspace-scan-progress*))
                   (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
                   (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn)))))

  (it "add-client-terminal-refresh-error-settles-the-catalog-as-stale"
    (multiple-value-bind (organizations) (%make-server-dispatch-helper-fixture)
      (let ((nerimux::*workspace-catalog-refresh-started-p* nil)
            (nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* 4)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* organizations)
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (refresh-fn (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async))
            (captured-on-error nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key on-error)
                       (setf captured-on-error on-error)))
               (with-stubbed-fdefinition
                   ((nerimux/net:socket-stream
                      (lambda (socket)
                        (declare (ignore socket))
                        (make-two-way-stream
                         (make-string-input-stream "")
                         (make-string-output-stream))))
                    (nerimux/net:socket-fd
                      (lambda (socket)
                        (declare (ignore socket))
                        1))
                    (nerimux/net:close-socket
                      (lambda (&rest args)
                        (declare (ignore args)))))
                 (let ((conn (nerimux::%add-client :socket)))
                   (expect conn)
                   (expect captured-on-error)
                   (expect (plusp (hash-table-count nerimux::*workspace-refreshing-ids*)))
                   (funcall captured-on-error (make-condition 'error))
                   (expect nerimux::*workspace-catalog-loaded-p*)
                   (expect (null nerimux::*workspace-scan-progress*))
                   (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
                   (expect (plusp (hash-table-count nerimux::*workspace-stale-ids*)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh-fn))))))

  (it "drop-client-ignores-stream-errors-while-sending-bye"
    (let* ((stream (make-two-way-stream
                    (make-string-input-stream "")
                    (make-string-output-stream)))
           (conn (nerimux::%make-client-conn :stream stream))
           (nerimux::*clients* (list conn)))
      (with-stubbed-fdefinition
          ((nerimux/transport:send-frame
            (lambda (&rest args)
              (declare (ignore args))
              (error 'stream-error :stream stream))))
        (nerimux::%drop-client conn :bye t))
      (expect (null nerimux::*clients*))))))
