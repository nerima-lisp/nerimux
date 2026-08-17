(in-package #:cl-tmux/test)

;;;; Per-client message dispatch tests for the multi-client server.

(describe "server-multi-suite"

  ;;; ── %handle-multi-client-message: per-client dispatch ────────────────────────

  ;; A resize message updates the client's geometry and re-applies the effective size.
  (it "multi-handle-resize-updates-conn-and-effective-size"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn :rows 24 :cols 80))
             (cl-tmux::*clients* (list conn))
             (payload (cl-tmux/protocol::u16-octets-pair 40 100)))
        (cl-tmux::%handle-multi-client-message cl-tmux::+msg-resize+ payload s conn)
        ;; Single client → effective size equals that client's size.
        (check-table (list (list (cl-tmux::client-conn-rows conn) 40 "conn rows updated from the resize")
                           (list (cl-tmux::client-conn-cols conn) 100 "conn cols updated from the resize")
                           (list cl-tmux::*term-rows* 40 "effective rows applied to *term-rows*")
                           (list cl-tmux::*term-cols* 100 "effective cols applied to *term-cols*"))))))

  (it "multi-render-keeps-client-frame-and-ui-state-independent"
    (with-fake-session (s)
      (let ((wide (%make-test-conn :rows 10 :cols 40))
            (narrow (%make-test-conn :rows 6 :cols 20))
            (renderer (fdefinition 'cl-tmux/renderer:render-session-to-string))
            (calls nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'cl-tmux/renderer:render-session-to-string)
                     (lambda (session rows cols &key focus-pane viewport mode
                                           picker-items picker-query picker-index
                                           picker-regex-p command-buffer)
                       (declare (ignore session))
                       (declare (ignore picker-items picker-query picker-index
                                        picker-regex-p command-buffer))
                       (push (list rows cols focus-pane viewport mode) calls)
                       (make-string (* rows cols) :initial-element #\x)))
               (let ((wide-frame (cl-tmux::%render-client-frame s wide))
                     (narrow-frame (cl-tmux::%render-client-frame s narrow)))
                 (expect (eq wide-frame (cl-tmux::client-conn-frame wide)))
                 (expect (eq narrow-frame (cl-tmux::client-conn-frame narrow)))
                 (expect (/= (length wide-frame) (length narrow-frame)))
                 (setf (cl-tmux::client-conn-focus wide) :wide-pane
                       (cl-tmux::client-conn-viewport wide) 3
                       (cl-tmux::client-conn-mode wide) :copy)
                 (cl-tmux::%render-client-frame s wide)
                 (expect (equal '(10 40 :wide-pane 3 :copy) (first calls)))
                 (expect (eq :wide-pane (cl-tmux::client-conn-focus wide)))
                 (expect (= 3 (cl-tmux::client-conn-viewport wide)))
                 (expect (eq :copy (cl-tmux::client-conn-mode wide)))
                 (expect (null (cl-tmux::client-conn-focus narrow)))
                 (expect (= 0 (cl-tmux::client-conn-viewport narrow)))
                 (expect (eq :normal (cl-tmux::client-conn-mode narrow)))))
          (setf (fdefinition 'cl-tmux/renderer:render-session-to-string) renderer)))))

  (it "multi-client-ui-command-state-is-private"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (eq :normal (cl-tmux::client-conn-mode conn)))
        (expect (cl-tmux::%handle-client-ui-command s conn :mode nil '("copy")))
        (expect (eq :copy (cl-tmux::client-conn-mode conn)))
        (expect (cl-tmux::%handle-client-ui-command s conn :viewport nil '("3")))
        (expect (= 3 (cl-tmux::client-conn-viewport conn)))
        (expect (cl-tmux::%handle-client-ui-command s conn :viewport nil '("-1")))
        (expect (= 2 (cl-tmux::client-conn-viewport conn)))
        (expect (cl-tmux::%handle-client-ui-command s conn :focus nil nil))
        (expect (eq (cl-tmux::window-active-pane (cl-tmux::session-active-window s))
                    (cl-tmux::client-conn-focus conn)))
        (expect (= 0 (cl-tmux::client-conn-viewport conn)))
        (expect (cl-tmux::%handle-client-ui-command s conn :cancel nil nil))
        (expect (eq :normal (cl-tmux::client-conn-mode conn))))))

  (it "overview-shortcut-opens-worktree-picker"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (refresh (fdefinition
                       'cl-tmux/vcs:refresh-workspace-organizations-async))
             (organizations (fdefinition 'cl-tmux/vcs:workspace-organizations)))
        (unwind-protect
             (progn
               (setf (fdefinition 'cl-tmux/vcs:workspace-organizations)
                     (lambda () nil)
                     (fdefinition
                      'cl-tmux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key on-complete on-error)
                       (declare (ignore on-error))
                       (funcall on-complete nil)))
               (setf (cl-tmux::client-conn-view conn) :overview)
               (cl-tmux::%handle-multi-key-message s conn #(16))
               (expect (eq :picker (cl-tmux::client-conn-mode conn)))
               (expect (string= ""
                                (cl-tmux::client-conn-picker-query conn))))
          (setf (fdefinition 'cl-tmux/vcs:refresh-workspace-organizations-async)
                refresh
                (fdefinition 'cl-tmux/vcs:workspace-organizations)
                organizations)))))

  (it "overview-worktree-actions-open-explicit-command-prompts"
    (with-fake-session (s)
      (let* ((organization
               (cl-tmux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (cl-tmux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (cl-tmux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/ux"))
             (conn (%make-test-conn)))
        (cl-tmux/model:organization-add-repository organization repository)
        (cl-tmux/model:repository-add-worktree repository worktree)
        (setf (cl-tmux::client-conn-view conn) :overview)
        (cl-tmux::%set-client-selected-tree-object conn repository)
        (cl-tmux::%handle-multi-key-message s conn #(110))
        (expect (eq :command (cl-tmux::client-conn-mode conn)))
        (expect (string= "wt-create --branch "
                         (cl-tmux::client-conn-command-buffer conn)))
        (cl-tmux::%handle-multi-key-message s conn #(27))
        (expect (eq :normal (cl-tmux::client-conn-mode conn)))
        (expect (eq :overview (cl-tmux::client-conn-view conn)))
        (cl-tmux::%handle-multi-key-message s conn #(13))
        (expect (eq :command (cl-tmux::client-conn-mode conn)))
        (expect (string= "wt-create --branch "
                         (cl-tmux::client-conn-command-buffer conn)))
        (cl-tmux::%handle-multi-key-message s conn #(27))
        (cl-tmux::%set-client-selected-tree-object conn worktree)
        (cl-tmux::%handle-multi-key-message s conn #(88))
        (expect (eq :command (cl-tmux::client-conn-mode conn)))
        (expect (string= "wt-delete --confirm"
                         (cl-tmux::client-conn-command-buffer conn))))))

  (it "overview-worktree-create-dispatches-and-restores-overview"
    (with-fake-session (s)
      (let* ((organization
               (cl-tmux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (cl-tmux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (conn (%make-test-conn))
             (available (fdefinition 'cl-tmux/vcs:vcs-package-available-p))
             (create (fdefinition 'cl-tmux/vcs:create-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (cl-tmux/model:organization-add-repository organization repository)
               (setf (fdefinition 'cl-tmux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'cl-tmux/vcs:create-worktree-async)
                     (lambda (received-repository
                              &key branch path path-template new-branch-p force
                                on-complete on-error)
                       (declare (ignore path path-template force on-complete on-error))
                       (setf call (list received-repository branch new-branch-p))
                       t))
               (setf (cl-tmux::client-conn-view conn) :overview)
               (cl-tmux::%set-client-selected-tree-object conn repository)
               (cl-tmux::%handle-multi-key-message s conn #(13))
               (cl-tmux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "feature/new --confirm"
                 :encoding :utf-8))
               (cl-tmux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository "feature/new" t) call))
               (expect (eq :normal (cl-tmux::client-conn-mode conn)))
               (expect (eq :overview (cl-tmux::client-conn-view conn)))
               (expect (string= "" (cl-tmux::client-conn-command-buffer conn))))
          (setf (fdefinition 'cl-tmux/vcs:vcs-package-available-p) available
                (fdefinition 'cl-tmux/vcs:create-worktree-async) create)))))

  (it "multi-picker-regex-toggle-is-client-local"
    (with-fake-session (s)
      (let* ((organization
               (cl-tmux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (cl-tmux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (cl-tmux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/picker"))
             (conn (%make-test-conn)))
        (cl-tmux/model:organization-add-repository organization repository)
        (cl-tmux/model:repository-add-worktree repository worktree)
        (setf (cl-tmux::client-conn-mode conn) :picker
              (cl-tmux::client-conn-picker-items conn)
              (cl-tmux/picker:build-global-picker-items
               (list organization))
              (cl-tmux::client-conn-picker-query conn) "feature/.+")
        (expect (null (cl-tmux::client-conn-picker-regex-p conn)))
        (expect (null (cl-tmux::%client-picker-visible-items conn)))
        (cl-tmux::%handle-multi-key-message s conn #(18))
        (expect (cl-tmux::client-conn-picker-regex-p conn))
        (expect (= 1 (length (cl-tmux::%client-picker-visible-items conn))))
        (expect (cl-tmux::%handle-client-ui-command
                 s conn :picker-regex "off" nil))
        (expect (null (cl-tmux::client-conn-picker-regex-p conn)))
        (expect (null (cl-tmux::%client-picker-visible-items conn))))))

  (it "multi-picker-key-input-filters-navigates-and-selects-worktree"
    (with-fake-session (s)
      (let* ((organization
               (cl-tmux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (cl-tmux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (cl-tmux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/picker"))
             (conn (%make-test-conn))
             (pane (cl-tmux/model:window-active-pane
                    (cl-tmux/model:session-active-window s))))
        (cl-tmux/model:organization-add-repository organization repository)
        (cl-tmux/model:repository-add-worktree repository worktree)
        (cl-tmux/model:worktree-add-pane worktree pane)
        (setf (cl-tmux::client-conn-mode conn) :picker
              (cl-tmux::client-conn-picker-items conn)
              (cl-tmux/picker:build-global-picker-items
               (list organization))
              (cl-tmux::client-conn-picker-index conn) 0)
        (cl-tmux::%handle-multi-key-message s conn #(27 91 66))
        (expect (= 1 (cl-tmux::client-conn-picker-index conn)))
        (cl-tmux::%handle-multi-key-message s conn #(27 91 65))
        (expect (= 0 (cl-tmux::client-conn-picker-index conn)))
        (cl-tmux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "feature" :encoding :utf-8))
        (expect (string= "feature" (cl-tmux::client-conn-picker-query conn)))
        (expect (= 1 (length (cl-tmux::%client-picker-visible-items conn))))
        (cl-tmux::%handle-multi-key-message s conn #(13))
        (expect (eq :normal (cl-tmux::client-conn-mode conn)))
        (expect (eq pane (cl-tmux::client-conn-focus conn))))))

  (it "multi-picker-selects-a-worktree-pane-in-an-inactive-window"
    (with-fake-session (s :nwindows 2)
      (let* ((organization
               (cl-tmux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (cl-tmux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (cl-tmux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/inactive"))
             (conn (%make-test-conn))
             (inactive-window (second (cl-tmux/model:session-windows s)))
             (pane (cl-tmux/model:window-active-pane inactive-window)))
        (cl-tmux/model:organization-add-repository organization repository)
        (cl-tmux/model:repository-add-worktree repository worktree)
        (cl-tmux/model:worktree-add-pane worktree pane)
        (setf (cl-tmux::client-conn-mode conn) :picker
              (cl-tmux::client-conn-picker-items conn)
              (cl-tmux/picker:build-global-picker-items
               (list organization))
              (cl-tmux::client-conn-picker-query conn) "feature")
        (expect (cl-tmux::%select-client-picker-item s conn))
        (expect (eq inactive-window
                    (cl-tmux/model:session-active-window s)))
        (expect (eq pane (cl-tmux::client-conn-focus conn)))
        (expect (eq :normal (cl-tmux::client-conn-mode conn))))))

  (it "multi-picker-new-window-uses-client-geometry"
    (with-fake-session (s)
      (let* ((organization
               (cl-tmux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (cl-tmux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (cl-tmux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/new"))
             (conn (%make-test-conn :rows 17 :cols 63))
             (captured-geometry nil)
             (original-new-window (fdefinition 'cl-tmux::%cmd-new-window)))
        (cl-tmux/model:organization-add-repository organization repository)
        (cl-tmux/model:repository-add-worktree repository worktree)
        (setf (cl-tmux::client-conn-mode conn) :picker
              (cl-tmux::client-conn-picker-items conn)
              (cl-tmux/picker:build-global-picker-items
               (list organization))
              (cl-tmux::client-conn-picker-query conn) "feature")
        (unwind-protect
             (progn
               (setf (fdefinition 'cl-tmux::%cmd-new-window)
                     (lambda (session &rest args)
                       (declare (ignore args))
                       (setf captured-geometry
                             (list cl-tmux::*term-rows* cl-tmux::*term-cols*))
                       (cl-tmux/model:session-active-window session)))
               (expect (cl-tmux::%select-client-picker-item s conn))
               (expect (equal '(17 63) captured-geometry)))
          (setf (fdefinition 'cl-tmux::%cmd-new-window)
                original-new-window)))))

  (it "multi-client-command-vocabulary-normalizes-to-tmux"
    (check-table
     (list
      (list (multiple-value-list
             (cl-tmux::%canonical-client-command :close "%.0" nil))
            '(:kill-pane "%.0" nil)
            "close becomes kill-pane")
      (list (multiple-value-list
             (cl-tmux::%canonical-client-command :restart nil '("echo")))
            '(:respawn-pane nil ("-k" "echo"))
            "restart forces respawn-pane -k")
      (list (multiple-value-list
             (cl-tmux::%canonical-client-command :split nil '("horizontal")))
            '(:split-window nil ("-h"))
            "horizontal split uses split-window -h")
      (list (multiple-value-list
             (cl-tmux::%canonical-client-command :resize nil '("left" "7")))
            '(:resize-pane nil ("-L" "7"))
            "left resize uses resize-pane -L")
      (list (multiple-value-list
             (cl-tmux::%canonical-client-command :rename nil '("work")))
            '(:rename-window nil ("work"))
            "rename becomes rename-window")
      (list (multiple-value-list
             (cl-tmux::%canonical-client-command :move nil '("down")))
            '(:select-pane nil ("-D"))
            "move becomes select-pane")
      (list (multiple-value-list
             (cl-tmux::%canonical-client-command :swap nil '("right")))
            '(:swap-pane nil ("-R"))
            "swap becomes swap-pane")
      (list (multiple-value-list
             (cl-tmux::%canonical-client-command :layout nil '("even-horizontal")))
            '(:select-layout nil ("even-horizontal"))
            "layout becomes select-layout"))
     :test #'equal))

  ;; A resize moves the client to the front of *clients* so window-size "latest"
  ;; tracks the just-resized client.
  (it "multi-resize-marks-client-latest"
    (with-fresh-options
      (cl-tmux/options:set-option "window-size" "latest")
      (with-fake-session (s)
        (let* ((a (%make-test-conn :rows 24 :cols 80))
               (b (%make-test-conn :rows 30 :cols 100))
               (cl-tmux::*clients* (list a b))   ; a is front initially
               (payload (cl-tmux/protocol::u16-octets-pair 50 150)))
          (cl-tmux::%handle-multi-client-message cl-tmux::+msg-resize+ payload s b)
          (expect (eq b (first cl-tmux::*clients*)))
          (multiple-value-bind (rows cols) (cl-tmux::%effective-client-size)
            (check-table (list (list rows 50 "latest tracks the just-resized client's new rows")
                               (list cols 150 "latest tracks the just-resized client's new cols"))))))))

  ;; A ^B d key message yields :drop (the client detaches; the session survives).
  (it "multi-handle-key-detach-drops-client"
    (with-fake-session (s)
      (with-isolated-config
        (let ((conn    (%make-test-conn))
              (payload (make-array 2 :element-type '(unsigned-byte 8)
                                     :initial-contents (list 2 (char-code #\d)))))
          (expect (eq :drop (cl-tmux::%handle-multi-client-message
                             cl-tmux::+msg-key+ payload s conn)))
          (expect cl-tmux::*running* :to-be-truthy)))))

  ;; A +msg-attach+ frame whose flags byte sets +attach-flag-read-only+ marks the
  ;; connection read-only; a plain (no-flag) attach leaves it NIL.
  (it "multi-attach-readonly-flag-sets-conn-slot"
    (with-fake-session (s)
      (let* ((conn   (%make-test-conn))
             (cl-tmux::*clients* (list conn))
             (ro-payload (cl-tmux/protocol::to-octets
                          (concatenate 'list
                                       (cl-tmux/protocol::u16-octets-pair 30 100)
                                       (list cl-tmux/protocol:+attach-flag-read-only+)))))
        (cl-tmux::%handle-multi-client-message cl-tmux::+msg-attach+ ro-payload s conn)
        (expect (cl-tmux::client-conn-read-only-p conn) :to-be-truthy)
        ;; A subsequent plain attach (no flags byte) clears it again.
        (cl-tmux::%handle-multi-client-message
         cl-tmux::+msg-attach+ (cl-tmux/protocol::u16-octets-pair 30 100) s conn)
        (expect (cl-tmux::client-conn-read-only-p conn) :to-be-falsy))))

  ;; When a connection is read-only, a printable key dispatched through
  ;; %handle-multi-client-message must NOT reach the active pane (no pty-write).
  (it "multi-readonly-conn-suppresses-pane-input"
    (with-fake-session (s)
      (with-isolated-config
        (let* ((conn (%make-test-conn))
               (cl-tmux::*clients* (list conn))
               (writes nil))
          (setf (cl-tmux::client-conn-read-only-p conn) t)
          ;; Capture any pty-write the key would otherwise forward to the pane.
          (flet ((rec (fd bytes) (declare (ignore fd)) (push bytes writes)))
            (let ((orig (fdefinition 'cl-tmux::pty-write)))
              (unwind-protect
                   (progn
                     (setf (fdefinition 'cl-tmux::pty-write) #'rec)
                     (cl-tmux::%handle-multi-client-message
                      cl-tmux::+msg-key+
                      (make-array 1 :element-type '(unsigned-byte 8)
                                    :initial-contents (list (char-code #\a)))
                      s conn))
                (setf (fdefinition 'cl-tmux::pty-write) orig))))
          (expect (null writes))))))

  ;; An explicit +msg-detach+ message yields :drop.
  (it "multi-handle-detach-message-drops-client"
    (with-fake-session (s)
      (expect (eq :drop (cl-tmux::%handle-multi-client-message
                         cl-tmux::+msg-detach+ #() s (%make-test-conn))))))

  ;; EOF (NIL type) and an unknown message type both yield :drop.
  (it "multi-handle-nil-and-unknown-type-drop"
    (with-fake-session (s)
      (expect (eq :drop (cl-tmux::%handle-multi-client-message nil #() s (%make-test-conn))))
      (expect (eq :drop (cl-tmux::%handle-multi-client-message 99 #() s (%make-test-conn))))))

  ;; A detach-other-clients command message yields :detach-others.
  (it "multi-handle-detach-other-clients-command"
    (with-fake-session (s)
      (let ((payload (cl-tmux/protocol::encode-command-payload :detach-other-clients)))
        (expect (eq :detach-others (cl-tmux::%handle-multi-client-message
                                    cl-tmux::+msg-command+ payload s (%make-test-conn)))))))

  (it "multi-client-ui-keymaps-drive-input-copy-search-and-command"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (cl-tmux::window-active-pane
                    (cl-tmux::session-active-window s)))
             (screen (cl-tmux/model:pane-screen pane))
             (cl-tmux::*clients* (list conn)))
        (setf (cl-tmux::client-conn-focus conn) pane)
        (cl-tmux/model:pane-feed
         pane
         (cl-codec-kit:string-to-octets "needle" :encoding :utf-8))
        (cl-tmux::%handle-multi-key-message s conn #(105))
        (expect (eq :input (cl-tmux::client-conn-mode conn)))
        (cl-tmux::%handle-multi-key-message s conn #(27))
        (expect (eq :normal (cl-tmux::client-conn-mode conn)))
        (cl-tmux::%handle-multi-key-message s conn #(99))
        (expect (eq :copy (cl-tmux::client-conn-mode conn)))
        (expect (cl-tmux/terminal:screen-copy-mode-p screen))
        (cl-tmux::%handle-multi-key-message s conn #(47))
        (expect (eq :command (cl-tmux::client-conn-mode conn)))
        (expect (string= "search-forward "
                         (cl-tmux::client-conn-command-buffer conn)))
        (cl-tmux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "needle" :encoding :utf-8))
        (cl-tmux::%handle-multi-key-message s conn #(13))
        (expect (eq :copy (cl-tmux::client-conn-mode conn)))
        (cl-tmux::%handle-multi-key-message s conn #(113))
        (expect (eq :normal (cl-tmux::client-conn-mode conn)))
        (expect (cl-tmux/terminal:screen-copy-mode-p screen) :to-be-falsy)
        (cl-tmux::%handle-multi-key-message s conn #(58))
        (cl-tmux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "overview" :encoding :utf-8))
        (cl-tmux::%handle-multi-key-message s conn #(13))
        (expect (eq :overview (cl-tmux::client-conn-view conn)))
        (expect (eq :normal (cl-tmux::client-conn-mode conn)))))))
