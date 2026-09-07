(in-package #:nerimux/test)

(describe "server-multi-rendering-suite"

  (it "multi-handle-resize-updates-conn-and-effective-size"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn :rows 24 :cols 80))
             (nerimux::*clients* (list conn))
             (payload (nerimux/protocol::u16-octets-pair 40 100)))
        (nerimux::%handle-multi-client-message nerimux::+msg-resize+ payload s conn)
        (check-table (list (list (nerimux::client-conn-rows conn) 40 "conn rows updated from the resize")
                           (list (nerimux::client-conn-cols conn) 100 "conn cols updated from the resize")
                           (list nerimux::*term-rows* 40 "effective rows applied to *term-rows*")
                           (list nerimux::*term-cols* 100 "effective cols applied to *term-cols*"))))))

  (it "multi-render-keeps-client-frame-and-ui-state-independent"
    (with-fake-session (s)
      (let ((wide (%make-test-conn :rows 10 :cols 40))
            (narrow (%make-test-conn :rows 6 :cols 20))
            (renderer (fdefinition 'nerimux/renderer:render-session-to-string))
            (calls nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/renderer:render-session-to-string)
                     (lambda (session rows cols &key focus-pane viewport mode
                                           picker-items picker-query picker-index
                                           picker-regex-p command-buffer)
                       (declare (ignore session))
                       (declare (ignore picker-items picker-query picker-index
                                        picker-regex-p command-buffer))
                       (push (list rows cols focus-pane viewport mode) calls)
                       (make-string (* rows cols) :initial-element #\x)))
               (setf (nerimux::client-conn-view wide) :pane
                     (nerimux::client-conn-view narrow) :pane)
               (let ((wide-frame (nerimux::%render-client-frame s wide))
                     (narrow-frame (nerimux::%render-client-frame s narrow)))
                 (expect (eq wide-frame (nerimux::client-conn-frame wide)))
                 (expect (eq narrow-frame (nerimux::client-conn-frame narrow)))
                 (expect (/= (length wide-frame) (length narrow-frame)))
                 (setf (nerimux::client-conn-focus wide) :wide-pane
                       (nerimux::client-conn-viewport wide) 3
                       (nerimux::client-conn-modal wide) :scrollback)
                 (nerimux::%render-client-frame s wide)
                 (expect (equal '(10 40 :wide-pane 3 :scrollback) (first calls)))
                 (expect (eq :wide-pane (nerimux::client-conn-focus wide)))
                 (expect (= 3 (nerimux::client-conn-viewport wide)))
                 (expect (eq :scrollback (nerimux::client-conn-modal wide)))
                 (expect (null (nerimux::client-conn-focus narrow)))
                 (expect (= 0 (nerimux::client-conn-viewport narrow)))
                 (expect (null (nerimux::client-conn-modal narrow)))))
          (setf (fdefinition 'nerimux/renderer:render-session-to-string) renderer))))))
