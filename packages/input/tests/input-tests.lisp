(in-package #:nerimux/test/input)

(defmacro with-function-stubs ((&rest bindings) &body body)
  (let ((saved (gensym "SAVED")))
    `(let ((,saved
            (list
             ,@(mapcar
                (lambda (binding)
                  `(cons ',(first binding) (symbol-function ',(first binding))))
                bindings))))
       (unwind-protect 
           (progn
             ,@(mapcar
                (lambda (binding)
                  `(setf (symbol-function ',(first binding)) (function
                                                              ,(second binding))))
                bindings)
             ,@body)
         (dolist (entry ,saved)
           (setf (symbol-function (car entry)) (cdr entry)))))))

(describe "input-suite"

  (it "with-raw-mode-expands-enable-before-body"
    (let* ((form (macroexpand-1 '(nerimux/input::with-raw-mode :body-marker)))
           (text (prin1-to-string form))
           (enable-pos (search "ENABLE-RAW-MODE!" text))
           (body-pos (search ":BODY-MARKER" text)))
      (expect enable-pos :to-be-truthy)
      (expect body-pos :to-be-truthy)
      (expect (< enable-pos body-pos))))

  (it "with-raw-mode-installs-disable-only-in-cleanup"
    (let* ((form (macroexpand-1 '(nerimux/input::with-raw-mode :body-marker)))
           (text (prin1-to-string form))
           (count 0)
           (start 0))
      (loop for pos = (search "DISABLE-RAW-MODE!" text :start2 start)
            while pos
            do (incf count)
               (setf start (+ pos (length "DISABLE-RAW-MODE!"))))
      (expect (= 1 count))
      (expect (null (search "HANDLER-BIND" text)))
      (expect (search "UNWIND-PROTECT" text) :to-be-truthy)))

  (it "with-raw-mode-is-a-macro"
    (expect (macro-function 'nerimux/input::with-raw-mode) :to-be-truthy))

  (it "input-symbols-exported-and-fbound"
    (expect (macro-function (find-symbol "WITH-RAW-MODE" '#:nerimux/input)) :to-be-truthy)
    (expect (fboundp (find-symbol "READ-BYTE-NONBLOCK" '#:nerimux/input)) :to-be-truthy)
    (multiple-value-bind (sym status)
        (find-symbol "WITH-RAW-MODE" '#:nerimux/input)
      (declare (ignore sym))
      (expect (eq :external status)))
    (multiple-value-bind (sym status)
        (find-symbol "READ-BYTE-NONBLOCK" '#:nerimux/input)
      (declare (ignore sym))
      (expect (eq :external status))))


  (it "read-byte-nonblock-returns-byte-when-data-available"
    (with-pipe-fds (rfd wfd)
      (write-byte-to-fd wfd 42)
      (let ((ready (nerimux/pty:select-fds (list rfd) 200000)))  ; 200 ms timeout
        (expect ready :to-be-truthy)
        (when ready
          (let ((bytes (read-octets-from-fd rfd 1)))
            (expect (= 1 (length bytes)))
            (expect (= 42 (aref bytes 0))))))))

  (it "read-byte-nonblock-select-returns-nil-when-no-data"
    (with-pipe-fds (rfd _wfd)
      (let ((ready (nerimux/pty:select-fds (list rfd) 10000)))  ; 10 ms
        (expect (null ready)))))

  (it "select-fds-gates-on-positive-select-return"
    (with-pipe-fds (rfd wfd)
      (expect (null (nerimux/pty:select-fds (list rfd) 10000)))
      (write-byte-to-fd wfd 7)
      (expect (equal (list rfd) (nerimux/pty:select-fds (list rfd) 200000)))))


  (it "poll-timeout-us-constant-is-positive"
    (let ((timeout (symbol-value
                    (find-symbol "+POLL-TIMEOUT-US+" '#:nerimux/ports))))
      (expect (integerp timeout))
      (expect (plusp timeout))))

  (it "with-raw-mode-expansion-contains-format-newline"
    (let* ((form (macroexpand-1 '(nerimux/input::with-raw-mode :body-marker)))
           (text (prin1-to-string form)))
      (expect (or (search "FORMAT" text) (search "format" text)) :to-be-truthy)))


  (it "read-byte-nonblock-with-zero-timeout-returns-nil-when-no-data"
    (with-pipe-fds (rfd _wfd)
      (let ((ready (nerimux/pty:select-fds (list rfd) 0)))
        (expect (null ready)))))

  (it "read-byte-nonblock-covers-select-and-read-outcomes"
    (with-function-stubs
        ((nerimux/pty:select-fds (lambda (fds timeout-us)
                                   (declare (ignore fds timeout-us))
                                   nil))
         (cl-tty-kit:fd-read-octets (lambda (fd buffer length)
                                      (declare (ignore fd buffer length))
                                      (error "read must not run"))))
      (expect (null (nerimux/input:read-byte-nonblock 0))))
    (with-function-stubs
        ((nerimux/pty:select-fds (lambda (fds timeout-us)
                                   (declare (ignore timeout-us))
                                   fds))
         (cl-tty-kit:fd-read-octets (lambda (fd buffer length)
                                      (declare (ignore fd))
                                      (setf (aref buffer 0) 65)
                                      length)))
      (expect (= 65 (nerimux/input:read-byte-nonblock 0))))
    (with-function-stubs
        ((nerimux/pty:select-fds (lambda (fds timeout-us)
                                   (declare (ignore timeout-us))
                                   fds))
         (cl-tty-kit:fd-read-octets (lambda (fd buffer length)
                                      (declare (ignore fd buffer length))
                                      0)))
      (expect (null (nerimux/input:read-byte-nonblock 0))))
    (with-function-stubs
        ((nerimux/pty:select-fds (lambda (fds timeout-us)
                                   (declare (ignore timeout-us))
                                   fds))
         (cl-tty-kit:fd-read-octets (lambda (fd buffer length)
                                      (declare (ignore fd buffer length))
                                      (error 'cl-tty-kit:pty-operation-failed))))
      (expect (null (nerimux/input:read-byte-nonblock 0)))))

  (it "read-byte-nonblock-select-returns-ready-list-when-data-present"
    (with-pipe-fds (rfd wfd)
      (write-byte-to-fd wfd 7)
      (let ((ready (nerimux/pty:select-fds (list rfd) 200000)))
        (expect (equal (list rfd) ready)))))

  (it "with-raw-mode-expansion-has-force-output"
    (let* ((form (macroexpand-1 '(nerimux/input::with-raw-mode :body-marker)))
           (text (prin1-to-string form)))
      (expect (or (search "FORCE-OUTPUT" text) (search "force-output" text)) :to-be-truthy))))
