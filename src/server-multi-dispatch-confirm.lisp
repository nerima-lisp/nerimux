(in-package #:nerimux)

(defun %open-confirm-view (conn operation fields action)
  "Put a y/n confirmation in front of CONN and remember what to run on y."
  (setf (client-conn-confirm-view conn)
        (nerimux/renderer:make-confirm-view :operation operation
                                            :fields fields
                                            :prompt-p t)
        (client-conn-confirm-action conn) action)
  (%set-client-modal conn :confirm)
  nil)

(defun %close-confirm-view (conn)
  "Take the confirmation down and forget its pending action."
  (setf (client-conn-confirm-view conn) nil
        (client-conn-confirm-action conn) nil)
  (%set-client-modal conn nil))

(defun %handle-confirm-key (session conn payload)
  "Answer the confirmation CONN is looking at."
  (declare (ignore session))
  (let ((action (client-conn-confirm-action conn)))
    (cond
      ((%client-key-p payload #\y)
       (%close-confirm-view conn)
       (values t (and action (funcall action))))
      ((%client-key-p payload #\n)
       (%close-confirm-view conn)
       (%client-notify conn "cancelled")
       (values t nil))
      (t (values t nil)))))
