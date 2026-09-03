(in-package #:nerimux)

(defun %client-single-byte (payload)
  (cond
    ((and (stringp payload) (= (length payload) 1))
     (char-code (char payload 0)))
    ((and (vectorp payload) (= (length payload) 1)) (aref payload 0))))

(defun %client-byte-p (payload byte)
  (eql (%client-single-byte payload) byte))

(defun %client-key-p (payload character)
  (%client-byte-p payload (char-code character)))

(defun %client-payload-text (payload)
  (cond
    ((stringp payload) payload)
    ((vectorp payload)
     (handler-case (cl-codec-kit:octets-to-string payload :encoding :utf-8)
       (cl-codec-kit:decode-error ()
         nil)))))
