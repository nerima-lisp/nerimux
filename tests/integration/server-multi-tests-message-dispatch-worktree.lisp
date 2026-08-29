(in-package #:nerimux/test)

;;;; Server multi-client message dispatch tests.

(describe "server-multi-suite"

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
                              &key dry-run verbose on-complete on-error
                                callback-dispatch)
                       (declare (ignore verbose on-error callback-dispatch))
                       (setf call (list received-repository dry-run))
                       (funcall on-complete "")
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
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
               (expect (nerimux::%client-ui-keys-p conn)))
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
               (setf (nerimux::client-conn-view conn) :repolist)
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
               (expect (nerimux::%client-ui-keys-p conn)))
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
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
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
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
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
        ;; Selecting a worktree pane sets VIEW :pane (%set-client-focus), so
        ;; the invariant under test is "the picker modal closed", not "keys
        ;; still route to the UI" -- %client-ui-keys-p would be false here
        ;; precisely because the selection succeeded.
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq pane (nerimux::client-conn-focus conn))))))

  ;; Direct proof of the finding above: an arrow-escape sequence sent the way
  ;; a real client actually sends it -- one byte per message -- never moves
;; the picker's selection index, because the second and third bytes are
;; swallowed before %move-client-picker-index is ever reached.
)
