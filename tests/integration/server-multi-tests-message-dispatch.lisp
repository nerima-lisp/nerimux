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

  (it "main-thread-callback-queue-continues-after-callback-error"
    (let ((events nil)
          (nerimux::*main-thread-callbacks* nil))
      (nerimux::%enqueue-main-thread-callback
       (lambda () (error "expected callback failure")))
      (nerimux::%enqueue-main-thread-callback
       (lambda () (push :after-error events)))
      (nerimux::%drain-main-thread-callbacks)
      (expect (equal '(:after-error) events))))

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
               ;; render-session-to-string is only reached through the :pane
               ;; branch of %render-client-frame (FR-001/FR-007) -- the
               ;; default VIEW is :repolist, which would render the workspace
               ;; tree instead and never call the stub above at all.
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
          (setf (fdefinition 'nerimux/renderer:render-session-to-string) renderer)))))

  (it "multi-client-ui-command-state-is-private"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (nerimux::%client-ui-keys-p conn))
        (expect (nerimux::%handle-client-ui-command s conn :mode nil '("copy")))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :viewport nil '("3")))
        (expect (= 3 (nerimux::client-conn-viewport conn)))
        (expect (nerimux::%handle-client-ui-command s conn :viewport nil '("-1")))
        (expect (= 2 (nerimux::client-conn-viewport conn)))
        (expect (null (nerimux::%handle-client-ui-command
                       s conn :mode nil '("not-a-mode"))))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command
                 s conn :focus nil '("not-a-pane")))
        (expect (nerimux::%handle-client-ui-command s conn :focus nil nil))
        (expect (eq (nerimux::window-active-pane (nerimux::session-active-window s))
                    (nerimux::client-conn-focus conn)))
        (expect (nerimux::%handle-client-ui-command s conn :viewport nil '("bad")))
        (expect (= 0 (nerimux::client-conn-viewport conn)))
        (expect (nerimux::%handle-client-ui-command s conn :cancel nil nil))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :enter-copy nil nil))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :toggle-copy nil nil))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :enter-input nil nil))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect (nerimux::%handle-client-ui-command s conn :enter-normal nil nil))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :detail nil nil))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect (nerimux::%handle-client-ui-command s conn :home nil nil))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (nerimux::%handle-client-ui-command s conn :tree-scroll nil '("bad")))
        (expect (= 0 (nerimux::client-conn-tree-scroll conn))))))

  (it "ui-command-mode-and-picker-transitions-share-a-small-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%open-client-picker
              (lambda (conn)
                (push :open calls)
                (setf (nerimux::client-conn-modal conn) :picker)))
             (nerimux::%close-client-picker
              (lambda (conn)
                (push :close calls)
                (setf (nerimux::client-conn-modal conn) nil)))
             (nerimux::%select-client-picker-item
              (lambda (session conn)
                (declare (ignore session))
                (push :select calls)
                (setf (nerimux::client-conn-modal conn) nil)
                t))
             (nerimux::%client-enter-copy-mode
              (lambda (session conn)
                (declare (ignore session))
                (setf (nerimux::client-conn-modal conn) :scrollback))))
          (expect (nerimux::%handle-client-ui-command s conn :mode nil '("picker")))
          (expect (eq :picker (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :accept nil nil))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :mode nil '("copy")))
          (expect (eq :scrollback (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :cancel nil nil))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (equal '(:select :open) calls))))))

  (it "ui-command-aliases-preserve-command-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%client-rebind-prefix
              (lambda (conn prefix)
                (declare (ignore conn))
                (push (list :prefix prefix) calls)))
             (nerimux::%select-client-tree-relative
              (lambda (conn delta)
                (declare (ignore conn))
                (push (list :tree delta) calls)))
             (nerimux::%move-client-tree-scroll
              (lambda (conn delta)
                (declare (ignore conn))
                (push (list :scroll delta) calls))))
          (expect (nerimux::%handle-client-ui-command
                   s conn :prefix-key "C-x" nil))
          (expect (nerimux::%handle-client-ui-command
                   s conn :tree-prev nil '("2")))
          (expect (nerimux::%handle-client-ui-command
                   s conn :tree-next nil nil))
          (expect (nerimux::%handle-client-ui-command
                   s conn :tree-scroll nil '("bad")))
          (expect (equal '((:scroll 1) (:tree 1) (:tree -2) (:prefix "C-x"))
                         calls))))))

  (it "picker-command-actions-share-a-small-dispatch-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%select-client-picker-item
              (lambda (session conn)
                (declare (ignore session conn))
                (push :select calls)))
             (nerimux::%refresh-client-picker
              (lambda (conn)
                (declare (ignore conn))
                (push :refresh calls)))
             (nerimux::%mark-dirty
              (lambda ()
                (push :dirty calls)))
             (nerimux::%move-client-picker-index
              (lambda (conn delta)
                (declare (ignore conn))
                (push (list :move delta) calls)))
             (nerimux::%delete-client-picker-query-character
              (lambda (conn)
                (declare (ignore conn))
                (push :backspace calls)))
             (nerimux::%set-client-picker-query
              (lambda (conn value)
                (declare (ignore conn))
                (push (list :query value) calls)))
             (nerimux::%set-client-picker-regex
              (lambda (conn value supplied-p)
                (declare (ignore conn))
                (push (list :regex value supplied-p) calls))))
          (dolist (command '((:picker-accept nil nil)
                             (:picker-refresh nil nil)
                             (:picker-next "2" nil)
                             (:picker-up "2" nil)
                             (:picker-backspace nil nil)
                             (:picker-query "needle" nil)
                             (:picker-query nil ("from-args"))
                             (:picker-regex "pattern" nil)
                             (:picker-regex nil ("from-args"))))
            (destructuring-bind (name target args) command
              (expect (nerimux::%handle-client-ui-command
                       s conn name target args))))
          (expect (equal '((:regex "from-args" ("from-args"))
                           (:regex "pattern" "pattern")
                           (:query "from-args")
                           (:query "needle")
                           :backspace
                           (:move -2)
                           (:move 2)
                           :dirty
                           :refresh
                           :select)
                         calls))))))

  (it "forwarded-command-message-keeps-ui-and-rejects-unknown-commands"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload :home))))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload :not-a-ui-command)))))))

  (it "forwarded-command-message-applies-focus-and-viewport"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload
                   :viewport :args '("4")))))
        (expect (= 4 (nerimux::client-conn-viewport conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload
                   :focus))))
        (expect (eq (nerimux::window-active-pane
                     (nerimux::session-active-window s))
                    (nerimux::client-conn-focus conn))))))

  (it "kill-command-replies-drops-client-and-forwards-success"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (requests nil)
            (frames nil)
            (drops nil))
        (with-stubbed-fdefinition
            ((nerimux::%server-kill-request
              (lambda (session force)
                (push (list session force) requests)
                (values :ok nil)))
             (nerimux::send-frame
              (lambda (stream frame)
                (push (list stream frame) frames)))
             (nerimux::%drop-client
              (lambda (client)
                (push client drops))))
          (expect (eq :quit
                      (nerimux::%handle-client-ui-command
                       s conn :kill nil '("--force"))))
          (expect (equal (list (list s t)) requests))
          (expect (equal (list conn) drops))
          (expect (= 1 (length frames)))))))

  (it "kill-command-replies-denied-and-still-drops-client"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (frames nil)
            (drops nil))
        (with-stubbed-fdefinition
            ((nerimux::%server-kill-request
              (lambda (session force)
                (declare (ignore session force))
                (values :denied '("active clients remain"))))
             (nerimux::send-frame
              (lambda (stream frame)
                (declare (ignore stream))
                (push frame frames)))
             (nerimux::%drop-client
              (lambda (client)
                (push client drops))))
          (expect (eq t
                      (nerimux::%handle-client-ui-command
                       s conn :kill nil nil)))
          (expect (= 1 (length frames)))
          (multiple-value-bind (type payload)
              (nerimux/protocol::decode-frame (first frames))
            (expect (= nerimux::+msg-reply+ type))
            (expect (search "DENIED" (nerimux/protocol::decode-text payload))))
          (expect (equal (list conn) drops))))))

  (it "forwarded-kill-command-propagates-quit-disposition"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (with-stubbed-fdefinition
            ((nerimux::%handle-client-kill-command
              (lambda (session client args)
                (declare (ignore session client args))
                :quit)))
          (expect (eq :quit
                      (nerimux::%handle-multi-command-message
                       s conn
                       (nerimux/protocol::encode-command-payload :kill))))))))

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
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%handle-multi-key-message s conn #(16))
               (expect (eq :picker (nerimux::client-conn-modal conn)))
               (expect (string= ""
                                (nerimux::client-conn-picker-query conn))))
          (setf (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh
                (fdefinition 'nerimux/vcs:workspace-organizations)
                organizations)))))

  ;; PR2 (R6.3 pivot, user decision) added `n`: create a worktree immediately,
  ;; with an auto-generated wt-<YYYYMMDDTHHMMSS> branch name, for the selected
  ;; repository, with a single keystroke as its own confirmation
  ;; (%CLIENT-START-WORKTREE-CREATE / %CLIENT-CREATE-WORKTREE-NOW).
  ;;
  ;; DELETED (genuinely retired, nothing replaces it): magit alignment
  ;; retires `n` as "next row" (contract §2) and moves worktree creation
  ;; behind the `w` transient's own `n` entry -- but
  ;; src/bootstrap/server-multi-dispatch-transient.lisp (+TRANSIENT-
  ;; DEFINITIONS+, already landed) wires that entry to `(:stub "worktree
  ;; creation needs a path/branch prompt, not wired in this build")`, not to
  ;; %CLIENT-START-WORKTREE-CREATE. The auto-branch-name single-keystroke
  ;; convenience these two tests covered has no reachable path at all in
  ;; this pass -- only an inert "not implemented" notice. The two tests that
  ;; drove %CLIENT-START-WORKTREE-CREATE directly (create-creates-
  ;; immediately-and-worktree-delete-still-prompts, and its worktree-
  ;; selection-resolution sibling) are removed rather than kept pointed at
  ;; now-dead code with no live caller. What replaces them: the coverage
  ;; below for the `w` transient's actual stub behaviour, and for
  ;; `:wt-create`, the OTHER entry path %CLIENT-CREATE-WORKTREE-NOW's
  ;; docstring names -- which is untouched by this migration and was never
  ;; covered by a VCS-reaching test anywhere in this suite.
  (it "wt-create-command-with-an-explicit-branch-reaches-the-vcs-layer"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (create (fdefinition 'nerimux/vcs:create-worktree-async))
             (call nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
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
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58)) ; :
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-create --branch feature/explicit --confirm"
                 :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository "feature/explicit") call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "overview-worktree-delete-dispatches-and-restores-overview"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
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
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree
                              &key force on-complete on-error callback-dispatch)
                       (declare (ignore on-complete on-error callback-dispatch))
                       (setf call (list received-worktree force))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               ;; `X`'s single-key "wt-delete --confirm" prefill is retired
               ;; (contract §2's removal list) with no live replacement --
               ;; the `w` transient's own `d` entry is wired to a
               ;; (:stub "not wired in this build") notice, not to
               ;; %CLIENT-START-WORKTREE-DELETE (see the removal note above
               ;; the create test). What survives is the `:` command line
               ;; itself, unaffected by any of this, so the trigger here is
               ;; typing the command a user would type by hand.
               (nerimux::%handle-multi-key-message s conn #(58)) ; :
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-delete --confirm" :encoding :utf-8))
               (expect (eq :command (nerimux::client-conn-modal conn)))
               (expect (string= "wt-delete --confirm"
                                (nerimux::client-conn-command-buffer conn)))
               ;; ... and submitting it must actually reach the VCS layer.
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list worktree nil) call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn)))
               (expect (string= "" (nerimux::client-conn-command-buffer conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

  ;; %client-delete-worktree's own guard: a `:` command submitted without
  ;; --confirm must not reach the VCS layer, even with a worktree selected.
  (it "overview-worktree-delete-without-confirm-is-rejected"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
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
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree
                              &key force on-complete on-error callback-dispatch)
                       (declare (ignore force on-complete on-error
                                       callback-dispatch))
                       (setf call received-worktree)
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-delete" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (string= "worktree delete requires --confirm"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
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
               (setf (nerimux::client-conn-view conn) :repolist)
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
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

  ;; DELETED (genuinely retired, nothing replaces it): this covered
  ;; %CLIENT-START-WORKTREE-DELETE/-LOCK/-UNLOCK's "notify when nothing is
  ;; selected" guard for the retired X/L/U single-key shortcuts. None of the
  ;; three has any caller left in the migrated UI -- the `w` transient's own
  ;; `d` entry is a (:stub ...) notice, not a call to
  ;; %CLIENT-START-WORKTREE-DELETE, and lock/unlock have no transient entry
  ;; at all (+TRANSIENT-DEFINITIONS+'s Worktree transient only defines `n`
  ;; and `d`, both stubs) -- so this guard now protects unreachable code.
  ;; The underlying `:` commands' OWN missing-selection guards
  ;; (%client-delete-worktree/-lock-worktree/-unlock-worktree, which do not
  ;; go through the retired functions at all) are exercised below and in
  ;; "overview-worktree-delete-without-selection-is-rejected".

  ;; `L`/`U`'s single-key "wt-lock/-unlock --confirm" prefill is retired
  ;; with no live replacement, the same way `X`'s is (see the note on the
  ;; delete test above) -- the Worktree transient does not mention lock or
  ;; unlock at all. What survives is the `:` command line itself.
  (it "wt-lock-and-wt-unlock-commands-reach-the-vcs-layer"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "feature" :repository repository
                :path "/tmp/feature" :branch "feature/lockme"))
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (lock-fn (fdefinition 'nerimux/vcs:lock-worktree-async))
             (unlock-fn (fdefinition 'nerimux/vcs:unlock-worktree-async))
             (lock-call nil)
             (unlock-call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:lock-worktree-async)
                     (lambda (received-worktree
                              &key reason on-complete on-error callback-dispatch)
                       (declare (ignore on-error callback-dispatch))
                       (setf lock-call (list received-worktree reason))
                       (funcall on-complete t)
                       t)
                     (fdefinition 'nerimux/vcs:unlock-worktree-async)
                     (lambda (received-worktree
                              &key on-complete on-error callback-dispatch)
                       (declare (ignore on-error callback-dispatch))
                       (setf unlock-call received-worktree)
                       (funcall on-complete t)
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58)) ; :
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-lock --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list worktree nil) lock-call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn)))
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-unlock --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (eq worktree unlock-call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:lock-worktree-async) lock-fn
                (fdefinition 'nerimux/vcs:unlock-worktree-async) unlock-fn)))))

  ;; Confirmed via +TRANSIENT-DEFINITIONS+ (server-multi-dispatch-
  ;; transient.lisp) and %HANDLE-CLIENT-UI-KEY-PAYLOAD's status-only `w`
  ;; binding (server-multi-dispatch-command-input.lisp), both already
  ;; landed: `w` opens the Worktree transient only from :status, and its
  ;; The `w` transient carries the four worktree operations the magit keymap
  ;; retired the shortcuts for -- `n` create, `X` delete, `L` lock, `U` unlock
  ;; are now `w c` / `w k` / `w l` / `w u`. This asserts they REACH those
  ;; operations rather than notifying a "not wired" stub: an earlier revision
  ;; stubbed all four, which silently deleted four working features while
  ;; reading like an unfinished new one.
  ;;
  ;; Driven end to end through %HANDLE-MULTI-KEY-MESSAGE rather than by calling
  ;; %OPEN-CLIENT-TRANSIENT directly, so the routing, the transient's key
  ;; lookup and the action's own dispatch are all on the path under test.
  ;;
  ;; With no repository selected, create reports "select a repository first"
  ;; and the other three report "select a worktree to ..." -- those messages
  ;; come from the worktree operations THEMSELVES (server-multi-dispatch-
  ;; command-input.lisp), so seeing one is proof the action ran, and no
  ;; fixture repository is needed to prove the wiring.
  (it "the-w-transient-reaches-the-real-worktree-operations"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil))
        (setf nerimux::*clients* (list conn))
        (setf (nerimux::client-conn-view conn) :status)
        (dolist (probe '((#(99)  . "select a repository first")   ; w c
                         (#(107) . "select a worktree to delete") ; w k
                         (#(108) . "select a worktree to lock")   ; w l
                         (#(117) . "select a worktree to unlock"))) ; w u
          (destructuring-bind (key . expected) probe
            (nerimux::%handle-multi-key-message
             s conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
            (expect (eq :transient (nerimux::client-conn-modal conn)))
            (nerimux::%handle-multi-key-message s conn key)
            (expect (string= expected
                             (first (nerimux::client-conn-message-log conn))))
            (expect (null (nerimux::client-conn-modal conn)))))
        ;; `w C` stays a stub on purpose: a chosen branch name needs a text
        ;; prompt, and the `:` command line already is one.
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(67)) ; C
        (expect (search "wt-create"
                        (first (nerimux::client-conn-message-log conn)))))))

  ;; Every :CALL handler in +TRANSIENT-DEFINITIONS+ is reached by FUNCALL out of
  ;; a data table, which is the one call shape none of this project's gates can
  ;; check: read-check sees only syntax, export-check only symbol resolution,
  ;; and internal-call-check matches %helper call sites textually, so a handler
  ;; whose arity disagrees with the caller compiles clean, loads clean, and
  ;; raises only when a user strikes that key.
  ;;
  ;; That is not hypothetical -- the `f` Fetch transient shipped into this
  ;; branch broken exactly this way: :CALL was widened to (SESSION CONN) while
  ;; its two entries were still sharp-quoted one-argument functions. Nothing
  ;; failed until the key was pressed.
  ;;
  ;; So this walks the table rather than naming keys: a handler added later
  ;; with the wrong arity is caught without anyone remembering to extend the
  ;; test. It asserts only that each handler is CALLABLE with the arguments
  ;; %RUN-TRANSIENT-ACTION passes; what each one then does is covered
  ;; individually elsewhere.
  (it "every-transient-call-handler-accepts-the-arguments-the-dispatcher-passes"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (checked 0))
        (setf nerimux::*clients* (list conn))
        (dolist (definition nerimux::+transient-definitions+)
          (destructuring-bind (title arguments actions) (cdr definition)
            (declare (ignore title arguments))
            (dolist (action actions)
              (let ((handler (third action)))
                (when (eq :call (first handler))
                  (incf checked)
                  ;; No HANDLER-CASE: a wrong argument count must surface as a
                  ;; failure here, not be absorbed into a passing assertion.
                  (funcall (second handler) s conn))))))
        ;; A table that stopped containing :CALL handlers would make every
        ;; assertion above vacuous, so the count is asserted too.
        (expect (plusp checked)))))

  ;; A dry-run preview must reach the VCS layer with :dry-run t and must not
  ;; remove anything from the repository's worktree list: the mock below only
  ;; mutates on a real (non-dry-run) call, so an unexpected mutation here
  ;; would mean dry-run stopped being dry.
  (it "overview-worktree-prune-preview-does-not-mutate"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
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
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error
                                callback-dispatch)
                       (declare (ignore verbose on-error callback-dispatch))
                       (setf call (list received-repository dry-run))
                       (unless dry-run
                         (setf (nerimux/workspace-model:repository-worktrees
                                received-repository)
                               nil))
                       (funcall on-complete "Would remove /tmp/stale")
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-prune" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository t) call))
               (expect (equal (list worktree)
                              (nerimux/workspace-model:repository-worktrees repository)))
               (expect (string= "worktree prune preview: Would remove /tmp/stale"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  ;; A confirmed prune must reach the VCS layer with :dry-run nil and, unlike
  ;; the preview, is expected to mutate the repository's worktree list. The
  ;; confirm now also requires a preview to have run first for this same
  ;; repository (CLIENT-CONN-PENDING-PRUNE-PREVIEW-REPOSITORY-ID), so this
  ;; drives wt-prune before wt-prune-confirm --confirm to match the legitimate
  ;; flow; see overview-worktree-prune-confirm-without-confirm-is-rejected in
  ;; server-multi-tests-message-dispatch-worktree.lisp for the case where
  ;; --confirm itself is missing (S7 fix: this comment used to name a test
  ;; that never existed anywhere under that name).
  (it "overview-worktree-prune-confirm-mutates"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
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
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error
                                callback-dispatch)
                       (declare (ignore verbose on-error callback-dispatch))
                       (setf call (list received-repository dry-run))
                       (unless dry-run
                         (setf (nerimux/workspace-model:repository-worktrees
                                received-repository)
                               nil))
                       (funcall on-complete "")
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
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
               (expect (null (nerimux/workspace-model:repository-worktrees repository)))
               (expect (string= "worktrees pruned"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  ;; PR2 `/` tree-filter mode (item 6, R6.3 pivot): entering it must NOT force
  ;; the view to :pane the way :input/:copy/:command do (%SET-CLIENT-UI-
  ;; MODE only special-cases those three) -- the whole point of `/` is to
  ;; keep navigating the :repolist tree while narrowing it. Typing and
  ;; backspacing both reset tree-scroll (a narrower/wider query can leave a
  ;; stale scroll offset past the end of the new filtered set). Esc clears
  ;; the query and drops the modal; Enter keeps it.
  (it "overview-tree-filter-key-enters-filter-mode-without-forcing-pane-view"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :filter (nerimux::client-conn-modal conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (setf (nerimux::client-conn-tree-scroll conn) 7)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "ab" :encoding :utf-8))
        (expect (string= "ab" (nerimux::client-conn-tree-filter conn)))
        (expect (zerop (nerimux::client-conn-tree-scroll conn)))
        (setf (nerimux::client-conn-tree-scroll conn) 3)
        (nerimux::%handle-multi-key-message s conn #(8))
        (expect (string= "a" (nerimux::client-conn-tree-filter conn)))
        (expect (zerop (nerimux::client-conn-tree-scroll conn)))
        ;; Esc cancels: clears the query and drops the modal, still in
        ;; :repolist.
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        ;; Esc arms R4.3's 2-byte swallow window; two no-op presses clear it
        ;; before `/` reopens tree-filter mode.
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "xyz" :encoding :utf-8))
        ;; Enter accepts: the query survives the modal closing.
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
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
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "abc" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (string= "abc" (nerimux::client-conn-tree-filter conn)))
        ;; Re-entering `/` (Enter's :accept path arms no ESC-swallow window,
        ;; unlike ESC's :cancel -- so no dummy presses are needed here).
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :filter (nerimux::client-conn-modal conn)))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "z" :encoding :utf-8))
        ;; "z", never "abcz" -- the old accepted query must not leak in.
        (expect (string= "z" (nerimux::client-conn-tree-filter conn))))))

  ;; :filter modal absorbs every printable key into the query buffer -- "n"/
  ;; "p" are ordinary characters there, never the :repolist navigation keys
  ;; (n = next row, p = previous row, contract §2), so the selection must not
  ;; move.
  ;; S4 fix: this used to call %HANDLE-CLIENT-TREE-FILTER-KEY-PAYLOAD
  ;; directly, bypassing %HANDLE-MULTI-KEY-MESSAGE entirely -- the exact
  ;; anti-pattern that once hid a real production dispatch bug (a mode
  ;; check that never actually routed here). Entering :FILTER modal via the
  ;; real `/` key first, mirroring the sibling test above (`overview-tree-
  ;; filter-key-enters-filter-mode-without-forcing-pane-view`), proves the
  ;; whole path -- modal transition and payload routing both -- rather than
  ;; only the leaf handler's own behaviour.
  (it "overview-tree-filter-mode-absorbs-np-as-query-text-not-navigation"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-np-absorb" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-np-absorb" :organization organization
                :specification "github.com/team/repo-np-absorb"))
             (conn (%make-test-conn))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn repository)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :filter (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "np" :encoding :utf-8))
        (expect (string= "np" (nerimux::client-conn-tree-filter conn)))
        (expect (eq repository (nerimux::client-conn-selected-tree-object conn))))))

  (it "overview-tree-filter-editing-rejects-invalid-input-and-respects-the-cap"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-tree-filter conn) nil
              (nerimux::client-conn-tree-scroll conn) 4)
        (expect (null (nerimux::%client-tree-filter-buffer-delete-character conn)))
        (expect (null (nerimux::%client-tree-filter-buffer-append conn #(1))))
        (expect (null (nerimux::%client-tree-filter-buffer-append conn #(10))))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        (setf (nerimux::client-conn-tree-filter conn)
              (make-string nerimux::+max-tree-filter-length+
                           :initial-element #\x))
        (expect (null (nerimux::%client-tree-filter-buffer-append conn #(121))))
        (expect (= nerimux::+max-tree-filter-length+
                   (length (nerimux::client-conn-tree-filter conn)))))))

  ;; DELETED (genuinely retired, nothing replaces it): these two covered
  ;; %CLIENT-START-WORKTREE-CREATE's "select a repository first" guard --
  ;; nothing selected, and an ambiguous multi-repository organization
  ;; selected -- for the retired `n` shortcut. %CLIENT-START-WORKTREE-CREATE
  ;; has no caller left (the `w` transient's `n` action is a pure (:STUB
  ;; ...) notice that never calls %CLIENT-SELECTED-REPOSITORY or this
  ;; function at all), so both guards now protect unreachable code; see the
  ;; removal note on the wt-create command test above for the evidence
  ;; (+TRANSIENT-DEFINITIONS+, already landed).

  ;; :tree-top/:tree-bottom must walk the FILTERED row set (review-round fix:
  ;; both now call %WORKSPACE-TREE-OBJECTS with CLIENT-CONN-TREE-FILTER),
  ;; not the whole unfiltered catalog.
  ;;
  ;; Section-based redesign: ORG-NOISE holds a dirty (Attention) worktree
  ;; that never matches the filter, so Attention exists unfiltered but is
  ;; pruned away entirely once the filter is active -- REPO-BURIED's own
  ;; worktree is clean and pane-less (reachable only via its repository's
  ;; own, default-collapsed, Repositories-section expansion), so unfiltered
  ;; it never surfaces as its own row at all. This makes both :tree-top and
  ;; :tree-bottom differ between the unfiltered and filtered cases, proving
  ;; the command genuinely reads the filtered set rather than coincidentally
  ;; landing on the same answer either way.
  (it "tree-top-and-tree-bottom-commands-use-the-filtered-row-set"
    (with-fake-session (s)
      (let* ((org-noise
               (nerimux/workspace-model:make-organization
                :id "org-top-bottom-noise" :host "github.com" :name "noise"))
             (org-buried
               (nerimux/workspace-model:make-organization
                :id "org-top-bottom-buried" :host "github.com" :name "buried"))
             (repo-noise
               (nerimux/workspace-model:make-repository
                :id "repo-top-bottom-noise" :organization org-noise
                :specification "github.com/noise/repo"))
             (repo-buried
               (nerimux/workspace-model:make-repository
                :id "repo-top-bottom-buried" :organization org-buried
                :specification "github.com/buried/repo"))
             (worktree-noise
               (nerimux/workspace-model:make-worktree
                :id "wt-top-bottom-noise" :repository repo-noise
                :path "/tmp/top-bottom-noise" :branch "attention-noise"
                :dirty-p t))
             (worktree-buried
               (nerimux/workspace-model:make-worktree
                :id "wt-top-bottom-buried" :repository repo-buried
                :path "/tmp/top-bottom-buried" :branch "only-match"))
             (conn (%make-test-conn))
             (nerimux/vcs::*workspace-organizations*
               (list org-noise org-buried)))
        (nerimux/workspace-model:organization-add-repository org-noise repo-noise)
        (nerimux/workspace-model:organization-add-repository org-buried repo-buried)
        (nerimux/workspace-model:repository-add-worktree repo-noise worktree-noise)
        (nerimux/workspace-model:repository-add-worktree repo-buried worktree-buried)
        ;; Sanity check: unfiltered, tree-top is the Attention section header
        ;; (WORKTREE-NOISE is dirty) and tree-bottom is REPO-BURIED's own row
        ;; (its worktree is collapsed by default) -- neither is what the
        ;; filtered case below lands on, so that case proves something.
        (expect (nerimux::%handle-client-ui-command s conn :tree-top nil nil))
        (expect (eq :attention (nerimux::client-conn-selected-tree-object conn)))
        (expect (nerimux::%handle-client-ui-command s conn :tree-bottom nil nil))
        (expect (eq repo-buried (nerimux::client-conn-selected-tree-object conn)))
        (setf (nerimux::client-conn-tree-filter conn) "only-match")
        (expect (nerimux::%handle-client-ui-command s conn :tree-top nil nil))
        (expect (eq :repositories (nerimux::client-conn-selected-tree-object conn)))
        (expect (nerimux::%handle-client-ui-command s conn :tree-bottom nil nil))
        (expect (eq worktree-buried (nerimux::client-conn-selected-tree-object conn))))))

  ;; Section-based overview redesign: Tab (byte 9) toggles the selected
  ;; row's own expand/collapse state -- a :SECTION row toggles that section
  ;; (*WORKSPACE-COLLAPSED-NODE-IDS*, default-expanded), a REPOSITORY row
  ;; toggles its worktree listing (*WORKSPACE-EXPANDED-NODE-IDS*, default-
  ;; collapsed) -- driven through the same one-byte-per-message framing a
  ;; real client uses.
  (it "tab-key-toggles-the-selected-section-header-and-repository-row"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-tab" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-tab" :organization organization
                :specification "github.com/team/repo-tab"))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn :repositories)
        (nerimux::%handle-multi-key-message s conn #(9))
        (expect (gethash (list :section :repositories)
                         nerimux::*workspace-collapsed-node-ids*))
        (nerimux::%handle-multi-key-message s conn #(9))
        (expect (null (gethash (list :section :repositories)
                               nerimux::*workspace-collapsed-node-ids*)))
        (nerimux::%set-client-selected-tree-object conn repository)
        (nerimux::%handle-multi-key-message s conn #(9))
        (expect (gethash (list :repository (nerimux/workspace-model:repository-id repository))
                         nerimux::*workspace-expanded-node-ids*)))))

  ;; J/K (uppercase, byte-driven "jump across section headers") are retired
  ;; (contract §2's removal list); the same jump is now M-n/M-p, confirmed
  ;; against *CLIENT-META-PENDING*/%CLIENT-META-PENDING-CONSUME
  ;; (server-multi-dispatch-command-input.lisp): ESC arrives as its own key
  ;; message, then the following `n`/`p` byte resolves the pending chord --
  ;; the same one-byte-per-message wire shape an arrow key's CSI sequence
  ;; uses.
  (it "meta-n-and-meta-p-jump-the-selection-across-section-headers"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-mnp-keys" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-mnp-keys" :organization organization
                :specification "github.com/team/repo-mnp-keys"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-mnp-keys" :repository repository :path "/tmp/mnp-keys"
                :branch "mnp-keys" :dirty-p t))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        ;; Rows: (Attention header) worktree (Repositories header)
        ;; repository -- select the worktree row directly, so M-n has to
        ;; skip past it to land on :REPOSITORIES.
        (nerimux::%set-client-selected-tree-object conn worktree)
        (nerimux::%handle-multi-key-message s conn #(27))
        (nerimux::%handle-multi-key-message s conn #(110))
        (expect (eq :repositories (nerimux::client-conn-selected-tree-object conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (nerimux::%handle-multi-key-message s conn #(112))
        (expect (eq :attention (nerimux::client-conn-selected-tree-object conn))))))

  ;; Inline worktree expansion (Wave B): Tab on a worktree row toggles its
  ;; own child rows (panes/files/commits, D3) into *WORKSPACE-EXPANDED-
  ;; NODE-IDS* the same way it already toggles a repository row's worktree
  ;; listing -- driven through the same one-byte-per-message framing as the
  ;; section/repository Tab test above.
  (it "tab-key-expands-and-collapses-a-worktree-rows-inline-detail"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-tab-wt" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-tab-wt" :organization organization
                :specification "github.com/team/repo-tab-wt"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-tab-wt" :repository repository :path "/tmp/tab-wt"
                :branch "tab-wt" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (flet ((entries ()
                 (nerimux/renderer::%workspace-flat-tree-entries
                  (list organization) nerimux::*workspace-collapsed-node-ids*
                  :expanded-node-ids nerimux::*workspace-expanded-node-ids*)))
          (expect (null (find :file (entries) :key #'fourth)))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                           nerimux::*workspace-expanded-node-ids*))
          (let ((file-entry (find :file (entries) :key #'fourth)))
            (expect file-entry)
            (expect (equal (list :file (nerimux/workspace-model:worktree-id worktree)
                                 "src/foo.lisp" " M")
                           (third file-entry))))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (null (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                                 nerimux::*workspace-expanded-node-ids*)))
          (expect (null (find :file (entries) :key #'fourth)))))))

  ;; A :FILE row's OBJECT is a fresh cons every flatten call (D3): selection
  ;; must re-anchor on it across a j/k move via EQUAL, not EQ, or the
  ;; cursor silently jumps back to the top/bottom of the tree the moment a
  ;; file row is the current selection.
  (it "selection-survives-re-flatten-on-a-file-row"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-file-reflatten" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-file-reflatten" :organization organization
                :specification "github.com/team/repo-file-reflatten"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-file-reflatten" :repository repository
                :path "/tmp/file-reflatten" :branch "file-reflatten" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (file-identity
               (list :file (nerimux/workspace-model:worktree-id worktree)
                     "src/foo.lisp" " M")))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (setf (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                       nerimux::*workspace-expanded-node-ids*)
              t)
        ;; A freshly-consed but EQUAL identity, standing in for a selection
        ;; captured on an earlier frame's flatten -- never EQ to whatever
        ;; %SELECT-CLIENT-TREE-RELATIVE flattens THIS call.
        (nerimux::%set-client-selected-tree-object conn (copy-list file-identity))
        (nerimux::%select-client-tree-relative conn 0)
        (expect (equal file-identity
                       (nerimux::client-conn-selected-tree-object conn))))))

  ;; S1 fix: a catalog refresh's rebind (%REBIND-CLIENT-SELECTION, run for
  ;; every live client from %REFRESH-CLIENT-PICKER's :ON-COMPLETE) must not
  ;; drop the selection to NIL just because the cursor sits on a cons-based
  ;; inline-expansion row (:FILE here) -- %TREE-OBJECT-SELECTION-TOKEN used
  ;; to have no typecase clause for those rows at all, so the fallback
  ;; lookup in %REBIND-CLIENT-SELECTION resolved a NIL token to NIL and
  ;; cleared the selection outright. *LAST-SELECTED-WORKTREE-TOKEN* is bound
  ;; to NIL so %CLIENT-ATTACH-SELECTION's own "previous selection" fallback
  ;; (a separate mechanism, unaffected by this fix) cannot coincidentally
  ;; restore the worktree and mask the bug under test.
  (it "a-file-row-selection-survives-a-catalog-refresh-rebind-by-re-anchoring-on-its-worktree"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-file-rebind" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-file-rebind" :organization organization
                :specification "github.com/team/repo-file-rebind"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-file-rebind" :repository repository
                :path "/tmp/file-rebind" :branch "file-rebind" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux::*last-selected-worktree-token* nil)
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (nerimux::%handle-multi-key-message s conn #(9)) ; Tab: expand the worktree
        ;; Magit alignment (contract SS2): `n`, not the retired `j`, is next
        ;; row in the repolist/status UI keymap now.
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "n" :encoding :utf-8)) ; move onto the :file row
        (let ((selected (nerimux::client-conn-selected-tree-object conn)))
          (expect (consp selected))
          (expect (eq :file (first selected))))
        (nerimux::%rebind-client-selection conn (list organization))
        (expect (eq worktree (nerimux::client-conn-selected-tree-object conn)))
        (expect (eq worktree (nerimux::client-conn-selected-worktree conn))))))

  ;; S6: no test exercised SELECTION surviving a catalog refresh that
  ;; rebuilds every organization/repository/worktree struct from scratch --
  ;; same stable ids, but no struct EQ to its predecessor, exactly what a
  ;; real background scan produces. %REBIND-CLIENT-SELECTION re-resolves by
  ;; TOKEN (stable id), not by object identity, so this must re-select the
  ;; NEW worktree rather than clearing the selection.
  (it "a-worktree-selection-survives-a-stable-id-catalog-refresh-with-fresh-structs"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-stable-refresh" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-stable-refresh" :organization organization
              :specification "github.com/team/repo-stable-refresh"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-stable-refresh" :repository repository
              :path "/tmp/stable-refresh" :branch "stable-refresh"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* nil))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (setf (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-selected-tree-object conn worktree)
      (let* ((new-worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-stable-refresh" :path "/tmp/stable-refresh"
                :branch "stable-refresh"))
             (new-repository
               (nerimux/workspace-model:make-repository
                :id "repo-stable-refresh"
                :specification "github.com/team/repo-stable-refresh"))
             (new-organization
               (nerimux/workspace-model:make-organization
                :id "org-stable-refresh" :host "github.com" :name "team")))
        (nerimux/workspace-model:organization-add-repository new-organization new-repository)
        (nerimux/workspace-model:repository-add-worktree new-repository new-worktree)
        (expect (not (eq new-worktree worktree)))
        (nerimux::%rebind-client-selection conn (list new-organization))
        (expect (eq new-worktree (nerimux::client-conn-selected-tree-object conn)))
        (expect (eq new-worktree (nerimux::client-conn-selected-worktree conn))))))

  ;; S6's :FILE-row variant, exercising S1's fix together with the stable-id
  ;; refresh: the selection at refresh time is a :FILE row naming the OLD
  ;; worktree's id -- the fix must re-anchor onto the NEW worktree carrying
  ;; that same id, not onto the stale struct or NIL.
  (it "a-file-row-selection-re-anchors-onto-the-new-worktree-across-a-stable-id-refresh"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-stable-file-refresh" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-stable-file-refresh" :organization organization
              :specification "github.com/team/repo-stable-file-refresh"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-stable-file-refresh" :repository repository
              :path "/tmp/stable-file-refresh" :branch "stable-file-refresh"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* nil)
           (file-object (list :file "wt-stable-file-refresh" "src/foo.lisp" " M")))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (setf (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-selected-tree-object conn file-object)
      (let* ((new-worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-stable-file-refresh" :path "/tmp/stable-file-refresh"
                :branch "stable-file-refresh"))
             (new-repository
               (nerimux/workspace-model:make-repository
                :id "repo-stable-file-refresh"
                :specification "github.com/team/repo-stable-file-refresh"))
             (new-organization
               (nerimux/workspace-model:make-organization
                :id "org-stable-file-refresh" :host "github.com" :name "team")))
        (nerimux/workspace-model:organization-add-repository new-organization new-repository)
        (nerimux/workspace-model:repository-add-worktree new-repository new-worktree)
        (nerimux::%rebind-client-selection conn (list new-organization))
        (expect (eq new-worktree (nerimux::client-conn-selected-tree-object conn)))
        (expect (eq new-worktree (nerimux::client-conn-selected-worktree conn))))))

  ;; Wave C: Tab on a :FILE row toggles its own inline-diff expansion the
  ;; same way Tab on a worktree row toggles pane/file/commit (Wave B) --
  ;; driven through the same one-byte-per-message framing. REFRESH-
  ;; WORKTREE-FILE-DIFF-ASYNC is stubbed to a call counter rather than run
  ;; for real, so the dedup assertion below is about %CLIENT-TOGGLE-
  ;; SELECTED-FILE-DIFF's own guard, not about process/thread timing.
  (it "tab-key-on-a-file-row-expands-to-pending-and-dedups-the-fetch-across-collapse-reexpand"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-diff-tab" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-diff-tab" :organization organization
                :specification "github.com/team/repo-diff-tab"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-diff-tab" :repository repository :path "/tmp/diff-tab"
                :branch "diff-tab" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (wt-id (nerimux/workspace-model:worktree-id worktree))
             (file-object (list :file wt-id "src/foo.lisp" " M"))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (call-count 0))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn file-object)
        (with-stubbed-fdefinition
            ((nerimux/vcs:refresh-worktree-file-diff-async
               (lambda (repository worktree path &key on-complete on-error
                                                        callback-dispatch)
                 (declare (ignore repository worktree path on-complete on-error
                                  callback-dispatch))
                 (incf call-count)
                 nil)))
          ;; First Tab: expands, launches exactly one fetch, sets :pending.
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (gethash (list :file-diff wt-id "src/foo.lisp")
                           nerimux::*workspace-expanded-node-ids*))
          (expect (equal (list :pending 0 nil)
                         (gethash (list wt-id "src/foo.lisp")
                                  nerimux::*workspace-file-diffs*)))
          (expect (= 1 call-count))
          ;; Second Tab: collapses. The cache entry survives the collapse --
          ;; Wave C never clears the cache on collapse, only on the next
          ;; whole-catalog refresh settle.
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (null (gethash (list :file-diff wt-id "src/foo.lisp")
                                 nerimux::*workspace-expanded-node-ids*)))
          (expect (equal (list :pending 0 nil)
                         (gethash (list wt-id "src/foo.lisp")
                                  nerimux::*workspace-file-diffs*)))
          ;; Third Tab: re-expands while the entry is still :PENDING --
          ;; dedup holds, no second fetch launches.
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (gethash (list :file-diff wt-id "src/foo.lisp")
                           nerimux::*workspace-expanded-node-ids*))
          (expect (= 1 call-count))))))

  ;; With a :READY cache entry already in place, Tab must show the cached
  ;; diff lines without launching a fetch at all (the dedup guard's other
  ;; branch), and a second Tab collapses them back out of the flattened
  ;; tree.
  (it "tab-key-on-a-file-row-shows-cached-diff-lines-without-fetching-and-collapses-on-second-tab"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-diff-cached" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-diff-cached" :organization organization
                :specification "github.com/team/repo-diff-cached"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-diff-cached" :repository repository :path "/tmp/diff-cached"
                :branch "diff-cached" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (wt-id (nerimux/workspace-model:worktree-id worktree))
             (file-object (list :file wt-id "src/foo.lisp" " M"))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        ;; The :FILE row itself only appears once its parent WORKTREE row is
        ;; expanded (%WORKSPACE-WORKTREE-DETAIL-ENTRIES) -- Tab on the file
        ;; row toggles the file's OWN diff expansion, not the worktree's, so
        ;; the fixture has to expand the worktree separately to see the file
        ;; row (and its diff children) in the flattened tree at all.
        (setf (gethash (list :worktree wt-id) nerimux::*workspace-expanded-node-ids*) t)
        (setf (gethash (list wt-id "src/foo.lisp") nerimux::*workspace-file-diffs*)
              (list :ready 1 (list "+only line")))
        (nerimux::%set-client-selected-tree-object conn file-object)
        (with-stubbed-fdefinition
            ((nerimux/vcs:refresh-worktree-file-diff-async
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error "must not be reached: a :ready cache entry must not refetch"))))
          (flet ((diff-entries ()
                   (remove-if-not
                    (lambda (entry) (eq (fourth entry) :diff-line))
                    (nerimux/renderer::%workspace-flat-tree-entries
                     (list organization) nerimux::*workspace-collapsed-node-ids*
                     :expanded-node-ids nerimux::*workspace-expanded-node-ids*
                     :file-diffs nerimux::*workspace-file-diffs*))))
            (expect (null (diff-entries)))
            (nerimux::%handle-multi-key-message s conn #(9))
            (let ((entries (diff-entries)))
              (expect (= 1 (length entries)))
              (expect (string= "+only line" (second (first entries)))))
            (nerimux::%handle-multi-key-message s conn #(9))
            (expect (null (diff-entries))))))))

  ;;; ── `?` transient dispatch and the full-screen help view (FR-005/FR-010) ──
  ;;;
  ;;; Magit alignment retires CLIENT-CONN-HELP-VIEW-P and `?` opening the
  ;;; help view directly: `?` now opens the dispatch transient (MODAL
  ;;; :transient), and the help view is one of that transient's entries --
  ;;; `k`, per the WHY comment already committed on %CLIENT-OPEN-HELP-VIEW
  ;;; (server-multi-dispatch.lisp). +transient-definitions+ and
  ;;; %handle-client-transient-key-payload do not exist yet in this
  ;;; worktree, so the `?`-then-`k` route to the help view is inferred from
  ;;; that comment rather than confirmed against a real transient table --
  ;;; worth rechecking once the TRANSIENT unit lands. Once MODAL is :help,
  ;;; %handle-help-view-key is unchanged (q/?/Enter/Esc all close it), so
  ;;; that half of the old test still applies verbatim.

  (it "?-then-k-opens-the-help-view-and-swallows-other-keys-until-q-closes-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(63)) ; ?
        (expect (eq :transient (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(107)) ; k
        (expect (eq :help (nerimux::client-conn-modal conn)))
        ;; An ordinary navigation key must not leak to the view underneath
        ;; (and so not to any pane) while the help view is up.
        (nerimux::%handle-multi-key-message s conn #(110)) ; n
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(113)) ; q
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "?-then-k-also-opens-from-the-repolist-view-and-enter-or-esc-close-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(13)) ; Enter
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (nerimux::%handle-multi-key-message s conn #(27)) ; Esc
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "the rendered client frame shows the help view's sections while it is up"
    (with-fake-session (s)
      (let ((conn (%make-test-conn :rows 40 :cols 110)))
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (multiple-value-bind (type payload)
            (nerimux/protocol::decode-frame (nerimux::%render-client-frame s conn))
          (expect (= nerimux::+msg-frame+ type))
          (let ((visible (strip-sgr (nerimux/protocol::decode-text payload))))
            (expect (search "Navigate" visible))
            (expect (search "Prefix C-q" visible))
            (expect (search "Scrollback" visible))
            ;; "Modes" was the pre-magit section describing normal/input/copy.
            ;; Those modes are gone; a frame still showing that heading means
            ;; the help content drifted back.
            (expect (null (search "Modes" visible))))))))

  ;; The old two-flag design (a CONFIRM-VIEW slot plus a separate HELP-VIEW-P
  ;; boolean) could have both up at once, which is exactly what this test
  ;; used to probe: which one answers a key, which one renders. MODAL is now
  ;; a single exclusive slot BY CONSTRUCTION (see the struct's own WHY
  ;; comment), so there is no reachable state with two modals live -- opening
  ;; a confirmation while MODAL is :help does not layer over it, it REPLACES
  ;; it. This asserts that replacement directly: the old "who wins" question
  ;; is moot, and what replaced it is single-slot exclusivity.
  (it "opening a confirm-view while modal is :help replaces it outright"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn :rows 40 :cols 110))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-modal conn) :help)
        (nerimux::%open-confirm-view conn "WORKTREE DELETE"
                                     '(("worktree" . "feature/x"))
                                     (lambda () nil))
        (expect (eq :confirm (nerimux::client-conn-modal conn)))
        ;; Rendering: the confirm view is what is on screen now, not help.
        (multiple-value-bind (type payload)
            (nerimux/protocol::decode-frame (nerimux::%render-client-frame s conn))
          (declare (ignore type))
          (let ((visible (strip-sgr (nerimux/protocol::decode-text payload))))
            (expect (search "WORKTREE DELETE" visible))
            (expect (not (search "Prefix C-q" visible)))))
        ;; Keys: n answers the confirmation (there is no help swallow left to
        ;; compete with it).
        (nerimux::%handle-multi-key-message s conn #(110)) ; n
        (expect (not (nerimux::client-conn-confirm-view conn)))
        ;; %close-confirm-view drops MODAL to NIL, not back to :help -- there
        ;; is no stack to pop, only the one slot the confirmation overwrote.
        (expect (null (nerimux::client-conn-modal conn))))))

  ;; S5 fix: the assertion above only proves `?` did not open the transient
  ;; -- it says nothing about where the byte actually went. Extended to
  ;; assert the forwarding side, mirroring %HANDLE-CLIENT-INPUT-KEY-PAYLOAD's
  ;; own live-pane branch (server-multi-dispatch-command-input.lisp), which
  ;; calls NERIMUX/PTY:PTY-WRITE directly rather than through any indirection
  ;; layer -- fd 9999 fakes "live" without a real PTY, the same technique
  ;; used elsewhere in this suite (e.g. server-dispatch-helper-tests.lisp's
  ;; tree-navigation-suite), and PTY-WRITE is stubbed to capture its call.
  ;;
  ;; Magit alignment retires :input mode outright (FR-007): a pane now takes
  ;; every byte, `?` included, whenever VIEW is :pane and MODAL is NIL, with
  ;; no mode to leave first. This is that FR-007 core invariant, specialised
  ;; to the one byte (`?`) that would otherwise be ambiguous with opening
  ;; the transient.
  (it "?-reaches-a-focused-pane-directly-in-pane-view-instead-of-opening-the-transient"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux::window-active-pane (nerimux::session-active-window s)))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 9999)
        (setf (nerimux::client-conn-view conn) :pane
              (nerimux::client-conn-focus conn) pane)
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-write
               (lambda (fd payload) (push (list fd payload) writes))))
          (nerimux::%handle-multi-key-message s conn #(63))
          (expect (null (nerimux::client-conn-modal conn)))
          ;; EQUALP, not EQUAL: a general (non-string) vector compares by EQ
          ;; under EQUAL, and PAYLOAD here is a fresh #(63) distinct from the
          ;; literal captured above -- EQUALP compares vector contents.
          (expect (equalp (list (list 9999 #(63))) writes))))))

  ;; FR-007's general case, requested independently of the `?`-specific test
  ;; above: with MODAL NIL and VIEW :pane, an entirely ordinary byte -- one
  ;; that would be a UI-bound key in :repolist/:status -- reaches the pane
  ;; with no mode to leave first. `n` is deliberately chosen: it is bound to
  ;; "next row" in :repolist (contract §2), so this also shows the same byte
  ;; means two different things purely as a function of VIEW.
  (it "an-ordinary-byte-reaches-a-focused-pane-directly-in-pane-view-fr-007"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux::window-active-pane (nerimux::session-active-window s)))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 9999)
        (setf (nerimux::client-conn-view conn) :pane
              (nerimux::client-conn-focus conn) pane)
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-write
               (lambda (fd payload) (push (list fd payload) writes))))
          (nerimux::%handle-multi-key-message s conn #(110)) ; n
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (eq :pane (nerimux::client-conn-view conn)))
          (expect (equalp (list (list 9999 #(110))) writes))))))

  ;; FR-007's other half: with MODAL set, the modal owns the key and it does
  ;; NOT reach the view underneath, however VIEW is set. :help swallows
  ;; every key but its own close set (q/?/Enter/Esc, unchanged behaviour),
  ;; so `n` here must neither move the (absent) selection nor be forwarded
  ;; anywhere -- it must simply do nothing while :help remains up.
  (it "a-modal-owns-the-key-and-the-view-underneath-never-sees-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist
              (nerimux::client-conn-modal conn) :help)
        (nerimux::%handle-multi-key-message s conn #(110)) ; n: "next row" in :repolist
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (expect (null (nerimux::client-conn-selected-tree-object conn))))))

  ;; BUG-2 (R6.2/design §7.3): a FAILED object shows stale; other objects
  ;; don't inherit it. Drives the REAL refresh path -- %REFRESH-CLIENT-
  ;; PICKER -> NERIMUX/VCS:REFRESH-WORKSPACE-ORGANIZATIONS-ASYNC ->
  ;; SCAN-REPOSITORIES-ASYNC -> REFRESH-WORKSPACE-STATUS-ASYNC ->
  ;; REFRESH-REPOSITORIES-ASYNC -- stubbed only at cl-vcs-kit's own outer
  ;; seams (GHQ-LIST-REPOSITORIES, MAKE-VCS-REPOSITORY, VCS-LIST-WORKTREES,
  ;; VCS-STATUS-STRUCTURED), with two ghq entries under one organization:
  ;; one repository whose `git status` fails, one whose succeeds. Before
  ;; this fix, the failing repository's blanket :SETTLE :STALE-P T marked
  ;; every node in the catalog stale, including the healthy repository's
  ;; own row -- despite "+N DIRTY" (or here, a clean status) already having
  ;; resolved successfully for it.
  (it "a single repository's status failure marks only that repository stale, not the whole catalog"
    (let* ((healthy-path (%vcs-operations-existing-path))
           (failing-path
             (namestring
              (merge-pathnames "nerimux-bug2-failing-status/"
                               (host-kit:temporary-directory))))
           (healthy-entry
             (vcs-kit:make-ghq-repository-entry
              :specification "bug2-host/team/healthy" :path healthy-path))
           (failing-entry
             (vcs-kit:make-ghq-repository-entry
              :specification "bug2-host/team/failing" :path failing-path))
           (available (fdefinition 'nerimux/vcs:vcs-package-available-p)))
      (ensure-directories-exist failing-path)
      (let ((nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* nil)
            ;; %SET-WORKSPACE-CATALOG-REFRESH-STATE's :SETTLE branch
            ;; unconditionally CLRHASHes *WORKSPACE-FILE-DIFFS* and resets
            ;; *WORKSPACE-FILE-DIFFS-ORDER* (F4's wholesale-invalidate-on-
            ;; settle behavior) -- this test's refresh reaches that branch,
            ;; so both are isolated here too rather than clearing whatever
            ;; another test left cached.
            (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
            (nerimux::*workspace-file-diffs-order* nil)
            (conn (nerimux::%make-client-conn)))
        (unwind-protect
             (progn
               ;; NOT let-bound: *MAIN-THREAD-CALLBACKS* is pushed onto by
               ;; the scan/status worker threads this test spawns for real
               ;; (unlike every OTHER variable in this LET, which only the
               ;; drained callback -- running back on THIS thread -- ever
               ;; touches). A LET rebinding is only visible on the thread
               ;; that established it; SBCL does not propagate a parent
               ;; thread's dynamic bindings into a freshly spawned one, so a
               ;; worker thread's push would land on the untouched GLOBAL
               ;; value while this thread's %DRAIN-MAIN-THREAD-CALLBACKS
               ;; kept draining its own empty LET-local one -- silently
               ;; never seeing anything the workers queued.
               (setf nerimux::*main-thread-callbacks* nil)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t))
               (with-stubbed-fdefinition
                   ((vcs-kit:ghq-list-repositories
                      (lambda (&key query)
                        (declare (ignore query))
                        (list healthy-entry failing-entry)))
                    (vcs-kit:make-vcs-repository
                      (lambda (directory &rest arguments)
                        (declare (ignore arguments))
                        directory))
                    (vcs-kit:vcs-list-worktrees
                      (lambda (directory)
                        (list (%vcs-operations-fake-worktree
                               directory :branch "main" :head "head"))))
                    (vcs-kit:vcs-status-structured
                      (lambda (directory &rest arguments)
                        (declare (ignore arguments))
                        (if (string= directory failing-path)
                            (error "synthetic status failure for BUG-2")
                            (%vcs-operations-status-snapshot
                             :branch-head "head" :ahead 0 :behind 0)))))
                 (nerimux::%refresh-client-picker conn)
                 ;; %REFRESH-CLIENT-PICKER (unlike %ADD-CLIENT) never touches
                 ;; *WORKSPACE-CATALOG-LOADED-P* -- that flag is exclusive to
                 ;; the initial-attach scan. The refresh's own completion
                 ;; signal here is *WORKSPACE-REFRESHING-IDS* draining back
                 ;; to empty: :MARK populates it once the scan lands
                 ;; (on-catalog), and :SETTLE (on-complete) clears it for
                 ;; good. Waiting on catalog non-emptiness first rules out
                 ;; the vacuous t=0 state, where the table is ALSO empty
                 ;; because nothing has run yet.
                 (let ((deadline (+ (get-internal-real-time)
                                    (* 2 internal-time-units-per-second))))
                   (loop until (and (plusp (length (nerimux/vcs:workspace-organizations)))
                                    (zerop (hash-table-count
                                            nerimux::*workspace-refreshing-ids*)))
                         while (< (get-internal-real-time) deadline)
                         do (nerimux::%drain-main-thread-callbacks)
                            (sleep 0.01))
                   (nerimux::%drain-main-thread-callbacks))
                 (expect (plusp (length (nerimux/vcs:workspace-organizations))))
                 (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
                 (let* ((organizations (nerimux/vcs:workspace-organizations))
                        (repositories
                          (and organizations
                               (nerimux/workspace-model:organization-repositories
                                (first organizations))))
                        (healthy-repository
                          (find healthy-path repositories
                                :key #'nerimux/workspace-model:repository-local-path
                                :test #'string=))
                        (failing-repository
                          (find failing-path repositories
                                :key #'nerimux/workspace-model:repository-local-path
                                :test #'string=)))
                   (expect healthy-repository)
                   (expect failing-repository)
                   ;; The failing repository, and each of its worktrees, is
                   ;; stale.
                   (expect (gethash (list :repository
                                          (nerimux/workspace-model:repository-id
                                           failing-repository))
                                    nerimux::*workspace-stale-ids*))
                   (dolist (worktree (nerimux/workspace-model:repository-worktrees
                                      failing-repository))
                     (expect (gethash (list :worktree
                                            (nerimux/workspace-model:worktree-id worktree))
                                      nerimux::*workspace-stale-ids*)))
                   ;; The healthy repository, and each of its worktrees, is
                   ;; NOT stale -- the core BUG-2 regression check: before
                   ;; the fix, the whole-catalog :SETTLE :STALE-P T marked
                   ;; this repository stale too, despite its own status
                   ;; fetch having already succeeded.
                   (expect (not (gethash (list :repository
                                               (nerimux/workspace-model:repository-id
                                                healthy-repository))
                                         nerimux::*workspace-stale-ids*)))
                   (dolist (worktree (nerimux/workspace-model:repository-worktrees
                                      healthy-repository))
                     (expect (not (gethash (list :worktree
                                                 (nerimux/workspace-model:worktree-id worktree))
                                           nerimux::*workspace-stale-ids*)))))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available)
          (setf nerimux::*main-thread-callbacks* nil)
          (ignore-errors (sb-posix:rmdir failing-path))))))

  ;;; ── FR-003 status-view stage/unstage/discard: crash regression ───────────
  ;;
  ;; %HANDLE-CLIENT-UI-KEY-PAYLOAD's :status clauses bound s/S/u/U/k to five
  ;; functions with no DEFUN anywhere in src/ (%CLIENT-STAGE-SELECTION,
  ;; %CLIENT-STAGE-ALL, %CLIENT-UNSTAGE-SELECTION, %CLIENT-UNSTAGE-ALL,
  ;; %CLIENT-START-DISCARD-SELECTION). Pressing any of them raised UNDEFINED-
  ;; FUNCTION, which escapes %HANDLE-MULTI-KEY-MESSAGE (its only error
  ;; boundary is PEER-IO-FAILURE, not ERROR -- server-multi-dispatch.lisp)
  ;; and kills the single select(2) loop shared by every attached client.

  ;; FINISHES asserts the dispatch call itself never signals, which is the
  ;; exact shape of the crash this guards against: comment out any one of the
  ;; five DEFUNs above and this test's DOLIST goes red with an UNBOUND-
  ;; FUNCTION condition on that key, proving the guard is not vacuous.
  (it "status-view-stage-unstage-and-discard-keys-do-not-crash-the-dispatcher"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-crash-guard" :repository repository
                :path "/tmp/wt-crash-guard" :branch "main"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             ;; %CLIENT-SELECTED-STATUS-FILE resolves a :FILE row's worktree
             ;; via %WORKSPACE-FIND-WORKTREE against the live catalog (the
             ;; same lookup %CLIENT-TOGGLE-SELECTED-FILE-DIFF already uses),
             ;; not via this CONN's own selection state -- WORKTREE must
             ;; therefore actually be reachable through the catalog, exactly
             ;; as the section-based-overview tests above register theirs.
             (nerimux/vcs::*workspace-organizations* (list organization))
             (calls nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :status
              (nerimux::client-conn-selected-worktree conn) worktree)
        (with-stubbed-fdefinition
            ;; VCS-PACKAGE-AVAILABLE-P NIL keeps a successful write's
            ;; %RUN-TRANSIENT-GIT-WRITE on-complete from calling
            ;; %REFRESH-CLIENT-PICKER's real (network/filesystem-reaching)
            ;; catalog rescan -- irrelevant to what this test is pinning.
            ((nerimux/vcs:vcs-package-available-p (lambda () nil))
             (nerimux/vcs:git-write-operation-async
               (lambda (received-repository operation arguments
                        &key callback-dispatch on-complete on-error)
                 (declare (ignore callback-dispatch on-error))
                 (push (list received-repository operation arguments) calls)
                 (when on-complete (funcall on-complete t ""))
                 t)))
          ;; S (stage all) and U (unstage all) key off CLIENT-CONN-SELECTED-
          ;; WORKTREE directly, pressed first while that slot still holds
          ;; WORKTREE -- %SET-CLIENT-SELECTED-TREE-OBJECT below (needed for
          ;; s/u/k's own :FILE selection) clobbers CLIENT-CONN-SELECTED-
          ;; WORKTREE back to NIL for any object that is not itself a
          ;; worktree struct (%SET-CLIENT-SELECTED-TREE-OBJECT's own
          ;; coupling of the two slots), so S/U would otherwise see no
          ;; worktree selected.
          (dolist (key '("S" "U"))
            (finishes (nerimux::%handle-multi-key-message s conn key)))
          ;; s (stage), u (unstage), k (discard) each need a selected :FILE
          ;; row.
          (dolist (key '("s" "u" "k"))
            (nerimux::%set-client-selected-tree-object
             conn (list :file "wt-crash-guard" "src/foo.lisp" " M"))
            (finishes (nerimux::%handle-multi-key-message s conn key))))
        ;; k only opens a confirmation (pinned more precisely by the next
        ;; test); s/u/S/U each ran a write -- four writes, not five.
        (expect (= 4 (length calls)))
        (expect (every (lambda (call) (eq repository (first call))) calls))
        (expect (eq :confirm (nerimux::client-conn-modal conn))))))

  ;; Second required test: k (discard) is destructive, so it must open
  ;; %OPEN-CONFIRM-VIEW's y/n gate instead of writing immediately -- unlike
  ;; s/S/u/U above, which run straight away. Confirming with `y` is what
  ;; actually reaches the VCS layer.
  (it "status-view-discard-key-confirms-before-writing"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-discard-confirm" :repository repository
                :path "/tmp/wt-discard-confirm" :branch "main"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (calls nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :status
              (nerimux::client-conn-selected-worktree conn) worktree)
        (nerimux::%set-client-selected-tree-object
         conn (list :file "wt-discard-confirm" "src/foo.lisp" " M"))
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () nil))
             (nerimux/vcs:git-write-operation-async
               (lambda (received-repository operation arguments
                        &key callback-dispatch on-complete on-error)
                 (declare (ignore callback-dispatch on-error))
                 (push (list received-repository operation arguments) calls)
                 (when on-complete (funcall on-complete t ""))
                 t)))
          (nerimux::%handle-multi-key-message s conn "k")
          (expect (null calls))
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (expect (nerimux::client-conn-confirm-action conn))
          (nerimux::%handle-multi-key-message s conn "y")
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (equal (list (list repository :restore (list "--" "src/foo.lisp")))
                         calls)))))))

(describe "transient data and process log suite"
  (it "covers-visibility-and-process-log-state-machines"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (nerimux::%client-set-visibility-level conn 0))
        (expect (= 2 (nerimux::client-conn-visibility-level conn)))
        (dolist (expected '(3 4 1 2))
          (nerimux::%client-cycle-visibility conn)
          (expect (= expected
                     (nerimux::client-conn-visibility-level conn))))
        (nerimux::%client-cycle-visibility conn)
        (expect (= 3 (nerimux::client-conn-visibility-level conn)))
        (setf (nerimux::client-conn-process-log conn)
              (list "first" "second" "third"))
        (nerimux::%handle-process-log-key conn "n")
        (expect (= 1 (nerimux::client-conn-process-log-scroll conn)))
        (nerimux::%handle-process-log-key conn "p")
        (expect (= 0 (nerimux::client-conn-process-log-scroll conn)))
        (setf (nerimux::client-conn-modal conn) :process-log)
        (nerimux::%handle-process-log-key conn "q")
        (expect (null (nerimux::client-conn-modal conn)))
        (setf (nerimux::client-conn-view conn) :status)
        (nerimux::%client-step-back s conn)
        (expect (eq :repolist (nerimux::client-conn-view conn))))))

  (it "transient-command-data-and-process-log-share-stable-contracts"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (dolist (definition nerimux::+transient-definitions+)
          (let ((menu (cdr definition)))
            (expect (characterp (car definition)))
            (expect (stringp (first menu)))
            (expect (listp (second menu)))
            (dolist (action (third menu))
              (expect (characterp (first action)))
              (expect (stringp (second action)))
              (expect (member (first (third action))
                              '(:git :call :open-transient :help :stub))))))
        (expect (string= "git push --force"
                         (nerimux::%transient-command-text :push '("--force"))))
        (expect (null (nerimux::%transient-branch conn)))
        (expect (null (nerimux::%transient-subtitle #\P conn)))
        (expect (string= "on ?"
                         (nerimux::%transient-action-display-description
                          conn "on ~A")))
        (expect (equal '((#\f "--force" "--force" nil #\P))
                       (nerimux::%transient-render-arguments
                        #\P conn '((#\f . "--force")))))
        (nerimux::%client-transient-toggle-flag conn #\P "--force")
        (expect (equal '("--force")
                       (nerimux::%client-transient-active-flags conn #\P)))
        (nerimux::%client-transient-toggle-flag conn #\P "--force")
        (expect (null (nerimux::%client-transient-active-flags conn #\P)))
        (dotimes (index (1+ nerimux::+max-process-log-entries+))
          (nerimux::%client-log-process conn (format nil "git ~D" index) t nil))
        (expect (= nerimux::+max-process-log-entries+
                  (length (nerimux::client-conn-process-log conn))))
        (expect (equal '("git 20" "0" "")
                       (first (nerimux::client-conn-process-log conn)))))))

  (it "transient-rendering-and-dismissal-cover-the-modal-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null (nerimux::%open-client-transient conn #\~)))
        (expect (nerimux::%open-client-transient conn #\P))
        (let ((view (nerimux::client-conn-transient-view conn)))
          (expect (eq :transient (nerimux::client-conn-modal conn)))
        (expect (string= "Push" (nerimux/renderer:transient-view-title view)))
        (expect (equal '(#\p #\e)
                         (mapcar #'first
                                 (nerimux/renderer:transient-view-actions view)))))
        (nerimux::%handle-client-transient-key-payload s conn #(102))
        (expect (equal '("--force-with-lease")
                        (nerimux::%client-transient-active-flags conn #\P)))
        (nerimux::%run-transient-action s conn (list :open-transient #\P))
        (expect (eq :transient (nerimux::client-conn-modal conn)))
        (nerimux::%run-transient-action s conn
                                        (list :git #\P :push nil nil nil))
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-client-transient-key-payload s conn #(122))
        (nerimux::%handle-client-transient-key-payload s conn #(113))
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%open-client-transient conn #\P)
        (nerimux::%handle-client-transient-key-payload s conn #(27))
        (expect (null (nerimux::client-conn-transient-view conn))))))

  (it "transient-actions-cover-preconditions-confirmation-and-direct-execution"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil))
        (setf nerimux::*clients* (list conn))
        (nerimux::%run-transient-git-action conn #\P :push nil nil nil)
        (expect (equal "no repository selected"
                       (first (nerimux::client-conn-message-log conn))))
        (let* ((organization
                 (nerimux/workspace-model:make-organization
                  :id "org-transient" :host "github.com" :name "team"))
               (repository
                 (nerimux/workspace-model:make-repository
                  :id "repo-transient" :organization organization
                  :specification "github.com/team/repo-transient"))
               (calls nil))
          (nerimux/workspace-model:organization-add-repository organization repository)
          (nerimux::%set-client-selected-tree-object conn repository)
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () nil)))
            (nerimux::%run-transient-git-action conn #\P :push nil nil nil)
            (expect (equal "VCS adapter unavailable"
                           (first (nerimux::client-conn-message-log conn)))))
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () t))
               (nerimux::%refresh-client-picker
                 (lambda (ignored-connection)
                   (declare (ignore ignored-connection))))
               (nerimux/vcs:git-write-operation-async
                 (lambda (received operation args &key on-complete on-error
                                                callback-dispatch)
                   (declare (ignore callback-dispatch on-error))
                   (push (list received operation args) calls)
                   (funcall on-complete t "done")
                   t)))
            (nerimux::%run-transient-git-action
            conn #\P :push '("--force") t nil)
            (expect (eq :confirm (nerimux::client-conn-modal conn)))
            (funcall (nerimux::client-conn-confirm-action conn))
            (expect (equal (list (list repository :push '("--force"))) calls))
            (nerimux::%run-transient-git-action conn #\P :push nil nil nil)
        (expect (= 2 (length calls)))))
        (multiple-value-bind (repository worktree ignored-conn)
            (%make-worktree-operation-fixture)
          (declare (ignore repository ignored-conn))
          (nerimux::%set-client-selected-tree-object conn worktree)
          (expect (string= "feature/errors -> origin/feature/errors"
                           (nerimux::%transient-subtitle #\P conn)))
          (expect (string= "on feature/errors"
                           (nerimux::%transient-subtitle #\x conn))))))))

(describe "client frame dispatch contract suite"
  (it "renders every modal and base view through one frame boundary"
    (with-fake-session (s)
      (let ((conn (%make-test-conn :rows 40 :cols 110)))
        (dolist (modal '(:help :process-log :picker))
          (setf (nerimux::client-conn-modal conn) modal)
          (when (eq modal :process-log)
            (setf (nerimux::client-conn-process-log conn)
                  '(("git status" 0 ""))))
          (expect (nerimux::%render-client-frame s conn) :to-be-truthy))
        (nerimux::%open-client-transient conn #\P)
        (expect (nerimux::%render-client-frame s conn) :to-be-truthy)
        (setf (nerimux::client-conn-modal conn) nil)
        (dolist (view '(:repolist :status :pane))
          (setf (nerimux::client-conn-view conn) view)
          (expect (nerimux::%render-client-frame s conn) :to-be-truthy))))))
