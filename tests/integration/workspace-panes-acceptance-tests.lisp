(in-package #:nerimux/test)

(defmacro %with-r5-fixture ((session-var conn-var worktree-var window-var) &body body)
  "Stub %fork-pane and start-reader-thread, bind PTY resize and close ports to
   no-ops,
   build one organization/repository/worktree, open the worktree's first pane
   via the real overview-Enter production path
   (%focus-selected-client-worktree), and bind SESSION-VAR/CONN-VAR/
   WORKTREE-VAR/WINDOW-VAR for BODY."
  `(with-loop-state
     (let ((nerimux/ports:*resize-pty* (lambda (fd rows cols)
                                         (declare (ignore fd rows cols))
                                         nil))
           (nerimux/ports:*close-pty* (lambda (fd pid)
                                        (declare (ignore fd pid))
                                        nil)))
       (with-stubbed-fdefinition
           ((nerimux/pane::%fork-pane
             (lambda (session id x y cols rows &key start-dir default-command)
               (declare (ignore session default-command))
               (let ((pane (make-no-pty-pane id x y cols rows)))
                 (setf (nerimux/pane:pane-fd pane) 9999
                       (nerimux/pane:pane-start-path pane) (or start-dir ""))
                 pane)))
            (nerimux::start-reader-thread
             (lambda (pane) (declare (ignore pane)) nil)))
       (let* ((organization
                (nerimux/workspace-model:make-organization
                 :id "org" :host "github.com" :name "team"))
              (repository
                (nerimux/workspace-model:make-repository
                 :id "repo" :organization organization
                 :specification "github.com/team/repo"))
              (,worktree-var
                (nerimux/workspace-model:make-worktree
                 :id "wt" :repository repository
                 :path "/tmp/nerimux-r5-wt" :branch "feat/phase3"))
              (,session-var (nerimux/session:make-session :id 1 :name "0" :windows nil))
              (,conn-var (%make-test-conn :rows 200 :cols 200))
              (nerimux::*clients* (list ,conn-var)))
         (nerimux/workspace-model:organization-add-repository organization repository)
         (nerimux/workspace-model:repository-add-worktree repository ,worktree-var)
         (setf (nerimux::client-conn-view ,conn-var) :repolist)
         (nerimux::%set-client-selected-tree-object ,conn-var ,worktree-var)
         (nerimux::%handle-multi-key-message ,session-var ,conn-var #(13)) ; Enter
         (let ((,window-var (nerimux/session:session-active-window ,session-var)))
           ,@body))))))

(describe "workspace-panes-acceptance-suite"

  (it "r5-1-split-that-does-not-fit-notifies-and-changes-nothing"
    (with-loop-state
      (multiple-value-bind (session window pane)
          (make-single-pane-session :width 3 :height 2)
        (let* ((worktree
                 (nerimux/workspace-model:make-worktree :id "wt" :path "/tmp/wt" :branch "feat/tiny"))
               (conn (%make-test-conn))
               (nerimux::*clients* (list conn)))
          (nerimux/pane:worktree-add-pane worktree pane)
          (nerimux::%set-client-focus conn pane)
          (nerimux::%handle-multi-key-message session conn #(17)) ; C-q
          (nerimux::%handle-multi-key-message session conn #(45)) ; -
          (expect (= 1 (length (nerimux/window:window-panes window))))
          (expect (= 1 (length (nerimux/workspace-model:worktree-panes worktree))))
          (expect (string= "pane too small to split"
                           (first (nerimux::client-conn-message-log conn))))))))

  (it "r5-acceptance-split-focus-cap-new-window-move-close-to-empty"
    (%with-r5-fixture (session conn worktree window-1)
      (expect (= 1 (length (nerimux/window:window-panes window-1))))
      (expect (= 1 (length (nerimux/workspace-model:worktree-panes worktree))))

      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(45)) ; -
      (expect (= 2 (length (nerimux/window:window-panes window-1))))
      (expect (= 2 (length (nerimux/workspace-model:worktree-panes worktree))))
      (expect (string= "/tmp/nerimux-r5-wt"
                       (nerimux/pane:pane-start-path
                        (nerimux/window:window-active-pane window-1))))

      (let ((before (nerimux::client-conn-focus conn)))
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(107)) ; k
        (expect (not (eq before (nerimux::client-conn-focus conn)))))

      (dotimes (_ 2)
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(45)))
      (expect (= 4 (length (nerimux/window:window-panes window-1))))

      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(45))
      (expect (= 4 (length (nerimux/window:window-panes window-1)))
              )
      (expect (= 2 (length (nerimux::%worktree-windows worktree)))
              )
      (let ((window-2 (nerimux/session:session-active-window session)))
        (expect (not (eq window-1 window-2)))
        (expect (= 1 (length (nerimux/window:window-panes window-2))))
        (expect (= 5 (length (nerimux/workspace-model:worktree-panes worktree))))
        (expect (string= "feat/phase3 (2)" (nerimux/window:window-name window-2)))

        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(112)) ; p
        (expect (eq window-1 (nerimux/session:session-active-window session)))

        (dotimes (_ 3)
          (nerimux::%handle-multi-key-message session conn #(17))
          (nerimux::%handle-multi-key-message session conn #(120))) ; x
        (expect (= 1 (length (nerimux/window:window-panes window-1))))
        (expect (member window-1 (nerimux/session:session-windows session)))

        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(120))
        (expect (not (member window-1 (nerimux/session:session-windows session))))
        (expect (not (member window-1 (nerimux::%worktree-windows worktree))))
        (expect (eq window-2 (nerimux/session:session-active-window session))
                )
        (expect (eq (nerimux/window:window-active-pane window-2)
                    (nerimux::client-conn-focus conn)))

        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(120))
        (expect (null (nerimux/workspace-model:worktree-panes worktree)))
        (expect (null (nerimux/session:session-windows session)))
        (expect (eq :repolist (nerimux::client-conn-view conn))))))

  (it "r5-6-zoom-auto-unzoom-so-the-4-pane-cap-is-checked-on-the-real-count"
    (%with-r5-fixture (session conn worktree window)
      (dotimes (_ 3)
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(45)))
      (expect (= 4 (length (nerimux/window:window-panes window))))

      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(122)) ; z
      (expect (nerimux/window:window-zoom-p window))
      (expect (= 1 (length (nerimux/window:window-panes window)))
              )

      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(45)) ; -
      (expect (not (nerimux/window:window-zoom-p window)) )
      (expect (= 4 (length (nerimux/window:window-panes window)))
              )
      (expect (= 2 (length (nerimux::%worktree-windows worktree)))
              )))

  (it "r5-7-worktree-pane-startup-failure-is-recorded-as-durable-state"
    (with-loop-state
      (with-stubbed-fdefinition
          ((nerimux/pane::%fork-pane
            (lambda (session id x y cols rows &key start-dir default-command)
              (declare (ignore session start-dir default-command))
              (make-no-pty-pane id x y cols rows)))) ; fd stays -1: not live
        (let* ((organization
                 (nerimux/workspace-model:make-organization
                  :id "org" :host "github.com" :name "team"))
               (repository
                 (nerimux/workspace-model:make-repository
                  :id "repo" :organization organization
                  :specification "github.com/team/repo"))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "wt" :repository repository
                  :path "/tmp/nerimux-r5-7-wt" :branch "feat/broken"))
               (session (nerimux/session:make-session :id 1 :name "0" :windows nil))
               (conn (%make-test-conn))
               (nerimux::*clients* (list conn)))
          (nerimux/workspace-model:organization-add-repository organization repository)
          (nerimux/workspace-model:repository-add-worktree repository worktree)
          (setf (nerimux::client-conn-view conn) :repolist)
          (nerimux::%set-client-selected-tree-object conn worktree)
          (nerimux::%handle-multi-key-message session conn #(13))
          (let ((pane (nerimux/window:window-active-pane
                       (nerimux/session:session-active-window session))))
            (expect (nerimux/pane:pane-startup-failed-p pane))
            (expect (not (nerimux/pane:pane-live-p pane)))
            (expect (member pane (nerimux/workspace-model:worktree-panes worktree)))
            (expect (eq pane (nerimux::client-conn-focus conn)))
            (expect (string= "worktree pane failed to start"
                             (first (nerimux::client-conn-message-log conn))))))))))
