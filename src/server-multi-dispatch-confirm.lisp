(in-package #:nerimux)

(defun %open-confirm-view (conn operation fields action &key on-cancel)
  "Put a y/n confirmation in front of CONN and remember what to run on y.
   OPERATION titles the box; FIELDS is the ordered (LABEL . VALUE) body."
  (setf (client-conn-confirm-view conn)
        (nerimux/renderer:make-confirm-view :operation operation
                                            :fields fields
                                            :prompt-p t)
        (client-conn-confirm-action conn) action
        (client-conn-confirm-cancel-action conn) on-cancel)
  (%set-client-modal conn :confirm)
  nil)

(defun %close-confirm-view (conn)
  "Take the confirmation down and forget its pending action."
  (setf (client-conn-confirm-view conn) nil
        (client-conn-confirm-action conn) nil
        (client-conn-confirm-cancel-action conn) nil)
  (%set-client-modal conn nil))

(defun %handle-confirm-key (session conn payload)
  "Answer the confirmation CONN is looking at.  Returns two values: whether the
   key was consumed here, and the loop disposition.

   Only y and n are consumed.  Every other key is swallowed too, a
   confirmation that let j scroll the tree underneath it would be asking about
   one thing while the user changed another."
  (declare (ignore session))
  (let ((action (client-conn-confirm-action conn))
        (cancel (client-conn-confirm-cancel-action conn)))
    (cond
      ((%client-key-p payload #\y)
        (%close-confirm-view conn)
        (values t (and action (funcall action))))
      ((%client-key-p payload #\n)
        (%close-confirm-view conn)
        (%client-notify conn "cancelled")
        (values t (and cancel (funcall cancel))))
      (t (values t nil)))))
