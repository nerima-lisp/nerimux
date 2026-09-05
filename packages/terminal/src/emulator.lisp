(in-package #:nerimux/terminal/emulator)

(defun screen-process-bytes (screen bytes &key (start 0) (end (length bytes)))
  "Feed raw PTY bytes BYTES[START..END) into SCREEN, advancing the CPS parser."
  (loop for i from start below
        end
        for byte = (aref bytes i)
        do (setf (screen-parser screen) (funcall (screen-parser screen)
                                                 screen
                                                 byte))))
