(in-package #:nerimux/test)

(describe "server-dispatch-helper-search-suite"
  (it "search-submit-reports-invalid-input-and-restores-view"
    (let* ((session (nerimux/session:make-session :id 1 :name "test"))
           (conn (nerimux::%make-client-conn))
           (messages nil))
      (setf (nerimux::client-conn-command-return-view conn) :status
            (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-modal conn :command)
      (with-stubbed-fdefinition
          ((nerimux::%resolve-client-focus-pane
             (lambda (&rest arguments) (declare (ignore arguments)) nil))
           (nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message messages))))
        (nerimux::%submit-client-search session conn :forward '("needle"))
        (nerimux::%submit-client-search session conn :backward nil))
      (expect (equal '("no focused pane" "no focused pane") messages))
      (expect (eq :status (nerimux::client-conn-view conn)))
      (expect (null (nerimux::client-conn-command-return-view conn)))
      (expect (null (nerimux::client-conn-modal conn)))))

  (it "search-submit-reports-empty-terms-before-searching"
    (let* ((session (nerimux/session:make-session :id 1 :name "test"))
           (conn (nerimux::%make-client-conn))
           (pane (make-no-pty-pane 1 0 0 4 4))
           (messages nil)
           (searches 0))
      (nerimux::%set-client-view conn :status)
      (nerimux::%set-client-modal conn :command)
      (with-stubbed-fdefinition
          ((nerimux::%resolve-client-focus-pane
             (lambda (&rest arguments) (declare (ignore arguments)) pane))
           (nerimux::copy-mode-search-forward
             (lambda (&rest arguments) (declare (ignore arguments))
               (incf searches)))
           (nerimux::%client-notify
             (lambda (connection message)
               (declare (ignore connection))
               (push message messages))))
        (nerimux::%submit-client-search session conn :forward '("  ")))
      (expect (equal '("search term is empty") messages))
      (expect (= 0 searches))
      (expect (eq :status (nerimux::client-conn-view conn)))
      (expect (null (nerimux::client-conn-modal conn)))))

  (it "search-submit-dispatches-both-directions"
    (let* ((session (nerimux/session:make-session :id 1 :name "test"))
           (conn (nerimux::%make-client-conn))
           (pane (make-no-pty-pane 1 0 0 4 4))
           (directions nil))
      (nerimux::%set-client-view conn :status)
      (nerimux::%set-client-modal conn :command)
      (with-stubbed-fdefinition
          ((nerimux::%resolve-client-focus-pane
             (lambda (&rest arguments) (declare (ignore arguments)) pane))
           (nerimux::copy-mode-search-forward
             (lambda (&rest arguments) (declare (ignore arguments))
               (push :forward directions)))
           (nerimux::copy-mode-search-backward
             (lambda (&rest arguments) (declare (ignore arguments))
               (push :backward directions))))
        (nerimux::%submit-client-search session conn :forward '("needle"))
        (nerimux::%set-client-modal conn :command)
        (nerimux::%submit-client-search session conn :backward '("needle")))
      (expect (equal '(:backward :forward) directions))
      (expect (eq :status (nerimux::client-conn-view conn)))
      (expect (null (nerimux::client-conn-modal conn))))))
