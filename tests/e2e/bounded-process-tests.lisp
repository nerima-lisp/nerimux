(load (merge-pathnames "helpers.lisp" *load-truename*))

(let ((passed 0) (failed 0))
  (flet ((run-case (name function)
           (handler-case
               (progn (funcall function)
                      (incf passed)
                      (format t "~&[bounded-process] PASS ~A~%" name))
             (error (condition)
               (incf failed)
               (format t "~&[bounded-process] FAIL ~A -- ~A~%" name condition)))))
    (run-case
     "exit code and separate output streams"
     (lambda ()
       (assert
        (equal '(7 "output" "error" nil)
               (multiple-value-list
                (run-program-bounded
                 "/bin/sh" '("-c" "printf output; printf error >&2; exit 7")))))))
    (run-case
     "large output is not truncated"
     (lambda ()
       (multiple-value-bind (code out err timed-out)
           (run-program-bounded
            "/bin/sh" '("-c" "i=0; while [ $i -lt 20000 ]; do printf abcdefgh; printf 12345678 >&2; i=$((i+1)); done"))
         (assert (eql code 0))
         (assert (not timed-out))
         (assert (string= out (with-output-to-string (stream)
                               (dotimes (i 20000) (write-string "abcdefgh" stream)))))
         (assert (string= err (with-output-to-string (stream)
                               (dotimes (i 20000) (write-string "12345678" stream))))))))
    (run-case
     "timeout kills the direct child"
     (lambda ()
       (multiple-value-bind (code out err timed-out)
           (run-program-bounded "/bin/sleep" '("10") :timeout-seconds 0.1)
         (assert timed-out)
         (assert (eql code 9))
         (assert (string= out ""))
         (assert (string= err "")))))
    (run-case
     "descendant output handles do not delay return"
     (lambda ()
       (let ((start (get-internal-real-time)))
         (unwind-protect
              (progn
                (assert
                 (equal '(0 "parent" "error" nil)
                        (multiple-value-list
                         (run-program-bounded
                          "/bin/sh"
                          '("-c" "/bin/sleep 3 & printf parent; printf error >&2; exit 0")
                          :timeout-seconds 0.1))))
                (assert (< (/ (- (get-internal-real-time) start)
                              internal-time-units-per-second)
                           2)))
           (sleep 3))))))
  (format t "~&[bounded-process] ~D selected, ~D passed, ~D failed~%"
          (+ passed failed) passed failed)
  (sb-ext:exit :code (if (and (= passed 4) (zerop failed)) 0 1)))
