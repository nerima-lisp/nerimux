(in-package #:nerimux/test)

;;;; Per-client message dispatch tests for the multi-client server.

(defun %wt-auto-branch-name-p (branch)
  "T when BRANCH matches wt-YYYYMMDDTHHMMSS -- the auto-generated branch
   name format %CLIENT-WORKTREE-CREATE-BRANCH-NAME produces for `n` (PR2,
   R6.3 pivot). Written without a regex dependency: a hand rolled character-
   class check over the fixed-width format is just as precise here."
  (and (stringp branch)
       (= (length branch) 18)
       (string= "wt-" branch :end2 3)
       (every #'digit-char-p (subseq branch 3 11))
       (char= #\T (char branch 11))
       (every #'digit-char-p (subseq branch 12 18))))

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

  ;; PR2 (R6.3 pivot, user decision): `n` no longer pre-fills the `:` command
  ;; line -- it creates a worktree immediately, with an auto-generated
  ;; wt-<YYYYMMDDTHHMMSS> branch name, for the selected repository, with a
  ;; single keystroke as its own confirmation (%CLIENT-START-WORKTREE-CREATE
  ;; / %CLIENT-CREATE-WORKTREE-NOW). CREATE-WORKTREE-ASYNC is stubbed so no
  ;; real git process runs; the stub only captures its arguments. `X` on a
  ;; selected worktree is untouched by this redesign and still pre-fills
  ;; "wt-delete --confirm" -- asserted here as a regression check that `n`'s
  ;; rewrite did not disturb the neighbouring X handler.
  (it "overview-worktree-create-key-creates-immediately-and-worktree-delete-key-still-prompts"
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
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (create (fdefinition 'nerimux/vcs:create-worktree-async))
             (call nil))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (unwind-protect
             (progn
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
               (nerimux::%handle-multi-key-message s conn #(110))
               (expect (eq repository (first call)))
               (expect (%wt-auto-branch-name-p (second call)))
               ;; No intermediate `:` prompt: the mode never leaves :normal.
               (expect (eq :normal (nerimux::client-conn-mode conn)))
               (expect (eq :overview (nerimux::client-conn-view conn)))
               ;; X is unaffected by the `n` redesign: it still pre-fills the
               ;; `:` command line rather than acting immediately.
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(88))
               (expect (eq :command (nerimux::client-conn-mode conn)))
               (expect (string= "wt-delete --confirm"
                                (nerimux::client-conn-command-buffer conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  ;; %CLIENT-SELECTED-REPOSITORY derives the owning repository from a
  ;; selected WORKTREE row too (not only from a selected repository row), so
  ;; this drives `n` from a worktree selection to pin that resolution stays
  ;; wired into the new immediate-create path.
  (it "overview-worktree-create-key-resolves-repository-from-a-selected-worktree"
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
                :branch "feature/existing"))
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (create (fdefinition 'nerimux/vcs:create-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/model:organization-add-repository organization repository)
               (nerimux/model:repository-add-worktree repository worktree)
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
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(110))
               (expect (eq repository (first call)))
               (expect (%wt-auto-branch-name-p (second call)))
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

  ;; PR2 `/` tree-filter mode (item 6, R6.3 pivot): entering it must NOT force
  ;; the view to :detail the way :input/:copy/:command do (%SET-CLIENT-UI-
  ;; MODE only special-cases those three) -- the whole point of `/` is to
  ;; keep navigating the :overview tree while narrowing it. Typing and
  ;; backspacing both reset tree-scroll (a narrower/wider query can leave a
  ;; stale scroll offset past the end of the new filtered set). Esc clears
  ;; the query and drops back to :normal; Enter keeps it.
  (it "overview-tree-filter-key-enters-filter-mode-without-forcing-detail-view"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :overview)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :tree-filter (nerimux::client-conn-mode conn)))
        (expect (eq :overview (nerimux::client-conn-view conn)))
        (setf (nerimux::client-conn-tree-scroll conn) 7)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "ab" :encoding :utf-8))
        (expect (string= "ab" (nerimux::client-conn-tree-filter conn)))
        (expect (zerop (nerimux::client-conn-tree-scroll conn)))
        (setf (nerimux::client-conn-tree-scroll conn) 3)
        (nerimux::%handle-multi-key-message s conn #(8))
        (expect (string= "a" (nerimux::client-conn-tree-filter conn)))
        (expect (zerop (nerimux::client-conn-tree-scroll conn)))
        ;; Esc cancels: clears the query and returns to :normal, still in
        ;; :overview.
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (eq :overview (nerimux::client-conn-view conn)))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        ;; Esc arms R4.3's 2-byte swallow window; two no-op presses clear it
        ;; before `/` reopens tree-filter mode (same pattern the X/L/U tests
        ;; above use).
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "xyz" :encoding :utf-8))
        ;; Enter accepts: the query survives the return to :normal.
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (eq :overview (nerimux::client-conn-view conn)))
        (expect (string= "xyz" (nerimux::client-conn-tree-filter conn))))))

  ;; Review-round fix: `/` always starts from an EMPTY query, even when a
  ;; previous filter session ended with Enter (:accept) and left CONN's
  ;; tree-filter set for the /query footer chip -- without the reset in
  ;; %CLIENT-ENTER-TREE-FILTER-MODE, the next `/` silently prepended new
  ;; keystrokes onto the old accepted query instead of starting fresh (vim's
  ;; `/` semantics).
  (it "overview-tree-filter-key-starts-empty-again-after-a-previous-accept"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :overview)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "abc" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (string= "abc" (nerimux::client-conn-tree-filter conn)))
        ;; Re-entering `/` (Enter's :accept path arms no ESC-swallow window,
        ;; unlike ESC's :cancel -- so no dummy presses are needed here).
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :tree-filter (nerimux::client-conn-mode conn)))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "z" :encoding :utf-8))
        ;; "z", never "abcz" -- the old accepted query must not leak in.
        (expect (string= "z" (nerimux::client-conn-tree-filter conn))))))

  ;; :tree-filter mode absorbs every printable key into the query buffer --
  ;; "j"/"k" are ordinary characters there, never the :overview navigation
  ;; keys, so the selection must not move.
  (it "overview-tree-filter-mode-absorbs-jk-as-query-text-not-navigation"
    (let* ((organization
             (nerimux/model:make-organization
              :id "org-jk-absorb" :host "github.com" :name "team"))
           (repository
             (nerimux/model:make-repository
              :id "repo-jk-absorb" :organization organization
              :specification "github.com/team/repo-jk-absorb"))
           (conn (%make-test-conn))
           (nerimux/vcs::*workspace-organizations* (list organization)))
      (nerimux/model:organization-add-repository organization repository)
      (setf (nerimux::client-conn-view conn) :overview)
      (nerimux::%set-client-selected-tree-object conn repository)
      (nerimux::%set-client-ui-mode conn :tree-filter)
      (nerimux::%handle-client-tree-filter-key-payload
       nil conn (cl-codec-kit:string-to-octets "jk" :encoding :utf-8))
      (expect (string= "jk" (nerimux::client-conn-tree-filter conn)))
      (expect (eq repository (nerimux::client-conn-selected-tree-object conn)))))

  ;; `n` with no repository resolvable from the current selection (nothing
  ;; selected, or an organization row selected -- %CLIENT-SELECTED-REPOSITORY
  ;; only derives a repository from a repository/worktree selection, or from
  ;; an organization with EXACTLY one repository) notifies instead of
  ;; creating anything, and the mode stays :normal (no worktree-create ever
  ;; starts).
  (it "overview-worktree-create-key-with-no-repository-selected-notifies"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (create (fdefinition 'nerimux/vcs:create-worktree-async))
            (called nil)
            ;; %CLIENT-NOTIFY only appends to the message log for a live
            ;; (registered) client -- see %CLIENT-LIVE-P.
            (nerimux::*clients* nil))
        (setf nerimux::*clients* (list conn))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:create-worktree-async)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (setf called t)))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%handle-multi-key-message s conn #(110))
               (expect (null called))
               (expect (string= "select a repository first"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (eq :normal (nerimux::client-conn-mode conn))))
          (setf (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  ;; Same guard, but with an ORGANIZATION holding two repositories selected --
  ;; %CLIENT-SELECTED-REPOSITORY's organization branch only resolves when
  ;; there is exactly one repository, so this must notify too, not guess.
  (it "overview-worktree-create-key-with-an-ambiguous-organization-selected-notifies"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org-ambiguous" :host "github.com" :name "team"))
             (repo-a
               (nerimux/model:make-repository
                :id "repo-ambiguous-a" :organization organization
                :specification "github.com/team/repo-a"))
             (repo-b
               (nerimux/model:make-repository
                :id "repo-ambiguous-b" :organization organization
                :specification "github.com/team/repo-b"))
             (conn (%make-test-conn))
             (create (fdefinition 'nerimux/vcs:create-worktree-async))
             (called nil)
             ;; %CLIENT-NOTIFY only appends to the message log for a live
             ;; (registered) client -- see %CLIENT-LIVE-P.
             (nerimux::*clients* (list conn)))
        (nerimux/model:organization-add-repository organization repo-a)
        (nerimux/model:organization-add-repository organization repo-b)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:create-worktree-async)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (setf called t)))
               (setf (nerimux::client-conn-view conn) :overview)
               (nerimux::%set-client-selected-tree-object conn organization)
               (nerimux::%handle-multi-key-message s conn #(110))
               (expect (null called))
               (expect (string= "select a repository first"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (eq :normal (nerimux::client-conn-mode conn))))
          (setf (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  ;; :tree-top/:tree-bottom must walk the FILTERED row set (review-round fix:
  ;; both now call %WORKSPACE-TREE-OBJECTS with CLIENT-CONN-TREE-FILTER),
  ;; not the whole unfiltered catalog. 3 organizations, only the MIDDLE one
  ;; matching the filter: unfiltered, :tree-top would land on org-none-1 (the
  ;; first row) and :tree-bottom on worktree-none-3 (the last row) -- with
  ;; the filter active, both must instead land on the filtered set's own
  ;; first/last row (org-match itself, and its one matching worktree),
  ;; proving the command genuinely reads the filtered set rather than
  ;; coincidentally landing on the same answer either way.
  (it "tree-top-and-tree-bottom-commands-use-the-filtered-row-set"
    (with-fake-session (s)
      (let* ((org-none-1
               (nerimux/model:make-organization
                :id "org-top-bottom-none-1" :host "github.com" :name "none-1"))
             (org-match
               (nerimux/model:make-organization
                :id "org-top-bottom-match" :host "github.com" :name "match"))
             (org-none-3
               (nerimux/model:make-organization
                :id "org-top-bottom-none-3" :host "github.com" :name "none-3"))
             (repo-none-1
               (nerimux/model:make-repository
                :id "repo-top-bottom-none-1" :organization org-none-1
                :specification "github.com/none-1/repo"))
             (repo-match
               (nerimux/model:make-repository
                :id "repo-top-bottom-match" :organization org-match
                :specification "github.com/match/repo"))
             (repo-none-3
               (nerimux/model:make-repository
                :id "repo-top-bottom-none-3" :organization org-none-3
                :specification "github.com/none-3/repo"))
             (worktree-none-1
               (nerimux/model:make-worktree
                :id "wt-top-bottom-none-1" :repository repo-none-1
                :path "/tmp/top-bottom-none-1" :branch "no-match-here-1"))
             (worktree-match
               (nerimux/model:make-worktree
                :id "wt-top-bottom-match" :repository repo-match
                :path "/tmp/top-bottom-match" :branch "only-match"))
             (worktree-none-3
               (nerimux/model:make-worktree
                :id "wt-top-bottom-none-3" :repository repo-none-3
                :path "/tmp/top-bottom-none-3" :branch "no-match-here-3"))
             (conn (%make-test-conn))
             (nerimux/vcs::*workspace-organizations*
               (list org-none-1 org-match org-none-3)))
        (nerimux/model:organization-add-repository org-none-1 repo-none-1)
        (nerimux/model:organization-add-repository org-match repo-match)
        (nerimux/model:organization-add-repository org-none-3 repo-none-3)
        (nerimux/model:repository-add-worktree repo-none-1 worktree-none-1)
        (nerimux/model:repository-add-worktree repo-match worktree-match)
        (nerimux/model:repository-add-worktree repo-none-3 worktree-none-3)
        ;; Sanity check: unfiltered, tree-top/bottom would NOT be org-match /
        ;; worktree-match -- if this failed the test below would prove
        ;; nothing about filtering.
        (expect (nerimux::%handle-client-ui-command s conn :tree-top nil nil))
        (expect (eq org-none-1 (nerimux::client-conn-selected-tree-object conn)))
        (expect (nerimux::%handle-client-ui-command s conn :tree-bottom nil nil))
        (expect (eq worktree-none-3 (nerimux::client-conn-selected-tree-object conn)))
        (setf (nerimux::client-conn-tree-filter conn) "only-match")
        (expect (nerimux::%handle-client-ui-command s conn :tree-top nil nil))
        (expect (eq org-match (nerimux::client-conn-selected-tree-object conn)))
        (expect (nerimux::%handle-client-ui-command s conn :tree-bottom nil nil))
        (expect (eq worktree-match (nerimux::client-conn-selected-tree-object conn))))))

  ;; wt-prune-confirm without --confirm must not reach the VCS layer, even
  ;; though the preview path (wt-prune) never requires it. Per the test
  ;; review finding, this now also carries a worktree in the fixture and
  ;; asserts it survives untouched, so a rejected confirm is verified against
  ;; actual repository state rather than only against the mock not firing.
)
