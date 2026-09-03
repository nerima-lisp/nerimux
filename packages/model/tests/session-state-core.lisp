(in-package #:nerimux/test/model)

(describe "model-suite"


  (it "session-active-pane"
    (let* ((sess (make-fake-session :nwindows 1 :npanes 1))
           (win  (session-active-window sess))
           (pane (window-active-pane win)))
      (expect (eq pane (session-active-pane sess)))))


  (it "shell-basename-table"
    (dolist (entry
             '(("/bin/bash"  "bash" "%shell-basename strips /bin/ prefix")
               ("zsh"        "zsh"  "%shell-basename returns bare name when no slash")
               (nil          "sh"   "%shell-basename falls back to /bin/sh's basename when $SHELL is unset")
               ("/usr/bin/"  ""     "%shell-basename returns empty string for trailing-slash path")))
      (destructuring-bind (shell expected desc) entry
        (declare (ignore desc))
        (with-temporary-posix-environment-variable ("SHELL" shell)
          (expect (string= expected (nerimux/session::%shell-basename)))))))

  (it "shell-basename-trailing-slash-is-string"
    (with-temporary-posix-environment-variable ("SHELL" "/usr/bin/")
      (expect (stringp (nerimux/session::%shell-basename)))))


  (it "session-insert-window-sorts-by-id"
    (let* ((w0   (make-window :id 0 :name "a"))
           (w2   (make-window :id 2 :name "c"))
           (w1   (make-window :id 1 :name "b"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w2))))
      (session-insert-window sess w1)
      (expect (equal (list w0 w1 w2) (session-windows sess)))))

  (it "session-insert-window-does-not-change-active"
    (let* ((w0   (make-window :id 0 :name "a"))
           (w1   (make-window :id 1 :name "b"))
           (sess (make-session :id 1 :name "s" :windows (list w0))))
      (session-select-window sess w0)
      (session-insert-window sess w1)
      (expect (eq w0 (session-active-window sess)))))


  (it "session-touch-updates-last-active"
    (let ((sess (make-session :id 42 :name "t" :last-active 0)))
      (let ((before (get-universal-time)))
        (let ((result (session-touch sess)))
          (expect (eq sess result))
          (expect (>= (session-last-active sess) before))))))


  (it "all-panes-returns-flat-list-of-panes"
    (let* ((p0   (make-no-pty-pane 1 0 0 20 5))
           (p1   (make-no-pty-pane 2 0 0 20 5))
           (w0   (make-window :id 0 :name "w0" :panes (list p0)))
           (w1   (make-window :id 1 :name "w1" :panes (list p1)))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (let ((panes (all-panes sess)))
        (expect (= 2 (length panes)))
        (expect (member p0 panes) :to-be-truthy)
        (expect (member p1 panes) :to-be-truthy))))

  (it "all-panes-empty-session"
    (let ((sess (make-session :id 1 :name "s" :windows nil)))
      (expect (null (all-panes sess)))))


  (it "session-id-slot-accessible"
    (let ((sess (make-session :id 99 :name "test")))
      (expect (= 99 (session-id sess)))))


  (it "session-name-slot-accessible"
    (let ((sess (make-session :id 1 :name "my-session")))
      (expect (string= "my-session" (session-name sess)))))


  (it "session-clients-defaults-nil"
    (let ((sess (make-session :id 1 :name "c")))
      (expect (null (session-clients sess)))))


  (it "next-window-id-fills-lowest-gap"
    (let* ((w0   (make-window :id 0 :name "a"))
           (w2   (make-window :id 2 :name "c"))
           (sess (make-session :id 1 :name "s" :windows (list w0 w2))))
      (expect (= 1 (nerimux/session::%next-window-id sess 0))))))
