(in-package #:nerimux)

(defun %scroll-client-process-log (conn delta)
  (let* ((entries (client-conn-process-log conn))
         (max-scroll (max 0 (1- (length entries)))))
    (setf (client-conn-process-log-scroll conn)
          (max 0
               (min max-scroll
                    (+ (client-conn-process-log-scroll conn) delta))))
    (%mark-dirty)))

(defun %handle-process-log-key (conn payload)
  (cond
    ((%client-byte-p payload 27)
     (%client-esc-swallow-start conn)
     (%set-client-modal conn nil))
    ((%client-key-p payload #\q) (%set-client-modal conn nil))
    ((%client-key-p payload #\n) (%scroll-client-process-log conn 1))
    ((%client-key-p payload #\p) (%scroll-client-process-log conn -1)))
  nil)
