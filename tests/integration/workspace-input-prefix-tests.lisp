(in-package #:nerimux/test)

(describe "workspace-input-prefix-suite"

  (it "r4-1-pane-view-forwards-bare-j-k-h-l-to-the-shell-instead-of-moving-focus"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/session:session-windows s)))
             (left (first (nerimux/window:window-panes win)))
             (fed nil)
             (orig (fdefinition 'nerimux/pane:pane-feed)))
        (nerimux::%set-client-focus conn left)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/pane:pane-feed)
                     (lambda (p bytes) (push (list p bytes) fed) (funcall orig p bytes)))
               (dolist (byte '(108 104 107 106)) ; l h k j
                 (nerimux::%handle-multi-key-message s conn (vector byte))))
          (setf (fdefinition 'nerimux/pane:pane-feed) orig))
        (expect (= 4 (length fed)))
        (expect (every (lambda (call) (eq left (first call))) fed))
        (expect (eq left (nerimux::client-conn-focus conn))))))

  (it "r4-1-arrow-escape-sequence-one-byte-at-a-time-forwards-every-byte-to-the-pane"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/session:session-windows s)))
             (left (first (nerimux/window:window-panes win)))
             (fed nil)
             (orig (fdefinition 'nerimux/pane:pane-feed)))
        (nerimux::%set-client-focus conn left)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/pane:pane-feed)
                     (lambda (p bytes) (push (list p bytes) fed) (funcall orig p bytes)))
               (nerimux::%handle-multi-key-message s conn #(27)) ; ESC
               (nerimux::%handle-multi-key-message s conn #(91)) ; [
               (nerimux::%handle-multi-key-message s conn #(65))) ; A
          (setf (fdefinition 'nerimux/pane:pane-feed) orig))
        (expect (equalp (list (list left #(65)) (list left #(91)) (list left #(27)))
                        fed))
        (expect (eq left (nerimux::client-conn-focus conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "r4-2-esc-is-forwarded-to-the-pane-in-pane-view-and-view-stays-pane"
    (with-minimal-session (pane win sess)
      (declare (ignorable win))
      (setf (nerimux/pane:pane-fd pane) 9999) ; "live" without a real PTY
      (let* ((conn (%make-test-conn))
             (writes nil)
             (orig (fdefinition 'nerimux::pty-write)))
        (nerimux::%set-client-focus conn pane) ; also sets VIEW :pane
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux::pty-write)
                     (lambda (fd bytes) (push (list fd bytes) writes)))
               (nerimux::%handle-multi-key-message sess conn #(27)))
          (setf (fdefinition 'nerimux::pty-write) orig))
        (expect (equalp (list (list 9999 #(27))) writes))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "r4-2-scrollback-exits-only-on-q-not-esc"
    (with-minimal-session (pane win sess)
      (declare (ignorable win))
      (let* ((conn (%make-test-conn))
             (screen (nerimux/pane:pane-screen pane)))
        (nerimux::%set-client-focus conn pane)
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message sess conn #(91)) ; [ : enter scrollback
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen))
        (nerimux::%handle-multi-key-message sess conn #(27)) ; ESC: no-op
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen))
        (nerimux::%handle-multi-key-message sess conn #(113)) ; q: exits
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen) :to-be-falsy))))

  (it "r4-3-esc-in-command-modal-swallows-exactly-the-next-two-bytes"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (nerimux::%handle-multi-key-message s conn #(58)) ; :
        (expect (eq :command (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC: cancels + arms swallow(2)
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(49)) ; "1" -- swallowed
        (nerimux::%handle-multi-key-message s conn #(51)) ; "3" -- swallowed
        (expect (= 2 (nerimux::client-conn-visibility-level conn))) ; default, unchanged
        (nerimux::%handle-multi-key-message s conn #(52)) ; "4" -- live again
        (expect (= 4 (nerimux::client-conn-visibility-level conn))))))

  (it "r4-3-esc-in-picker-modal-swallows-exactly-the-next-two-bytes"
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
                :path "/tmp/feature" :branch "feature/ux"))
             (conn (%make-test-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-modal conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization)))
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC: closes + arms swallow(2)
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (string= "" (nerimux::client-conn-picker-query conn)))
        (nerimux::%handle-multi-key-message s conn #(91))
        (nerimux::%handle-multi-key-message s conn #(65))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "r4-4-prefix-unbound-key-is-discarded-not-forwarded-to-the-pane"
    (with-minimal-session (pane win sess)
      (declare (ignorable win))
      (let* ((conn (%make-test-conn))
             (fed nil)
             (orig (fdefinition 'nerimux/pane:pane-feed)))
        (setf (nerimux::client-conn-stdin-target conn) pane)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/pane:pane-feed)
                     (lambda (p bytes) (push (list p bytes) fed) (funcall orig p bytes)))
               (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
               (expect (nerimux::client-conn-ui-prefix-p conn))
               (nerimux::%handle-multi-key-message sess conn #(101)) ; e: unbound
               (expect (null (nerimux::client-conn-ui-prefix-p conn))
                       )
               (expect (null fed) ))
          (setf (fdefinition 'nerimux/pane:pane-feed) orig)))))

  (it "r4-4-prefix-F-and-C-f-are-unbound-now-not-forwarded-to-the-pane"
    (with-minimal-session (pane win sess)
      (declare (ignorable win))
      (dolist (byte (list (char-code #\F) 6)) ; F, C-f
        (let* ((conn (%make-test-conn))
               (fed nil)
               (orig (fdefinition 'nerimux/pane:pane-feed)))
          (setf (nerimux::client-conn-stdin-target conn) pane)
          (unwind-protect
               (progn
                 (setf (fdefinition 'nerimux/pane:pane-feed)
                       (lambda (p bytes) (push (list p bytes) fed) (funcall orig p bytes)))
                 (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
                 (expect (nerimux::client-conn-ui-prefix-p conn))
                 (nerimux::%handle-multi-key-message sess conn (vector byte))
                 (expect (null (nerimux::client-conn-ui-prefix-p conn))))
            (setf (fdefinition 'nerimux/pane:pane-feed) orig))
          (expect (null fed))))))

  (it "r4-4-prefix-c-q-c-q-clears-modal"
    (with-minimal-session (pane win sess)
      (declare (ignorable pane win))
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-modal conn) :scrollback)
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
        (expect (nerimux::client-conn-ui-prefix-p conn))
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q again
        (expect (null (nerimux::client-conn-ui-prefix-p conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "r4-4-prefix-w-opens-status-view-for-the-focused-worktree"
    (with-minimal-session (pane win sess)
      (declare (ignorable win))
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
                :path "/tmp/wt" :branch "main"))
             (conn (%make-test-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux/pane:worktree-add-pane worktree pane)
        (nerimux::%set-client-focus conn pane)
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message sess conn #(119)) ; w
        (expect (eq :status (nerimux::client-conn-view conn)))
        (expect (eq worktree (nerimux::client-conn-selected-worktree conn))))))

  (it "r4-4-prefix-w-with-no-focused-worktree-falls-back-to-repolist"
    (with-minimal-session (pane win sess)
      (declare (ignorable pane win))
      (let ((conn (%make-test-conn)))
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message sess conn #(119)) ; w
        (expect (eq :repolist (nerimux::client-conn-view conn))))))

  (it "r4-4-prefix-open-bracket-enters-scrollback-on-the-focused-pane"
    (with-minimal-session (pane win sess)
      (declare (ignorable win))
      (let ((conn (%make-test-conn)))
        (nerimux::%set-client-focus conn pane)
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message sess conn #(91)) ; [
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p
                 (nerimux/pane:pane-screen pane))))))

  (it "r4-4-prefix-open-bracket-with-no-focused-pane-reports-and-stays-unmodal"
    (with-fake-session (s :nwindows 0)
      (let ((conn (%make-test-conn)))
        (nerimux::%handle-multi-key-message s conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message s conn #(91)) ; [
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "r4-4-prefix-dispatch-drops-only-the-explicit-detach-key"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (dolist (byte '(104 106 108 110 70 6 (char-code #\|)))
          (expect (null (nerimux::%workspace-prefix-dispatch s conn byte))))
        (expect (eq :drop
                    (nerimux::%workspace-prefix-dispatch
                     s conn (char-code #\d))))
        (expect (null (nerimux::%workspace-prefix-dispatch s conn 255)))
        (expect (null (nerimux::%workspace-prefix-dispatch s conn :unknown))))))

  (it "prefix-dispatch-routes-split-and-worktree-command-bindings"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (split-args nil)
            (command-args nil))
        (with-stubbed-fdefinition
            ((nerimux::%workspace-prefix-split
              (lambda (&rest args)
                (setf split-args args)))
             (nerimux::%client-open-selected-worktree-command
              (lambda (&rest args)
                (setf command-args args))))
          (expect (equal (list s conn :v)
                         (nerimux::%workspace-prefix-dispatch
                          s conn (char-code #\-))))
          (expect (equal (list s conn :v) split-args))
          (expect (equal (list s conn :h)
                         (nerimux::%workspace-prefix-dispatch
                          s conn (char-code #\|))))
          (expect (equal (list s conn :h) split-args))
          (expect (equal (list s conn nil)
                         (nerimux::%workspace-prefix-dispatch
                          s conn (char-code #\t))))
          (expect (equal (list s conn nil) command-args))))))

  (it "r4-5-prefix-actions-report-missing-focus-without-mutating-session"
    (with-fake-session (s :nwindows 0)
      (let ((conn (%make-test-conn)))
        (expect (null (nerimux::%workspace-prefix-split s conn :h)))
        (expect (null (nerimux::%workspace-prefix-close-pane s conn)))
        (expect (null (nerimux::%workspace-prefix-toggle-zoom s conn)))
        (expect (null (nerimux::%workspace-prefix-move-focus s conn :right)))
        (expect (null (nerimux::%workspace-prefix-cycle-window s conn 1)))
        (expect (null (nerimux::client-conn-focus conn)))))) (it "r5-6-prefix-unzoom-restores-a-zoomed-window-before-action"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (window (first (nerimux/session:session-windows s))))
        (nerimux::%set-client-focus conn (nerimux/window:window-active-pane window))
        (nerimux/window:window-zoom-toggle window)
        (expect (nerimux/window:window-zoom-p window))
        (nerimux::%workspace-prefix-unzoom window)
        (expect (not (nerimux/window:window-zoom-p window))))))

  (it "r5-6-prefix-cycle-reports-a-single-worktree-window"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (message nil)
             (window (first (nerimux/session:session-windows s)))
             (pane (nerimux/window:window-active-pane window))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt" :path "/tmp/wt" :branch "main")))
        (nerimux/pane:worktree-add-pane worktree pane)
        (nerimux::%set-client-focus conn pane)
        (with-stubbed-fdefinition
            ((nerimux::%client-notify
              (lambda (connection text)
                (declare (ignore connection))
                (setf message text))))
          (expect (null (nerimux::%workspace-prefix-cycle-window s conn 1))))
        (expect (search "no other window" message)))))

  (it "r5-7-prefix-open-status-steps-out-from-the-status-view"
    (with-fake-session (s :nwindows 0)
      (let ((conn (%make-test-conn)))
        (nerimux::%set-client-view conn :status)
        (expect (null (nerimux::%workspace-prefix-open-status s conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn))))))

  (it "r7-1-repository-fetch-reports-preconditions-and-completion"
    (with-fake-session (s)
      (expect s)
      (let ((conn (%make-test-conn))
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (fetch (fdefinition 'nerimux/vcs:fetch-repository-async))
            (refresh (fdefinition 'nerimux::%refresh-client-picker))
            (notify (fdefinition 'nerimux::%client-notify))
            (callback nil)
            (error-callback nil)
            (refreshed nil)
            (messages nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux::%client-notify)
                     (lambda (connection message)
                       (declare (ignore connection))
                       (push message messages)))
               (nerimux::%workspace-prefix-fetch-repository conn)
               (expect (search "selected repository" (first messages)))
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () nil))
               (let ((organization (nerimux/workspace-model:make-organization
                                    :id "org" :host "github.com" :name "team")))
                 (nerimux::%set-client-selected-tree-object
                  conn
                  (nerimux/workspace-model:make-repository
                   :id "repo" :organization organization
                   :specification "github.com/team/repo"))
                 (nerimux::%workspace-prefix-fetch-repository conn)
                 (expect (search "VCS unavailable" (first messages))))
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:fetch-repository-async)
                     (lambda (repository &key on-complete on-error
                                      callback-dispatch)
                       (declare (ignore repository callback-dispatch))
                       (setf callback on-complete error-callback on-error)
                       t)
                     (fdefinition 'nerimux::%refresh-client-picker)
                     (lambda (connection)
                       (declare (ignore connection))
                       (setf refreshed t))
                     (fdefinition 'nerimux::%client-notify)
                     (lambda (connection message)
                       (declare (ignore connection))
                       (push message messages)))
               (let ((organization (nerimux/workspace-model:make-organization
                                    :id "org" :host "github.com" :name "team"))
                     (repository nil))
                 (setf repository (nerimux/workspace-model:make-repository
                                   :id "repo" :organization organization
                                   :specification "github.com/team/repo"))
                 (nerimux::%set-client-selected-tree-object conn repository)
                 (nerimux::%workspace-prefix-fetch-repository conn)
                 (funcall callback t)
                 (expect refreshed)
                 (expect (search "fetch complete" (first messages)))
                 (funcall callback nil)
                 (expect (search "already in progress" (first messages)))
                 (funcall error-callback (make-condition 'simple-error
                                                          :format-control "offline"))
                 (expect (search "fetch failed" (first messages)))
                 (setf (fdefinition 'nerimux/vcs:fetch-repository-async)
                       (lambda (repository &key on-complete on-error
                                        callback-dispatch)
                         (declare (ignore repository on-complete on-error
                                             callback-dispatch))
                         (error "sync failure")))
                 (nerimux::%workspace-prefix-fetch-repository conn)
                 (expect (search "sync failure" (first messages)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:fetch-repository-async) fetch
                (fdefinition 'nerimux::%refresh-client-picker) refresh
                (fdefinition 'nerimux::%client-notify) notify))))) (it "r7-1-organization-fetch-reports-unavailable-and-in-progress"
    (with-fake-session (s)
      (expect s)
      (let ((conn (%make-test-conn))
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (fetch (fdefinition 'nerimux/vcs:fetch-organization-async))
            (refresh (fdefinition 'nerimux::%refresh-client-picker))
            (notify (fdefinition 'nerimux::%client-notify))
            (completion-callback nil)
            (error-callback nil)
            (refreshed nil)
            (messages nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () nil)
                     (fdefinition 'nerimux::%client-notify)
                     (lambda (connection message)
                       (declare (ignore connection))
                       (push message messages)))
               (nerimux::%workspace-prefix-fetch-organization conn)
               (expect (search "selected organization" (first messages)))
               (let ((organization (nerimux/workspace-model:make-organization
                                    :id "org" :host "github.com" :name "team")))
                 (nerimux::%set-client-selected-tree-object conn organization)
                 (nerimux::%workspace-prefix-fetch-organization conn)
                 (expect (search "VCS unavailable" (first messages))))
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux::%refresh-client-picker)
                     (lambda (connection)
                       (declare (ignore connection))
                       (setf refreshed t))
                     (fdefinition 'nerimux/vcs:fetch-organization-async)
                     (lambda (organization &key on-complete on-error
                                        callback-dispatch)
                       (declare (ignore organization callback-dispatch))
                       (setf completion-callback on-complete)
                       (funcall on-complete (list :repository))
                       (setf error-callback on-error)))
               (let ((organization (nerimux/workspace-model:make-organization
                                    :id "org" :host "github.com" :name "team")))
                 (nerimux::%set-client-selected-tree-object conn organization)
                 (nerimux::%workspace-prefix-fetch-organization conn)
                 (expect refreshed)
                 (expect (search "fetch complete" (first messages)))
                 (funcall completion-callback nil)
                 (expect (search "already in progress" (first messages)))
                 (funcall error-callback
                          (nerimux/workspace-model:make-repository
                           :id "repo" :organization organization
                           :specification "github.com/team/repo")
                          (make-condition 'simple-error
                                          :format-control "offline"))
                 (expect (search "fetch failed for repo" (first messages)))
                 (setf (fdefinition 'nerimux/vcs:fetch-organization-async)
                       (lambda (&rest args)
                         (declare (ignore args))
                         (error "sync failure")))
                 (nerimux::%workspace-prefix-fetch-organization conn)
                 (expect (search "sync failure" (first messages))))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:fetch-organization-async) fetch
                (fdefinition 'nerimux::%refresh-client-picker) refresh
                (fdefinition 'nerimux::%client-notify) notify))))

  (it "r5-4-refocuses-to-the-most-recent-pane-in-the-worktree"
    (let* ((organization (nerimux/workspace-model:make-organization
                           :id "org" :host "github.com" :name "team"))
           (repository (nerimux/workspace-model:make-repository
                         :id "repo" :organization organization
                         :specification "github.com/team/repo"))
           (worktree (nerimux/workspace-model:make-worktree
                       :id "wt" :repository repository
                       :path "/tmp/nerimux-r5-wt" :branch "feat/phase3"))
           (session (nerimux/session:make-session :id 1 :name "0" :windows nil))
           (test-conn (%make-test-conn))
           (older-pane (make-no-pty-pane 1 0 0 40 10))
           (newer-pane (make-no-pty-pane 2 0 0 40 10))
           (older-window (make-window :id 1 :name "older" :width 40 :height 10))
           (newer-window (make-window :id 2 :name "newer" :width 40 :height 10))
            (selected-window nil)
            (focused-pane nil))
      (setf (nerimux/workspace-model:worktree-panes worktree)
            (list older-pane newer-pane)
            (nerimux/pane:pane-window older-pane) older-window
            (nerimux/pane:pane-window newer-pane) newer-window
            (nerimux/window:window-last-active-time older-window) 1
            (nerimux/window:window-last-active-time newer-window) 2)
      (nerimux/window:window-select-pane newer-window newer-pane)
      (with-stubbed-fdefinition
            ((nerimux/session:session-select-window
              (lambda (object window)
                (declare (ignore object))
                (setf selected-window window)))
             (nerimux::%set-client-focus
              (lambda (connection pane)
                (declare (ignore connection))
                (setf focused-pane pane))))
          (nerimux::%workspace-refocus-after-window-close
           session test-conn worktree)
          (expect (eq newer-window selected-window))
          (expect (eq newer-pane focused-pane)))))
  )
