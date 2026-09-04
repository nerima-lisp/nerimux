(in-package #:nerimux)

(defun %picker-selected-item (conn)
  (let ((items (%client-picker-visible-items conn)))
    (and items (nth (client-conn-picker-index conn) items))))

(defun %set-client-picker-query (conn value)
  (when (stringp value)
    (setf (client-conn-picker-query conn) value
          (client-conn-picker-index conn) 0)
    (%mark-dirty)
    t))

(defun %set-client-picker-regex (conn value supplied-p)
  (setf (client-conn-picker-regex-p conn)
        (if supplied-p
            (cond
              ((member value '(:on "on" "true" "1" t) :test #'equal) t)
              ((member value '(:off "off" "false" "0" nil) :test #'equal) nil)
              (t (client-conn-picker-regex-p conn)))
            (not (client-conn-picker-regex-p conn)))
        (client-conn-picker-index conn) 0)
  (%mark-dirty)
  (client-conn-picker-regex-p conn))

(defun %delete-client-picker-query-character (conn)
  (let ((query (client-conn-picker-query conn)))
    (when (plusp (length query))
      (setf (client-conn-picker-query conn) (subseq query 0 (1- (length query)))
            (client-conn-picker-index conn) 0)
      (%mark-dirty)
      t)))

(defun %append-client-picker-query-octets (conn payload)
  (let ((text
          (cond
            ((stringp payload) payload)
            ((vectorp payload)
             (handler-case
                 (cl-codec-kit:octets-to-string payload :encoding :utf-8)
               (cl-codec-kit:decode-error () nil))))))
    (when (and text (every (lambda (character) (>= (char-code character) 32)) text))
      (setf (client-conn-picker-query conn)
            (concatenate 'string (client-conn-picker-query conn) text)
            (client-conn-picker-index conn) 0)
      (%mark-dirty)
      t)))

(defun %move-client-picker-index (conn delta)
  (let ((items (%client-picker-visible-items conn)))
    (when items
      (setf (client-conn-picker-index conn)
            (mod (+ (client-conn-picker-index conn) delta) (length items)))
      (%mark-dirty)
      t)))

(defun %handle-client-picker-key-payload (session conn payload)
  (cond
    ((or (equalp payload #(13)) (equalp payload #(10)))
     (%select-client-picker-item session conn))
    ((equalp payload #(27))
     (%client-esc-swallow-start conn)
     (%close-client-picker conn)
     t)
    ((equalp payload #(18)) (%set-client-picker-regex conn nil nil))
    ((equalp payload #(16)) (%move-client-picker-index conn -1))
    ((equalp payload #(14)) (%move-client-picker-index conn 1))
    ((or (equalp payload #(8)) (equalp payload #(127)))
     (%delete-client-picker-query-character conn))
    (t (%append-client-picker-query-octets conn payload))))
