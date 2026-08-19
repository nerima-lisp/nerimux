(in-package #:nerimux/test)

;;;; Per-client message dispatch tests for the multi-client server.

(describe "server-multi-suite"

  ;;; ── %handle-multi-client-message: per-client dispatch ────────────────────────

  ;; A resize message updates the client's geometry and re-applies the effective size.
  (it "multi-handle-resize-updates-conn-and-effective-size"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn :rows 24 :cols 80))
             (nerimux::*clients* (list conn))
             (payload (nerimux/protocol::u16-octets-pair 40 100)))
        (nerimux::%handle-multi-client-message nerimux::+msg-resize+ payload s conn)
        ;; Single client → effective size equals that client's size.
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
               (let ((wide-frame (nerimux::%render-client-frame s wide))
                     (narrow-frame (nerimux::%render-client-frame s narrow)))
                 (expect (eq wide-frame (nerimux::client-conn-frame wide)))
                 (expect (eq narrow-frame (nerimux::client-conn-frame narrow)))
                 (expect (/= (length wide-frame) (length narrow-frame)))
                 (setf (nerimux::client-conn-focus wide) :wide-pane
                       (nerimux::client-conn-viewport wide) 3
                       (nerimux::client-conn-mode wide) :copy)
                 (nerimux::%render-client-frame s wide)
                 (expect (equal '(10 40 :wide-pane 3 :copy) (first calls)))
                 (expect (eq :wide-pane (nerimux::client-conn-focus wide)))
                 (expect (= 3 (nerimux::client-conn-viewport wide)))
                 (expect (eq :copy (nerimux::client-conn-mode wide)))
                 (expect (null (nerimux::client-conn-focus narrow)))
                 (expect (= 0 (nerimux::client-conn-viewport narrow)))
                 (expect (eq :normal (nerimux::client-conn-mode narrow)))))
          (setf (fdefinition 'nerimux/renderer:render-session-to-string) renderer)))))

  (it "multi-client-ui-command-state-is-private"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (nerimux::%handle-client-ui-command s conn :mode nil '("copy")))
        (expect (eq :copy (nerimux::client-conn-mode conn)))
        (expect (nerimux::%handle-client-ui-command s conn :viewport nil '("3")))
        (expect (= 3 (nerimux::client-conn-viewport conn)))
        (expect (nerimux::%handle-client-ui-command s conn :viewport nil '("-1")))
        (expect (= 2 (nerimux::client-conn-viewport conn)))
        (expect (nerimux::%handle-client-ui-command s conn :focus nil nil))
        (expect (eq (nerimux::window-active-pane (nerimux::session-active-window s))
                    (nerimux::client-conn-focus conn)))
        (expect (= 0 (nerimux::client-conn-viewport conn)))
        (expect (nerimux::%handle-client-ui-command s conn :cancel nil nil))
        (expect (eq :normal (nerimux::client-conn-mode conn))))))

  (it "overview-shortcut-opens-worktree-picker"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (refresh (fdefinition
                       'nerimux/vcs:refresh-workspace-organizations-async))
             (organizations (fdefinition 'nerimux/vcs:workspace-organizations)))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:workspace-organizations)
                     (lambda () nil)
                     (fdefinition
                      'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key on-complete on-error)
                       (declare (ignore on-error))
                       (funcall on-complete nil)))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%handle-multi-key-message s conn #(16))
               (expect (eq :picker (nerimux::client-conn-mode conn)))
               (expect (string= ""
                                (nerimux::client-conn-picker-query conn))))
          (setf (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh
                (fdefinition 'nerimux/vcs:workspace-organizations)
                organizations)))))

  (it "overview-worktree-actions-open-explicit-command-prompts"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/ux"))
             (conn (%make-test-conn)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :overview)
        (nerimux::%set-client-selected-tree-object conn repository)
        (nerimux::%handle-multi-key-message s conn #(110))
        (expect (eq :command (nerimux::client-conn-mode conn)))
        (expect (string= "wt-create --branch "
                         (nerimux::client-conn-command-buffer conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (eq :overview (nerimux::client-conn-view conn)))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (eq :command (nerimux::client-conn-mode conn)))
        (expect (string= "wt-create --branch "
                         (nerimux::client-conn-command-buffer conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (nerimux::%set-client-selected-tree-object conn worktree)
        (nerimux::%handle-multi-key-message s conn #(88))
        (expect (eq :command (nerimux::client-conn-mode conn)))
        (expect (string= "wt-delete --confirm"
                         (nerimux::client-conn-command-buffer conn))))))

  (it "overview-worktree-create-dispatches-and-restores-overview"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (create (fdefinition 'nerimux/vcs:create-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/model:organization-add-repository organization repository)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:create-worktree-async)
                     (lambda (received-repository
                              &key branch path path-template new-branch-p force
                                on-complete on-error)
                       (declare (ignore path path-template force on-complete on-error))
                       (setf call (list received-repository branch new-branch-p))
                       t))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(13))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "feature/new --confirm"
                 :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository "feature/new" t) call))
               (expect (eq :normal (nerimux::client-conn-mode conn)))
               (expect (eq :overview (nerimux::client-conn-view conn)))
               (expect (string= "" (nerimux::client-conn-command-buffer conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "multi-picker-regex-toggle-is-client-local"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/picker"))
             (conn (%make-test-conn)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-query conn) "feature/.+")
        (expect (null (nerimux::client-conn-picker-regex-p conn)))
        (expect (null (nerimux::%client-picker-visible-items conn)))
        (nerimux::%handle-multi-key-message s conn #(18))
        (expect (nerimux::client-conn-picker-regex-p conn))
        (expect (= 1 (length (nerimux::%client-picker-visible-items conn))))
        (expect (nerimux::%handle-client-ui-command
                 s conn :picker-regex "off" nil))
        (expect (null (nerimux::client-conn-picker-regex-p conn)))
        (expect (null (nerimux::%client-picker-visible-items conn))))))

  (it "multi-picker-key-input-filters-navigates-and-selects-worktree"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/picker"))
             (conn (%make-test-conn))
             (pane (nerimux/model:window-active-pane
                    (nerimux/model:session-active-window s))))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (nerimux/model:worktree-add-pane worktree pane)
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (nerimux::%handle-multi-key-message s conn #(27 91 66))
        (expect (= 1 (nerimux::client-conn-picker-index conn)))
        (nerimux::%handle-multi-key-message s conn #(27 91 65))
        (expect (= 0 (nerimux::client-conn-picker-index conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "feature" :encoding :utf-8))
        (expect (string= "feature" (nerimux::client-conn-picker-query conn)))
        (expect (= 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (eq pane (nerimux::client-conn-focus conn))))))

  (it "multi-picker-selects-a-worktree-pane-in-an-inactive-window"
    (with-fake-session (s :nwindows 2)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/inactive"))
             (conn (%make-test-conn))
             (inactive-window (second (nerimux/model:session-windows s)))
             (pane (nerimux/model:window-active-pane inactive-window)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (nerimux/model:worktree-add-pane worktree pane)
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-query conn) "feature")
        (expect (nerimux::%select-client-picker-item s conn))
        (expect (eq inactive-window
                    (nerimux/model:session-active-window s)))
        (expect (eq pane (nerimux::client-conn-focus conn)))
        (expect (eq :normal (nerimux::client-conn-mode conn))))))

  (it "multi-picker-new-window-uses-client-geometry"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/new"))
             (conn (%make-test-conn :rows 17 :cols 63))
             (captured-geometry nil)
             (original-new-window (fdefinition 'nerimux::%workspace-new-window)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-query conn) "feature")
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux::%workspace-new-window)
                     (lambda (session &rest args)
                       (declare (ignore args))
                       (setf captured-geometry
                             (list nerimux::*term-rows* nerimux::*term-cols*))
                       (nerimux/model:session-active-window session)))
               (expect (nerimux::%select-client-picker-item s conn))
               (expect (equal '(17 63) captured-geometry)))
          (setf (fdefinition 'nerimux::%workspace-new-window)
                original-new-window)))))

  ;; The workspace->tmux command vocabulary translation
  ;; (%canonical-client-command: :close -> :kill-pane, :split -> :split-window,
  ;; and so on) was deleted with the tmux command table it fed.  Its only
  ;; consumer was %dispatch-forwarded-command; once that went, the translation
  ;; had nothing to translate for, and this test was the only thing still
  ;; calling it.

  ;; A resize moves the client to the front of *clients* so window-size "latest"
  ;; tracks the just-resized client.
  (it "multi-resize-marks-client-latest"
    (with-fresh-options
      (nerimux/options:set-option "window-size" "latest")
      (with-fake-session (s)
        (let* ((a (%make-test-conn :rows 24 :cols 80))
               (b (%make-test-conn :rows 30 :cols 100))
               (nerimux::*clients* (list a b))   ; a is front initially
               (payload (nerimux/protocol::u16-octets-pair 50 150)))
          (nerimux::%handle-multi-client-message nerimux::+msg-resize+ payload s b)
          (expect (eq b (first nerimux::*clients*)))
          (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
            (check-table (list (list rows 50 "latest tracks the just-resized client's new rows")
                               (list cols 150 "latest tracks the just-resized client's new cols"))))))))

  ;; The client-local C-q prefix (%handle-workspace-prefix-key) followed by
  ;; `d` still detaches: :drop on the second key, session survives.  This used
  ;; to be driven through the tmux ^B keytable's own detach binding via the
  ;; now-deleted process-client-keys fallthrough; that path is gone, so the
  ;; coverage is re-expressed through the surviving prefix mechanism, which is
  ;; handled earlier in %handle-multi-key-message than the deleted fallthrough
  ;; ever was.
  (it "multi-handle-key-detach-drops-client"
    (with-fake-session (s)
      (with-isolated-config
        (let* ((conn   (%make-test-conn))
               (prefix (make-array 1 :element-type '(unsigned-byte 8)
                                      :initial-contents
                                      (list (nerimux::client-conn-workspace-prefix-code conn))))
               (d-key  (make-array 1 :element-type '(unsigned-byte 8)
                                      :initial-contents (list (char-code #\d)))))
          ;; The prefix byte alone is absorbed: no disposition yet, but the
          ;; client is now armed for the following `d`.
          (expect (null (nerimux::%handle-multi-client-message
                         nerimux::+msg-key+ prefix s conn)))
          (expect (nerimux::client-conn-ui-prefix-p conn))
          (expect (eq :drop (nerimux::%handle-multi-client-message
                             nerimux::+msg-key+ d-key s conn)))
          (expect nerimux::*running* :to-be-truthy)))))

  ;; A key the workspace UI does not bind (:normal mode, no stdin-target set)
  ;; is a no-op: NIL disposition, CONN's mode/view unchanged, and -- unlike the
  ;; deleted tmux-keytable fallthrough, which used to write an unprefixed key
  ;; straight into the active pane's pty -- nothing is written to the pane.
  (it "multi-handle-unbound-normal-key-is-noop"
    (with-fake-session (s)
      (with-isolated-config
        (let* ((conn (%make-test-conn))
               (before-mode (nerimux::client-conn-mode conn))
               (before-view (nerimux::client-conn-view conn))
               (key (make-array 1 :element-type '(unsigned-byte 8)
                                   :initial-contents (list (char-code #\z))))
               (writes nil))
          (flet ((rec (fd bytes) (declare (ignore fd)) (push bytes writes)))
            (let ((orig (fdefinition 'nerimux::pty-write)))
              (unwind-protect
                   (progn
                     (setf (fdefinition 'nerimux::pty-write) #'rec)
                     (expect (null (nerimux::%handle-multi-client-message
                                    nerimux::+msg-key+ key s conn))))
                (setf (fdefinition 'nerimux::pty-write) orig))))
          (expect (null writes))
          (expect (eq before-mode (nerimux::client-conn-mode conn)))
          (expect (eq before-view (nerimux::client-conn-view conn)))
          (expect nerimux::*running* :to-be-truthy)))))

  ;; A +msg-attach+ frame whose flags byte sets +attach-flag-read-only+ marks the
  ;; connection read-only; a plain (no-flag) attach leaves it NIL.
  (it "multi-attach-readonly-flag-sets-conn-slot"
    (with-fake-session (s)
      (let* ((conn   (%make-test-conn))
             (nerimux::*clients* (list conn))
             (ro-payload (nerimux/protocol::to-octets
                          (concatenate 'list
                                       (nerimux/protocol::u16-octets-pair 30 100)
                                       (list nerimux/protocol:+attach-flag-read-only+)))))
        (nerimux::%handle-multi-client-message nerimux::+msg-attach+ ro-payload s conn)
        (expect (nerimux::client-conn-read-only-p conn) :to-be-truthy)
        ;; A subsequent plain attach (no flags byte) clears it again.
        (nerimux::%handle-multi-client-message
         nerimux::+msg-attach+ (nerimux/protocol::u16-octets-pair 30 100) s conn)
        (expect (nerimux::client-conn-read-only-p conn) :to-be-falsy))))

  ;; When a connection is read-only, a printable key dispatched through
  ;; %handle-multi-client-message must NOT reach the active pane (no pty-write).
  (it "multi-readonly-conn-suppresses-pane-input"
    (with-fake-session (s)
      (with-isolated-config
        (let* ((conn (%make-test-conn))
               (nerimux::*clients* (list conn))
               (writes nil))
          (setf (nerimux::client-conn-read-only-p conn) t)
          ;; Capture any pty-write the key would otherwise forward to the pane.
          (flet ((rec (fd bytes) (declare (ignore fd)) (push bytes writes)))
            (let ((orig (fdefinition 'nerimux::pty-write)))
              (unwind-protect
                   (progn
                     (setf (fdefinition 'nerimux::pty-write) #'rec)
                     (nerimux::%handle-multi-client-message
                      nerimux::+msg-key+
                      (make-array 1 :element-type '(unsigned-byte 8)
                                    :initial-contents (list (char-code #\a)))
                      s conn))
                (setf (fdefinition 'nerimux::pty-write) orig))))
          (expect (null writes))))))

  ;; An explicit +msg-detach+ message yields :drop.
  (it "multi-handle-detach-message-drops-client"
    (with-fake-session (s)
      (expect (eq :drop (nerimux::%handle-multi-client-message
                         nerimux::+msg-detach+ #() s (%make-test-conn))))))

  ;; EOF (NIL type) and an unknown message type both yield :drop.
  (it "multi-handle-nil-and-unknown-type-drop"
    (with-fake-session (s)
      (expect (eq :drop (nerimux::%handle-multi-client-message nil #() s (%make-test-conn))))
      (expect (eq :drop (nerimux::%handle-multi-client-message 99 #() s (%make-test-conn))))))

  ;; A detach-other-clients command message yields :detach-others.
  (it "multi-handle-detach-other-clients-command"
    (with-fake-session (s)
      (let ((payload (nerimux/protocol::encode-command-payload :detach-other-clients)))
        (expect (eq :detach-others (nerimux::%handle-multi-client-message
                                    nerimux::+msg-command+ payload s (%make-test-conn)))))))

  (it "multi-client-ui-keymaps-drive-input-copy-search-and-command"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux::window-active-pane
                    (nerimux::session-active-window s)))
             (screen (nerimux/model:pane-screen pane))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-focus conn) pane)
        (nerimux/model:pane-feed
         pane
         (cl-codec-kit:string-to-octets "needle" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(105))
        (expect (eq :input (nerimux::client-conn-mode conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (nerimux::%handle-multi-key-message s conn #(99))
        (expect (eq :copy (nerimux::client-conn-mode conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen))
        (nerimux::%handle-multi-key-message s conn #(47))
        (expect (eq :command (nerimux::client-conn-mode conn)))
        (expect (string= "search-forward "
                         (nerimux::client-conn-command-buffer conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "needle" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (eq :copy (nerimux::client-conn-mode conn)))
        (nerimux::%handle-multi-key-message s conn #(113))
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen) :to-be-falsy)
        (nerimux::%handle-multi-key-message s conn #(58))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "overview" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (eq :overview (nerimux::client-conn-view conn)))
        (expect (eq :normal (nerimux::client-conn-mode conn)))))))
