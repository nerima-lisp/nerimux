(in-package #:nerimux/test)

(describe "confirm-view-quit-suite"

  (it "r8-2-c-q-shift-q-shows-confirm-with-live-pane-count-and-swallows-other-keys"
    (with-fake-session (s :nwindows 1 :npanes 2)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (win (first (nerimux/session:session-windows s)))
             (panes (nerimux/window:window-panes win)))
        (setf (nerimux/pane:pane-fd (first panes)) 9999)
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(81))
        (let ((view (nerimux::client-conn-confirm-view conn)))
          (expect view)
          (expect (string= "Quit server" (nerimux/renderer:confirm-view-operation view)))
          (expect (search "1 open"
                          (cdr (assoc "panes" (nerimux/renderer:confirm-view-fields view)
                                      :test #'string=)))
                  :to-be-truthy))
        (nerimux::%handle-multi-key-message s conn #(106))
        (expect (nerimux::client-conn-confirm-view conn)
                )
        (nerimux::%handle-multi-key-message s conn #(110))
        (expect (null (nerimux::client-conn-confirm-view conn)))
        (expect (string= "cancelled" (first (nerimux::client-conn-message-log conn))))
        (expect nerimux::*running* :to-be-truthy))))

  (it "cancels the server-quit confirmation on escape, q and the prefix escape"
    (with-fake-session (s :nwindows 1 :npanes 2)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn)))
        (dolist (cancel (list #(27) "q" :prefix))
          (nerimux::%handle-multi-key-message s conn #(17))
          (nerimux::%handle-multi-key-message s conn #(81))
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (if (eq cancel :prefix)
              (progn
                (nerimux::%handle-multi-key-message s conn #(17))
                (nerimux::%handle-multi-key-message s conn #(17)))
              (nerimux::%handle-multi-key-message s conn cancel))
          (expect (null (nerimux::client-conn-confirm-view conn)))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (string= "cancelled"
                           (first (nerimux::client-conn-message-log conn))))
          (expect nerimux::*running* :to-be-truthy)))))

  (it "names the keys that answer a confirmation on the prompt line only"
    (let* ((conn (%make-test-conn))
           (nerimux::*clients* (list conn)))
      (nerimux::%open-confirm-view conn
                                   "git reset --hard HEAD"
                                   (list (cons "repository" "github.com/acme/alpha"))
                                   (lambda () nil))
      (let ((view (nerimux::client-conn-confirm-view conn)))
        (expect (equal '(("repository" . "github.com/acme/alpha"))
                       (nerimux/renderer:confirm-view-fields view)))
        (expect (string= "y execute   n/q/Esc cancel"
                         (nerimux/renderer::%confirm-view-prompt-line view))))))

  (it "lists the files a git clean confirmation would remove"
    (expect (string= "untracked.txt build/"
                     (nerimux::%confirm-clean-preview-text
                      (format nil "Would remove untracked.txt~%Would remove build/~%"))))
    (expect (string= "nothing" (nerimux::%confirm-clean-preview-text "")))
    (expect (nerimux::%confirm-clean-preview-p "git clean -fd"))
    (expect (null (nerimux::%confirm-clean-preview-p "git reset --hard HEAD"))))

  (it "r8-2-server-quit-route-cleans-up-client-host-modes"
    (with-fake-session (s :nwindows 1 :npanes 1)
      (let ((output
              (with-connected-client-host-output
                  ((let* ((conn (nerimux::%make-client-conn
                                  :socket server-sock
                                  :stream server-stream
                                  :fd (socket-fd server-sock)))
                         (nerimux::*clients* (list conn))
                         (nerimux::*running* t))
                     (with-stubbed-fdefinition
                         ((nerimux/net:close-socket
                           (lambda (&rest args)
                             (declare (ignore args))
                             nil))
                          (nerimux::%multi-serve-iteration
                           (lambda (listener session)
                             (declare (ignore listener session))
                             (nerimux::%handle-multi-key-message s conn #(17))
                             (nerimux::%handle-multi-key-message s conn #(81))
                             (expect
                              (eq :quit
                                  (nerimux::%handle-multi-key-message
                                   s conn #(121))))
                             :quit)))
                       (expect (null (nerimux::%run-multi-server-loop
                                      :listener s)))
                       (expect (null nerimux::*clients*)))))
                (nerimux::run-client "7"))))
        (expect (string= (%expected-client-host-output) output))
        (expect (search (%host-mode-sequence nil) output)))))

  (it "r8-3-detaching-the-last-client-leaves-running-true-and-panes-untouched"
    (with-fake-session (s :nwindows 1 :npanes 1)
      (let* ((conn (%make-test-conn))
             (pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s)))
             (nerimux::*clients* (list conn)))
        (setf (nerimux/pane:pane-fd pane) 9999)
        (expect (eq :drop (nerimux::%handle-multi-client-message
                           nerimux::+msg-detach+ #() s conn)))
        (expect nerimux::*running* :to-be-truthy)
        (expect (nerimux/pane:pane-live-p pane))))))
