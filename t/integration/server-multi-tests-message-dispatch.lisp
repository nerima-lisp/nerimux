(in-package #:nerimux/test)

;;;; Per-client message dispatch tests for the multi-client server.

(describe "server-multi-suite"

  (it "main-thread-callback-queue-preserves-order"
    (let ((events nil)
          (nerimux::*main-thread-callbacks* nil))
      (nerimux::%enqueue-main-thread-callback
       (lambda () (setf events (nconc events (list :first)))))
      (nerimux::%enqueue-main-thread-callback
       (lambda () (setf events (nconc events (list :second)))))
      (nerimux::%drain-main-thread-callbacks)
      (expect (equal '(:first :second) events))))

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
                     (lambda (&key on-complete on-error callback-dispatch)
                       (declare (ignore on-error callback-dispatch))
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
        ;; ESC arms R4.3's 2-byte swallow window (%client-esc-swallow-start),
        ;; so the next two bytes after it never reach dispatch -- two no-op
        ;; presses clear it before n reopens the same prompt (R6.3 gave Enter
        ;; on a repository row expand/collapse instead —
        ;; %focus-selected-client-worktree — so n is the only key that starts
        ;; worktree-create now).
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message s conn #(110))
        (expect (eq :command (nerimux::client-conn-mode conn)))
        (expect (string= "wt-create --branch "
                         (nerimux::client-conn-command-buffer conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (nerimux::%set-client-selected-tree-object conn worktree)
        ;; Same R4.3 swallow window as above.
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message s conn #(0))
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
                              &key branch path force on-complete on-error
                                callback-dispatch)
                       (declare (ignore path force on-complete on-error
                                       callback-dispatch))
                       (setf call (list received-repository branch))
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
               (expect (equal (list repository "feature/new") call))
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
                     (lambda (received-worktree
                              &key force on-complete on-error callback-dispatch)
                       (declare (ignore on-complete on-error callback-dispatch))
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
                     (lambda (received-worktree
                              &key force on-complete on-error callback-dispatch)
                       (declare (ignore force on-complete on-error
                                       callback-dispatch))
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
                     (lambda (received-worktree
                              &key force on-complete on-error callback-dispatch)
                       (declare (ignore force on-complete on-error
                                       callback-dispatch))
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
        ;; ESC arms R4.3's 2-byte swallow window (%client-esc-swallow-start);
        ;; two no-op presses clear it before U reaches dispatch.
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message s conn #(0))
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
                     (lambda (received-worktree
                              &key reason on-complete on-error callback-dispatch)
                       (declare (ignore on-error callback-dispatch))
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
                     (lambda (received-worktree
                              &key on-complete on-error callback-dispatch)
                       (declare (ignore on-error callback-dispatch))
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
                              &key dry-run verbose on-complete on-error
                                callback-dispatch)
                       (declare (ignore verbose on-error callback-dispatch))
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
                              &key dry-run verbose on-complete on-error
                                callback-dispatch)
                       (declare (ignore verbose on-error callback-dispatch))
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
)
