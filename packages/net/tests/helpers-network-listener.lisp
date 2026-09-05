(in-package #:nerimux/test/net)

(defun %test-socket-directory ()
  (let ((tmpdir (sb-ext:posix-getenv "TMPDIR")))
    (string-right-trim "/"
                       (if (and tmpdir
                                (plusp (length tmpdir))
                                (host-kit:directory-exists-p tmpdir))
                           tmpdir
                           "/tmp"))))

(defun %test-socket-path (label)
  "Unique throwaway socket path for LABEL (a descriptive tag embedded in the
   filename), under an existing $TMPDIR (or /tmp when unset or invalid)."
  (let ((dir (%test-socket-directory)))
    (format nil "~A/nerimux-~A-~D.sock" dir label (get-universal-time))))

(defmacro with-test-listener ((listener-var path-var path-form &key backlog)
                              &body
                              body)
  "Bind PATH-VAR to PATH-FORM (e.g. (%test-socket-path \"label\") or an
   explicit (socket-path name)) and LISTENER-VAR to a listener on it for the
   extent of BODY, tearing both down afterwards.  Skips BODY (via cl-weave
   `skip`) when Unix-domain sockets are unavailable — factors out the
   make-listener/unwind-protect/close-socket/delete-file boilerplate shared by
   every multi-client socket-lifecycle test."
  `(if (nerimux/net:unix-socket-available-p)
       (let* ((,path-var ,path-form)
              (_ (ensure-directories-exist ,path-var))
              (,listener-var
               ,(if backlog
                    `(nerimux/net:make-listener ,path-var :backlog ,backlog)
                    `(nerimux/net:make-listener ,path-var))))
         (declare (ignore _))
         (unwind-protect 
             (progn
               ,@body)
           (nerimux/net:close-socket ,listener-var)
           (ignore-errors (delete-file ,path-var))))
       (skip "Unix-domain socket unavailable (sandbox)")))
