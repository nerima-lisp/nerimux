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
        (format t
                "~&DIAG view=~S selected-eq-repo=~S selected-type=~S selected-repo-fn=~S selected-repo-eq=~S~%"
                (nerimux::client-conn-view conn)
                (eq repository (nerimux::client-conn-selected-tree-object conn))
                (type-of (nerimux::client-conn-selected-tree-object conn))
                (type-of (nerimux::%client-selected-repository conn))
                (eq repository (nerimux::%client-selected-repository conn)))
        (finish-output)
        (nerimux::%handle-multi-key-message s conn #(110))
        (format t "~&DIAG mode-after-n=~S~%" (nerimux::client-conn-mode conn))
        (finish-output)
        (expect (eq :command (nerimux::client-conn-mode conn)))
        (expect (string= "wt-create --branch "
                         (nerimux::client-conn-command-buffer conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (eq :overview (nerimux::client-conn-view conn)))
        ;; n reopens the same prompt after cancelling (R6.3 gave Enter on a
        ;; repository row expand/collapse instead — %focus-selected-client-
        ;; worktree — so n is the only key that starts worktree-create now).
        (nerimux::%handle-multi-key-message s conn #(110))
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
               ;; n starts worktree-create; Enter on a repository row now
               ;; expands/collapses it instead (R6.3, %focus-selected-client-
               ;; worktree).
               (nerimux::%handle-multi-key-message s conn #(110))
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

  (it "overview-worktree-delete-dispatches-and-restores-overview"
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
                :branch "feature/doomed"))
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/model:organization-add-repository organization repository)
               (nerimux/model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree &key force on-complete on-error)
                       (declare (ignore on-complete on-error))
                       (setf call (list received-worktree force))
                       t))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%set-client-selected-tree-object conn worktree)
               ;; `X` on a selected worktree pre-fills the command line ...
               (nerimux::%handle-multi-key-message s conn #(88))
               (expect (eq :command (nerimux::client-conn-mode conn)))
               (expect (string= "wt-delete --confirm"
                                (nerimux::client-conn-command-buffer conn)))
               ;; ... and submitting it must actually reach the VCS layer.
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list worktree nil) call))
               (expect (eq :normal (nerimux::client-conn-mode conn)))
               (expect (eq :overview (nerimux::client-conn-view conn)))
               (expect (string= "" (nerimux::client-conn-command-buffer conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

  ;; %client-delete-worktree's own guard (distinct from the `X`-key guard in
  ;; %client-start-worktree-delete): a `:` command submitted without
  ;; --confirm must not reach the VCS layer, even with a worktree selected.
  (it "overview-worktree-delete-without-confirm-is-rejected"
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
                :branch "feature/no-confirm"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/model:organization-add-repository organization repository)
               (nerimux/model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree &key force on-complete on-error)
                       (declare (ignore force on-complete on-error))
                       (setf call received-worktree)
                       t))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-delete" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (string= "worktree delete requires --confirm"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (eq :normal (nerimux::client-conn-mode conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

  ;; The other %client-delete-worktree guard: --confirm with no worktree
  ;; selected must not reach the VCS layer either.
  (it "overview-worktree-delete-without-selection-is-rejected"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree &key force on-complete on-error)
                       (declare (ignore force on-complete on-error))
                       (setf call received-worktree)
                       t))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-delete --confirm"
                 :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               ;; (null call) alone does not discriminate: an unrecognised or
               ;; misspelled command would leave it NIL too.  The message-log
               ;; assertion below is what pins this to the no-selection guard
               ;; rather than to the command never having been reached.
               (expect (null call))
               (expect (string= "worktree delete requires a worktree"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (eq :normal (nerimux::client-conn-mode conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

  ;; `L`/`U` on a selected worktree pre-fill the lock/unlock command lines,
  ;; mirroring `X`'s "wt-delete --confirm" prefill exactly (both already
  ;; include --confirm since no further required argument exists).
  (it "overview-worktree-lock-unlock-open-explicit-command-prompts"
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
        (nerimux::%set-client-selected-tree-object conn worktree)
        (nerimux::%handle-multi-key-message s conn #(76))
        (expect (eq :command (nerimux::client-conn-mode conn)))
        (expect (string= "wt-lock --confirm"
                         (nerimux::client-conn-command-buffer conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (nerimux::%set-client-selected-tree-object conn worktree)
        (nerimux::%handle-multi-key-message s conn #(85))
        (expect (eq :command (nerimux::client-conn-mode conn)))
        (expect (string= "wt-unlock --confirm"
                         (nerimux::client-conn-command-buffer conn))))))

  (it "overview-worktree-lock-dispatches-and-restores-overview"
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
                :branch "feature/lockme"))
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (lock-fn (fdefinition 'nerimux/vcs:lock-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/model:organization-add-repository organization repository)
               (nerimux/model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:lock-worktree-async)
                     (lambda (received-worktree &key reason on-complete on-error)
                       (declare (ignore on-error))
                       (setf call (list received-worktree reason))
                       (funcall on-complete t)
                       t))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(76))
               (expect (string= "wt-lock --confirm"
                                (nerimux::client-conn-command-buffer conn)))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list worktree nil) call))
               (expect (eq :normal (nerimux::client-conn-mode conn)))
               (expect (eq :overview (nerimux::client-conn-view conn)))
               (expect (string= "" (nerimux::client-conn-command-buffer conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:lock-worktree-async) lock-fn)))))

  (it "overview-worktree-unlock-dispatches-and-restores-overview"
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
                :branch "feature/unlockme"))
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (unlock-fn (fdefinition 'nerimux/vcs:unlock-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/model:organization-add-repository organization repository)
               (nerimux/model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:unlock-worktree-async)
                     (lambda (received-worktree &key on-complete on-error)
                       (declare (ignore on-error))
                       (setf call received-worktree)
                       (funcall on-complete t)
                       t))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(85))
               (expect (string= "wt-unlock --confirm"
                                (nerimux::client-conn-command-buffer conn)))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (eq worktree call))
               (expect (eq :normal (nerimux::client-conn-mode conn)))
               (expect (eq :overview (nerimux::client-conn-view conn)))
               (expect (string= "" (nerimux::client-conn-command-buffer conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:unlock-worktree-async) unlock-fn)))))

  ;; A dry-run preview must reach the VCS layer with :dry-run t and must not
  ;; remove anything from the repository's worktree list: the mock below only
  ;; mutates on a real (non-dry-run) call, so an unexpected mutation here
  ;; would mean dry-run stopped being dry.
  (it "overview-worktree-prune-preview-does-not-mutate"
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
                :id "stale"
                :repository repository
                :path "/tmp/stale"
                :branch "feature/stale"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (prune-fn (fdefinition 'nerimux/vcs:prune-worktrees-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/model:organization-add-repository organization repository)
               (nerimux/model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error)
                       (declare (ignore verbose on-error))
                       (setf call (list received-repository dry-run))
                       (unless dry-run
                         (setf (nerimux/model:repository-worktrees
                                received-repository)
                               nil))
                       (funcall on-complete "Would remove /tmp/stale")
                       t))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-prune" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository t) call))
               (expect (equal (list worktree)
                              (nerimux/model:repository-worktrees repository)))
               (expect (string= "worktree prune preview: Would remove /tmp/stale"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (eq :normal (nerimux::client-conn-mode conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  ;; A confirmed prune must reach the VCS layer with :dry-run nil and, unlike
  ;; the preview, is expected to mutate the repository's worktree list. The
  ;; confirm now also requires a preview to have run first for this same
  ;; repository (CLIENT-CONN-PENDING-PRUNE-PREVIEW-REPOSITORY-ID), so this
  ;; drives wt-prune before wt-prune-confirm --confirm to match the legitimate
  ;; flow; see overview-worktree-prune-confirm-without-preview-is-rejected
  ;; below for the case where that preview step is skipped.
  (it "overview-worktree-prune-confirm-mutates"
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
                :id "stale"
                :repository repository
                :path "/tmp/stale"
                :branch "feature/stale"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (prune-fn (fdefinition 'nerimux/vcs:prune-worktrees-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/model:organization-add-repository organization repository)
               (nerimux/model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error)
                       (declare (ignore verbose on-error))
                       (setf call (list received-repository dry-run))
                       (unless dry-run
                         (setf (nerimux/model:repository-worktrees
                                received-repository)
                               nil))
                       (funcall on-complete "")
                       t))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-prune" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository t) call))
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-prune-confirm --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository nil) call))
               (expect (null (nerimux/model:repository-worktrees repository)))
               (expect (string= "worktrees pruned"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (eq :normal (nerimux::client-conn-mode conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  ;; wt-prune-confirm without --confirm must not reach the VCS layer, even
  ;; though the preview path (wt-prune) never requires it. Per the test
  ;; review finding, this now also carries a worktree in the fixture and
  ;; asserts it survives untouched, so a rejected confirm is verified against
  ;; actual repository state rather than only against the mock not firing.
  (it "overview-worktree-prune-confirm-without-confirm-is-rejected"
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
                :id "stale"
                :repository repository
                :path "/tmp/stale"
                :branch "feature/stale"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (prune-fn (fdefinition 'nerimux/vcs:prune-worktrees-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/model:organization-add-repository organization repository)
               (nerimux/model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error)
                       (declare (ignore verbose on-error))
                       (setf call (list received-repository dry-run))
                       (funcall on-complete "")
                       t))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-prune-confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (string= "worktree prune requires --confirm"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (equal (list worktree)
                              (nerimux/model:repository-worktrees repository)))
               (expect (eq :normal (nerimux::client-conn-mode conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  ;; Regression guard for the design-review finding that %CLIENT-PRUNE-WORKTREES
  ;; gated the destructive path only on a textual --confirm token, with no
  ;; record of whether a dry-run preview had actually been shown first. A
  ;; client (or a scripted one) typing wt-prune-confirm --confirm directly,
  ;; skipping wt-prune entirely, must be rejected and must not mutate
  ;; anything -- this would have PASSED straight through to the VCS layer
  ;; against the pre-fix code, since --confirm alone used to be sufficient.
  (it "overview-worktree-prune-confirm-without-preview-is-rejected"
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
                :id "stale"
                :repository repository
                :path "/tmp/stale"
                :branch "feature/stale"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (prune-fn (fdefinition 'nerimux/vcs:prune-worktrees-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/model:organization-add-repository organization repository)
               (nerimux/model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error)
                       (declare (ignore verbose on-error))
                       (setf call (list received-repository dry-run))
                       (unless dry-run
                         (setf (nerimux/model:repository-worktrees
                                received-repository)
                               nil))
                       (funcall on-complete "")
                       t))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%set-client-selected-tree-object conn repository)
               ;; No preceding wt-prune here -- straight to wt-prune-confirm
               ;; --confirm, which is exactly the skip-preview path the
               ;; design review flagged as unsafe.
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-prune-confirm --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect
                (string=
                 "worktree prune requires a preview first: run wt-prune, then wt-prune-confirm --confirm"
                 (first (nerimux::client-conn-message-log conn))))
               (expect (equal (list worktree)
                              (nerimux/model:repository-worktrees repository)))
               (expect (eq :normal (nerimux::client-conn-mode conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

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

  ;; R4/§6 regression note: this used to drive #(27 91 65)/#(27 91 66) — a
  ;; 3-byte arrow escape in one call — to prove picker index navigation. That
  ;; is the exact §2.1 bug shape: client.lisp sends one stdin byte per msg-key
  ;; frame, so a real arrow arrives as ESC, then `[`, then a letter, as three
  ;; SEPARATE calls. The ESC alone already matches the picker's ESC branch,
  ;; which closes the picker and arms R4.3's 2-byte swallow, so the `[` and the
  ;; letter never reach any dispatch. Those four branches were unreachable from
  ;; any real client and are now deleted; C-p/C-n move the selection instead
  ;; (covered by multi-picker-c-p-c-n-move-the-selection below).
  (it "multi-picker-key-input-filters-by-query-and-selects-worktree"
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
        ;; Typed one byte per message, matching client.lisp's real framing.
        (loop for character across "feature"
              do (nerimux::%handle-multi-key-message
                  s conn (vector (char-code character))))
        (expect (string= "feature" (nerimux::client-conn-picker-query conn)))
        (expect (= 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (eq pane (nerimux::client-conn-focus conn))))))

  ;; Direct proof of the finding above: an arrow-escape sequence sent the way
  ;; a real client actually sends it -- one byte per message -- never moves
  ;; the picker's selection index, because the second and third bytes are
  ;; swallowed before %move-client-picker-index is ever reached.
  (it "picker-arrow-key-bytes-one-at-a-time-do-not-move-the-index"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree-a
               (nerimux/model:make-worktree
                :id "a" :repository repository :path "/tmp/a" :branch "a"))
             (worktree-b
               (nerimux/model:make-worktree
                :id "b" :repository repository :path "/tmp/b" :branch "b"))
             (conn (%make-test-conn)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree-a)
        (nerimux/model:repository-add-worktree repository worktree-b)
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (expect (< 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC: closes the picker
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (nerimux::%handle-multi-key-message s conn #(91)) ; [: swallowed
        (nerimux::%handle-multi-key-message s conn #(66)) ; B: swallowed
        (expect (eq :normal (nerimux::client-conn-mode conn))
                ))))

  ;; The replacement for those arrow branches. C-p/C-n are used rather than j/k
  ;; because every other key in the picker is a character of the search query --
  ;; a letter that also moved the cursor could not be typed.
  (it "multi-picker-c-p-c-n-move-the-selection"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree-a
               (nerimux/model:make-worktree
                :id "a" :repository repository :path "/tmp/a" :branch "a"))
             (worktree-b
               (nerimux/model:make-worktree
                :id "b" :repository repository :path "/tmp/b" :branch "b"))
             (conn (%make-test-conn)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree-a)
        (nerimux/model:repository-add-worktree repository worktree-b)
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (expect (< 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(14)) ; C-n
        (expect (= 1 (nerimux::client-conn-picker-index conn)))
        (expect (eq :picker (nerimux::client-conn-mode conn))
                )
        (nerimux::%handle-multi-key-message s conn #(16)) ; C-p
        (expect (= 0 (nerimux::client-conn-picker-index conn)))
        (expect (string= "" (nerimux::client-conn-picker-query conn))
                ))))

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

  ;; A resize updates the resized client's own geometry and immediately
  ;; re-applies the effective shared size, which §1.4 / R8.4 fix to the
  ;; smallest attached client — not the just-resized one.  window-size
  ;; "latest" (and "largest"/"manual") went away with domain/options (R2.2).
  (it "multi-resize-updates-geometry-and-reapplies-smallest-size"
    (with-fake-session (s)
      (let* ((a (%make-test-conn :rows 24 :cols 80))
             (b (%make-test-conn :rows 30 :cols 100))
             (nerimux::*clients* (list a b))
             (payload (nerimux/protocol::u16-octets-pair 50 150)))
        (nerimux::%handle-multi-client-message nerimux::+msg-resize+ payload s b)
        (expect (= 50 (nerimux::client-conn-rows b)))
        (expect (= 150 (nerimux::client-conn-cols b)))
        (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
          (check-table (list (list rows 24 "effective rows = smallest attached client (a), not the resized one")
                             (list cols 80 "effective cols = smallest attached client (a), not the resized one")))))))

  ;; The client-local C-q prefix (%handle-workspace-prefix-key) followed by
  ;; `d` still detaches: :drop on the second key, session survives.  This used
  ;; to be driven through the tmux ^B keytable's own detach binding via the
  ;; now-deleted process-client-keys fallthrough; that path is gone, so the
  ;; coverage is re-expressed through the surviving prefix mechanism, which is
  ;; handled earlier in %handle-multi-key-message than the deleted fallthrough
  ;; ever was.
  (it "multi-handle-key-detach-drops-client"
    (with-fake-session (s)
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
        (expect nerimux::*running* :to-be-truthy))))

  ;; A key the workspace UI does not bind (:normal mode, no stdin-target set)
  ;; is a no-op: NIL disposition, CONN's mode/view unchanged, and -- unlike the
  ;; deleted tmux-keytable fallthrough, which used to write an unprefixed key
  ;; straight into the active pane's pty -- nothing is written to the pane.
  (it "multi-handle-unbound-normal-key-is-noop"
    (with-fake-session (s)
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
        (expect nerimux::*running* :to-be-truthy))))

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
        ;; R4.2: :input mode has no keyboard exit of its own -- ESC is
        ;; forwarded to the pane like any other byte instead of kicking the
        ;; client back to :normal (the §2.1 bug this redesign fixes).
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (eq :input (nerimux::client-conn-mode conn)))
        ;; R4.4: the C-q prefix (C-q C-q) is the only way out of :input.
        (nerimux::%handle-multi-key-message s conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message s conn #(17)) ; C-q again -> :normal
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
