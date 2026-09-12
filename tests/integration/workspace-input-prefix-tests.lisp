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
               (dolist (byte '(108 104 107 106))
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
               (nerimux::%handle-multi-key-message s conn #(27))
               (nerimux::%handle-multi-key-message s conn #(91))
               (nerimux::%handle-multi-key-message s conn #(65)))
          (setf (fdefinition 'nerimux/pane:pane-feed) orig))
        (expect (equalp (list (list left #(65)) (list left #(91)) (list left #(27)))
                        fed))
        (expect (eq left (nerimux::client-conn-focus conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "r4-2-esc-is-forwarded-to-the-pane-in-pane-view-and-view-stays-pane"
    (with-minimal-session (pane win sess)
      (declare (ignorable win))
      (setf (nerimux/pane:pane-fd pane) 9999)
      (let* ((conn (%make-test-conn))
             (writes nil)
             (orig (fdefinition 'nerimux::pty-write)))
        (nerimux::%set-client-focus conn pane)
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
        (nerimux::%handle-multi-key-message sess conn #(17))
        (nerimux::%handle-multi-key-message sess conn #(91))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen))
        (nerimux::%handle-multi-key-message sess conn #(27))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen))
        (nerimux::%handle-multi-key-message sess conn #(113))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen) :to-be-falsy))))

  (it "r4-3-esc-in-command-modal-keeps-the-next-keystroke"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (nerimux::%handle-multi-key-message s conn #(58))
        (expect (eq :command (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(49))
        (expect (= 1 (nerimux::client-conn-visibility-level conn)))
        (nerimux::%handle-multi-key-message s conn #(51))
        (expect (= 3 (nerimux::client-conn-visibility-level conn)))
        (nerimux::%handle-multi-key-message s conn #(52))
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
        (nerimux::%handle-multi-key-message s conn #(27))
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
               (nerimux::%handle-multi-key-message sess conn #(17))
               (expect (nerimux::client-conn-ui-prefix-p conn))
               (nerimux::%handle-multi-key-message sess conn #(101))
               (expect (null (nerimux::client-conn-ui-prefix-p conn))
                       )
               (expect (null fed) ))
          (setf (fdefinition 'nerimux/pane:pane-feed) orig)))))

  (it "r4-4-prefix-F-and-C-f-are-unbound-now-not-forwarded-to-the-pane"
    (with-minimal-session (pane win sess)
      (declare (ignorable win))
      (dolist (byte (list (char-code #\F) 6))
        (let* ((conn (%make-test-conn))
               (fed nil)
               (orig (fdefinition 'nerimux/pane:pane-feed)))
          (setf (nerimux::client-conn-stdin-target conn) pane)
          (unwind-protect
               (progn
                 (setf (fdefinition 'nerimux/pane:pane-feed)
                       (lambda (p bytes) (push (list p bytes) fed) (funcall orig p bytes)))
                 (nerimux::%handle-multi-key-message sess conn #(17))
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
        (nerimux::%handle-multi-key-message sess conn #(17))
        (expect (nerimux::client-conn-ui-prefix-p conn))
        (nerimux::%handle-multi-key-message sess conn #(17))
        (expect (null (nerimux::client-conn-ui-prefix-p conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "r4-4-prefix-w-opens-overview-directly-and-repeatedly-for-the-focused-worktree"
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
        (dolist (view '(:pane :status :repolist))
          (nerimux::%set-client-view conn view)
          (dotimes (iteration 2)
            (declare (ignore iteration))
            (nerimux::%handle-multi-key-message sess conn #(17))
            (nerimux::%handle-multi-key-message sess conn #(119))
            (expect (eq :repolist (nerimux::client-conn-view conn)))
            (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))
            (expect (eq worktree (nerimux::client-conn-selected-tree-object conn))))))))

  (it "r4-4-prefix-w-with-no-focused-worktree-falls-back-to-repolist"
    (with-minimal-session (pane win sess)
      (declare (ignorable pane win))
      (let ((conn (%make-test-conn)))
        (nerimux::%handle-multi-key-message sess conn #(17))
        (nerimux::%handle-multi-key-message sess conn #(119))
        (expect (eq :repolist (nerimux::client-conn-view conn))))))

  (it "r4-4-prefix-open-bracket-enters-scrollback-on-the-focused-pane"
    (with-minimal-session (pane win sess)
      (declare (ignorable win))
      (let ((conn (%make-test-conn)))
        (nerimux::%set-client-focus conn pane)
        (nerimux::%handle-multi-key-message sess conn #(17))
        (nerimux::%handle-multi-key-message sess conn #(91))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p
                 (nerimux/pane:pane-screen pane))))))

  (it "r4-4-prefix-open-bracket-with-no-focused-pane-reports-and-stays-unmodal"
    (with-fake-session (s :nwindows 0)
      (let ((conn (%make-test-conn)))
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(91))
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

  (it "prefix-resize-byte-dispatch-grows-and-shrinks-by-five-cells"
    (with-loop-state
      (with-h-split-81-24 (left right window)
        (setf (nerimux/pane:pane-window left) window
              (nerimux/pane:pane-window right) window)
        (let* ((session (make-session :id 1 :name "s" :windows (list window)))
               (conn (%make-test-conn)))
          (window-select-pane window left)
          (session-select-window session window)
          (nerimux::%set-client-focus conn left)
          (nerimux::%handle-multi-key-message session conn #(17))
          (nerimux::%handle-multi-key-message session conn #(62))
          (expect (= 45 (nerimux/pane:pane-width left)))
          (expect (= 35 (nerimux/pane:pane-width right)))
          (nerimux::%handle-multi-key-message session conn #(17))
          (nerimux::%handle-multi-key-message session conn #(60))
          (expect (= 40 (nerimux/pane:pane-width left)))
          (expect (= 40 (nerimux/pane:pane-width right)))
          (window-select-pane window right)
          (nerimux::%set-client-focus conn right)
          (nerimux::%handle-multi-key-message session conn #(17))
          (nerimux::%handle-multi-key-message session conn #(62))
          (expect (= 35 (nerimux/pane:pane-width left)))
          (expect (= 45 (nerimux/pane:pane-width right)))))))

  (it "prefix-resize-byte-dispatch-notifies-when-no-horizontal-split-exists"
    (with-fake-session (session :nwindows 1 :npanes 1)
        (let* ((window (nerimux/session:session-active-window session))
             (pane (nerimux/window:window-active-pane window))
             (conn (%make-test-conn))
             (windows-before (nerimux/session:session-windows session))
             (panes-before (nerimux/window:window-panes window))
             (message nil))
        (nerimux::%set-client-focus conn pane)
        (expect (eq pane (nerimux::client-conn-focus conn)))
        (with-stubbed-fdefinition
            ((nerimux::%client-notify
              (lambda (connection text)
                (declare (ignore connection))
                (setf message text))))
          (nerimux::%handle-multi-key-message session conn #(17))
          (nerimux::%handle-multi-key-message session conn #(62)))
        (expect (equal windows-before (nerimux/session:session-windows session)))
        (expect (equal panes-before (nerimux/window:window-panes window)))
        (expect (string= "pane cannot be resized" message)))))

  (it "prefix-resize-bindings-appear-through-the-client-help-render"
    (with-fake-session (s)
      (let ((conn (%make-test-conn :rows 80 :cols 110)))
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (multiple-value-bind (type payload)
            (decode-frame (nerimux::%render-client-frame s conn))
          (expect (= nerimux::+msg-frame+ type))
          (let ((visible (strip-sgr (decode-text payload))))
            (expect (search "< / > width" visible))
            (expect (search "{ / } height" visible)))))))

  (it "r4-4-prefix-question-mark-opens-the-help-view-the-pane-hint-names"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :pane)
        (expect (null (nerimux::%workspace-prefix-dispatch
                       s conn (char-code #\?))))
        (expect (eq :help (nerimux::client-conn-modal conn))))))

  (it "closing-an-exited-pane-selected-through-the-tree-releases-the-selection"
    (with-fake-session (sess)
      (let* ((conn (%make-test-conn))
             (win (nerimux/session:session-active-window sess))
             (pane (nerimux/window:window-active-pane win))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-close" :path "/tmp/wt-close" :branch "main"))
             (nerimux::*clients* (list conn)))
        (setf (nerimux/pane:pane-window pane) win
              (nerimux/pane:pane-fd pane) -1)
        (nerimux/pane:worktree-add-pane worktree pane)
        (nerimux::%set-client-focus conn pane sess)
        ;; The tree's pane row is what the selection points at after Enter on
        ;; it; the close clears PANE-WINDOW, and a selection left here signals
        ;; out of the next render (NMX-PANES-1).
        (nerimux::%set-client-selected-tree-object conn pane)
        (expect (null (nerimux::%workspace-prefix-close-pane sess conn)))
        (expect (null (nerimux/pane:pane-window pane)))
        (expect (eq worktree (nerimux::client-conn-selected-tree-object conn)))
        (expect (equal (list :worktree "wt-close")
                       (nerimux/renderer::%workspace-tree-node-key
                        (nerimux::client-conn-selected-tree-object conn)))))))

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

  (it "r8-3-prefix-detach-drops-the-client-after-naming-what-stays-running"
    (with-fake-session (s :nwindows 0)
      (let ((conn (%make-test-conn))
            (parting nil))
        (with-stubbed-fdefinition
            ((nerimux::%send-client-parting
              (lambda (connection text)
                (declare (ignore connection))
                (setf parting text))))
          (expect (eq :drop (nerimux::%workspace-prefix-detach s conn))))
        (expect (search "detached" parting) :to-be-truthy)
        (expect (search "0 panes running" parting) :to-be-truthy))))

  (it "r7-1-repository-fetch-reports-preconditions-and-completion"
    (with-fake-session (s)
      (expect s)
      (let* ((conn (%make-test-conn))
             (organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (nerimux::*workspace-operation-jobs*
               (make-hash-table :test (function equal)))
             (available-p t)
             (fetch-count 0)
             (callbacks nil)
             (sync-failure-p nil)
             (refresh-count 0)
             (messages nil))
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p
               (lambda () available-p))
             (nerimux/vcs:fetch-repository-async
               (lambda (current &rest arguments)
                 (expect (eq repository current))
                 (if sync-failure-p
                     (error "sync failure")
                     (progn
                       (incf fetch-count)
                       (if (= fetch-count 1)
                           (progn
                             (setf callbacks arguments)
                             (funcall (getf arguments :on-accepted)))
                           (funcall (getf arguments :on-complete) nil))))))
             (nerimux::%refresh-client-picker
               (lambda (connection)
                 (declare (ignore connection))
                 (incf refresh-count)))
             (nerimux::%client-notify
               (lambda (connection message)
                 (declare (ignore connection))
                 (push message messages))))
          (nerimux::%workspace-fetch-repository conn)
          (expect (search "selected repository" (first messages)))
          (nerimux::%set-client-selected-tree-object conn repository)
          (setf available-p nil)
          (nerimux::%workspace-fetch-repository conn)
          (expect (search "VCS unavailable" (first messages)))
          (setf available-p t)
          (nerimux::%workspace-fetch-repository conn)
          (let ((job
                  (gethash (list :repository "repo" :fetch)
                           nerimux::*workspace-operation-jobs*)))
            (expect (= 1 fetch-count))
            (expect (functionp (getf callbacks :on-accepted)))
            (expect (functionp (getf callbacks :on-start)))
            (expect (functionp (getf callbacks :on-complete)))
            (expect (functionp (getf callbacks :on-error)))
            (expect job)
            (expect (eq :queued
                        (nerimux::workspace-operation-job-state job)))
            (nerimux::%workspace-fetch-repository conn)
            (expect (= 2 fetch-count))
            (expect (search "already in progress" (first messages)))
            (expect (eq job
                        (gethash (list :repository "repo" :fetch)
                                 nerimux::*workspace-operation-jobs*)))
            (expect (eq :queued
                        (nerimux::workspace-operation-job-state job)))
            (funcall (getf callbacks :on-start))
            (expect (eq :running
                        (nerimux::workspace-operation-job-state job)))
            (funcall (getf callbacks :on-complete) repository)
            (expect (eq :succeeded
                        (nerimux::workspace-operation-job-state job)))
            (expect (= 1 refresh-count))
            (expect (= 1 (count "fetch complete" messages :test (function string=))))
            (funcall (getf callbacks :on-error)
                     (make-condition (quote simple-error)
                                     :format-control "offline"))
            (expect (search "fetch failed" (first messages)))
            (expect (eq :succeeded
                        (nerimux::workspace-operation-job-state job)))
            (setf sync-failure-p t)
            (nerimux::%workspace-fetch-repository conn)
            (expect (search "sync failure" (first messages)))))))) (it "r7-1-organization-fetch-reports-unavailable-and-in-progress"
    (with-fake-session (s)
      (expect s)
      (let* ((conn (%make-test-conn))
             (organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (failed-organization
               (nerimux/workspace-model:make-organization
                :id "failed-org" :host "github.com" :name "failed-team"))
             (failed-repository
               (nerimux/workspace-model:make-repository
                :id "failed-repo" :organization failed-organization
                :specification "github.com/failed-team/failed-repo"))
             (failure
               (make-condition (quote simple-error)
                               :format-control "offline"))
             (nerimux::*workspace-operation-jobs*
               (make-hash-table :test (function equal)))
             (available-p t)
             (fetch-count 0)
             (success-callbacks nil)
             (failure-callbacks nil)
             (sync-failure-p nil)
             (refresh-count 0)
             (messages nil))
        (nerimux/workspace-model:organization-add-repository
         organization repository)
        (nerimux/workspace-model:organization-add-repository
         failed-organization failed-repository)
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p
               (lambda () available-p))
             (nerimux/vcs:fetch-organization-async
               (lambda (current &rest arguments)
                 (if sync-failure-p
                     (error "sync failure")
                     (progn
                       (incf fetch-count)
                       (case fetch-count
                         (1
                          (expect (eq organization current))
                          (setf success-callbacks arguments)
                          (funcall (getf arguments :on-accepted)))
                         (2
                          (expect (eq organization current))
                          (funcall (getf arguments :on-complete) nil))
                         (3
                          (expect (eq failed-organization current))
                          (setf failure-callbacks arguments)
                          (funcall (getf arguments :on-accepted)))
                         (otherwise
                          (error "unexpected fetch invocation")))))))
             (nerimux::%refresh-client-picker
               (lambda (connection)
                 (declare (ignore connection))
                 (incf refresh-count)))
             (nerimux::%client-notify
               (lambda (connection message)
                 (declare (ignore connection))
                 (push message messages))))
          (nerimux::%workspace-fetch-organization conn)
          (expect (search "selected organization" (first messages)))
          (nerimux::%set-client-selected-tree-object conn organization)
          (setf available-p nil)
          (nerimux::%workspace-fetch-organization conn)
          (expect (search "VCS unavailable" (first messages)))
          (setf available-p t)
          (nerimux::%workspace-fetch-organization conn)
          (let ((job
                  (gethash (list :organization "org" :fetch)
                           nerimux::*workspace-operation-jobs*)))
            (expect (= 1 fetch-count))
            (expect (functionp (getf success-callbacks :on-accepted)))
            (expect (functionp (getf success-callbacks :on-start)))
            (expect (functionp (getf success-callbacks :on-complete)))
            (expect (functionp (getf success-callbacks :on-error)))
            (expect job)
            (expect (eq :queued
                        (nerimux::workspace-operation-job-state job)))
            (funcall (getf success-callbacks :on-start))
            (expect (eq :running
                        (nerimux::workspace-operation-job-state job)))
            (funcall (getf success-callbacks :on-complete)
                     (list repository))
            (expect (eq :succeeded
                        (nerimux::workspace-operation-job-state job)))
            (expect (= 1 refresh-count))
            (expect (= 1 (count "fetch complete" messages :test (function string=))))
            (nerimux::%workspace-fetch-organization conn)
            (expect (= 2 fetch-count))
            (expect (search "already in progress" (first messages)))
            (expect (null (gethash (list :organization "org" :fetch)
                                   nerimux::*workspace-operation-jobs*)))
            (expect (eq :succeeded
                        (nerimux::workspace-operation-job-state job))))
          (nerimux::%set-client-selected-tree-object conn failed-organization)
          (nerimux::%workspace-fetch-organization conn)
          (let* ((job
                   (gethash (list :organization "failed-org" :fetch)
                            nerimux::*workspace-operation-jobs*))
                 (refresh-before refresh-count)
                 (complete-before
                   (count "fetch complete" messages :test (function string=))))
            (expect (= 3 fetch-count))
            (expect job)
            (expect (eq :queued
                        (nerimux::workspace-operation-job-state job)))
            (funcall (getf failure-callbacks :on-start))
            (expect (eq :running
                        (nerimux::workspace-operation-job-state job)))
            (funcall (getf failure-callbacks :on-error)
                     failed-repository failure)
            (expect (search "fetch failed for failed-repo" (first messages)))
            (expect (eq :failed
                        (nerimux::workspace-operation-job-state job)))
            (expect (eq failure
                        (nerimux::workspace-operation-job-outcome job)))
            (funcall (getf failure-callbacks :on-complete)
                     (list failed-repository))
            (expect (= refresh-before refresh-count))
            (expect (= complete-before
                       (count "fetch complete" messages :test (function string=))))
            (expect (eq :failed
                        (nerimux::workspace-operation-job-state job)))
            (expect (eq failure
                        (nerimux::workspace-operation-job-outcome job))))
          (setf sync-failure-p t)
          (nerimux::%workspace-fetch-organization conn)
          (expect (search "sync failure" (first messages)))))))

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
              (lambda (connection pane &optional session)
                (declare (ignore connection))
                (declare (ignore session))
                (setf focused-pane pane))))
          (nerimux::%workspace-refocus-after-window-close
           session test-conn worktree)
          (expect (eq newer-window selected-window))
          (expect (eq newer-pane focused-pane)))))
  )
(describe "agent-workspace merge additions"
  (it "r4-4-prefix-w-opens-overview-directly-and-repeatedly-for-the-focused-worktree"
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
          (dolist (view '(:pane :status :repolist))
            (nerimux::%set-client-view conn view)
            (dotimes (iteration 2)
              (declare (ignorable iteration))
              (nerimux::%handle-multi-key-message sess conn #(17))
              (nerimux::%handle-multi-key-message sess conn #(119))
              (expect (eq :repolist (nerimux::client-conn-view conn)))
              (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))
              (expect (eq worktree (nerimux::client-conn-selected-tree-object conn))))))))
  (it "worktree-prefix-overview-create-uses-focused-repository-not-stale-selection"
      (with-minimal-session (pane win sess)
        (declare (ignorable win))
        (let* ((organization
                 (nerimux/workspace-model:make-organization :id "org"))
               (old-repository
                 (nerimux/workspace-model:make-repository
                  :id "old-repo" :organization organization))
               (repository
                 (nerimux/workspace-model:make-repository
                  :id "focused-repo" :organization organization))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "focused-wt" :repository repository
                  :path "/tmp/focused-wt" :branch "main"))
               (conn (%make-test-conn))
               (nerimux::*last-selected-worktree-token* nil)
               (created nil)
               (original (fdefinition 'nerimux/vcs:create-detached-worktree-async)))
          (nerimux/workspace-model:organization-add-repository organization old-repository)
          (nerimux/workspace-model:organization-add-repository organization repository)
          (nerimux/workspace-model:repository-add-worktree repository worktree)
          (nerimux/pane:worktree-add-pane worktree pane)
          (nerimux::%set-client-selected-tree-object conn old-repository)
          (nerimux::%set-client-focus conn pane)
          (expect (eq old-repository (nerimux::client-conn-selected-tree-object conn)))
          (unwind-protect
               (progn
                 (setf (fdefinition 'nerimux/vcs:create-detached-worktree-async)
                       (lambda (target &rest args)
                         (declare (ignore args))
                         (push target created)))
                 (nerimux::%handle-multi-key-message sess conn #(17))
                 (nerimux::%handle-multi-key-message sess conn #(119))
                 (expect (eq :repolist (nerimux::client-conn-view conn)))
                 (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))
                 (expect (eq worktree (nerimux::client-conn-selected-tree-object conn)))
                 (nerimux::%handle-multi-key-message sess conn #(119))
                 (nerimux::%handle-multi-key-message sess conn #(110)))
            (setf (fdefinition 'nerimux/vcs:create-detached-worktree-async) original))
          (expect (equal (list repository) created))
          (expect (null (member old-repository created)))
          (expect (eq repository
                      (nerimux::workspace-assignment-repository
                       (nerimux::client-conn-workspace-assignment conn)))))))
  (it "r4-4-prefix-w-with-no-focused-pane-opens-overview-from-every-view"
      (with-fake-session (sess :nwindows 0)
        (let ((conn (%make-test-conn)))
          (dolist (view '(:pane :status :repolist))
            (nerimux::%set-client-view conn view)
            (nerimux::%handle-multi-key-message sess conn #(17))
            (nerimux::%handle-multi-key-message sess conn #(119))
            (expect (eq :repolist (nerimux::client-conn-view conn)))))))
  (it "prefix-split-starts-reader-for-a-live-new-pane"
      (with-minimal-session (pane window session)
        (let* ((conn (%make-test-conn))
               (new-pane (make-pane :id 2 :fd 42 :pid -1))
               (starts 0))
          (setf (pane-window pane) window
                (pane-window new-pane) window)
          (nerimux::%set-client-focus conn pane)
          (with-stubbed-fdefinition
              ((nerimux/window:window-split
                (lambda (&rest arguments)
                  (declare (ignore arguments))
                  new-pane))
               (nerimux::start-reader-thread
                (lambda (candidate)
                  (when (eq candidate new-pane)
                    (incf starts)))))
            (expect (null (nerimux::%workspace-prefix-split session conn :h))))
          (expect (= 1 starts))
          (expect (eq new-pane (nerimux::client-conn-focus conn)))
          (expect (eq new-pane (window-active-pane window))))))
  (it "prefix-split-does-not-start-reader-for-a-dead-new-pane"
      (with-minimal-session (pane window session)
        (let* ((conn (%make-test-conn))
               (new-pane (make-pane :id 2 :fd -1 :pid -1))
               (starts 0))
          (setf (pane-window pane) window
                (pane-window new-pane) window)
          (nerimux::%set-client-focus conn pane)
          (with-stubbed-fdefinition
              ((nerimux/window:window-split
                (lambda (&rest arguments)
                  (declare (ignore arguments))
                  new-pane))
               (nerimux::start-reader-thread
                (lambda (candidate)
                  (declare (ignore candidate))
                  (incf starts))))
            (expect (null (nerimux::%workspace-prefix-split session conn :h))))
          (expect (= 0 starts))
          (expect (eq new-pane (nerimux::client-conn-focus conn)))
          (expect (eq new-pane (window-active-pane window))))))
  (it "r4-5-prefix-actions-stop-when-a-worktree-attachment-is-pending"
      (with-fake-session (s :nwindows 0)
        (let ((conn (%make-test-conn)))
          (with-stubbed-fdefinition
              ((nerimux::%reject-pending-worktree-attachment
                 (lambda (&rest arguments)
                   (declare (ignore arguments))
                   t)))
            (expect (null (nerimux::%workspace-prefix-split s conn :h)))
            (expect (null (nerimux::%workspace-prefix-close-pane s conn)))
            (expect (null (nerimux::%workspace-prefix-move-focus s conn :right)))))))
  (it "r4-5-prefix-refocus-stops-when-the-next-window-is-pending"
      (with-fake-session (s :nwindows 2)
        (let* ((conn (%make-test-conn))
               (windows (nerimux/session:session-windows s))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "wt" :path "/tmp/wt" :branch "main")))
          (dolist (window windows)
            (nerimux/pane:worktree-add-pane
             worktree
             (nerimux/window:window-active-pane window)))
          (with-stubbed-fdefinition
              ((nerimux::%reject-pending-worktree-attachment
                 (lambda (&rest arguments)
                   (declare (ignore arguments))
                   t)))
            (expect (null
                     (nerimux::%workspace-refocus-after-window-close
                      s conn worktree)))))))
  (it "r5-6-prefix-cycle-stops-when-the-next-window-is-pending"
      (with-fake-session (s :nwindows 2)
        (let* ((conn (%make-test-conn))
               (windows (nerimux/session:session-windows s))
               (worktree
                 (nerimux/workspace-model:make-worktree
                  :id "wt" :path "/tmp/wt" :branch "main")))
          (dolist (window windows)
            (nerimux/pane:worktree-add-pane
             worktree
             (nerimux/window:window-active-pane window)))
          (nerimux::%set-client-focus
           conn
           (nerimux/window:window-active-pane (first windows)))
          (with-stubbed-fdefinition
              ((nerimux::%reject-pending-worktree-attachment
                 (lambda (&rest arguments)
                   (declare (ignore arguments))
                   t)))
            (expect (null (nerimux::%workspace-prefix-cycle-window s conn 1)))))))
  (it "r5-7-prefix-open-overview-steps-out-from-the-status-view"
      (with-fake-session (s :nwindows 0)
        (let ((conn (%make-test-conn)))
          (nerimux::%set-client-view conn :status)
          (expect (null (nerimux::%workspace-prefix-open-overview s conn)))
          (expect (eq :repolist (nerimux::client-conn-view conn))))))
  (it "r7-1-repository-fetch-reports-wrapper-errors"
      (with-fake-session (s)
        (let* ((conn (%make-test-conn))
               (organization
                 (nerimux/workspace-model:make-organization
                  :id "org" :host "github.com" :name "team"))
               (repository
                 (nerimux/workspace-model:make-repository
                  :id "repo" :organization organization
                  :specification "github.com/team/repo"))
               (messages nil))
          (nerimux::%set-client-selected-tree-object conn repository)
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () t))
               (nerimux::%workspace-fetch-repository-async
                 (lambda (&rest args)
                   (declare (ignore args))
                   (error "wrapper failure")))
               (nerimux::%client-notify
                 (lambda (connection message)
                   (declare (ignore connection))
                   (push message messages))))
            (nerimux::%workspace-prefix-fetch-repository conn)
            (expect (search "wrapper failure" (first messages)))))))
  (it "r7-1-organization-fetch-reports-wrapper-errors"
      (with-fake-session (s)
        (let* ((conn (%make-test-conn))
               (organization
                 (nerimux/workspace-model:make-organization
                  :id "org" :host "github.com" :name "team"))
               (messages nil))
          (nerimux::%set-client-selected-tree-object conn organization)
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () t))
               (nerimux::%workspace-fetch-organization-async
                 (lambda (&rest args)
                   (declare (ignore args))
                   (error "organization wrapper failure")))
               (nerimux::%client-notify
                 (lambda (connection message)
                   (declare (ignore connection))
                   (push message messages))))
            (nerimux::%workspace-prefix-fetch-organization conn)
            (expect (search "organization wrapper failure" (first messages)))))))

  (it "nmx-p19-c-q-x-asks-once-before-closing-a-live-pane"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/session:session-windows s)))
             (left (first (nerimux/window:window-panes win)))
             (nerimux::*clients* (list conn))
             (nerimux/ports:*close-pty* (lambda (fd pid)
                                          (declare (ignore fd pid))
                                          nil)))
        (setf (nerimux/pane:pane-fd left) 9999)
        (nerimux::%set-client-focus conn left)
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(120))
        (expect (string= "C-q x again to close"
                         (first (nerimux::client-conn-message-log conn))))
        (expect (member left (nerimux/window:window-panes win) :test #'eq))
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(120))
        (expect (null (member left (nerimux/window:window-panes win) :test #'eq))))))

  (it "nmx-p19-any-other-key-answers-the-pending-c-q-x-with-no"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/session:session-windows s)))
             (left (first (nerimux/window:window-panes win)))
             (nerimux/ports:*close-pty* (lambda (fd pid)
                                          (declare (ignore fd pid))
                                          nil)))
        (setf (nerimux/pane:pane-fd left) 9999)
        (nerimux::%set-client-focus conn left)
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(120))
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(121))
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(120))
        (expect (member left (nerimux/window:window-panes win) :test #'eq)))))

  (it "nmx-p19-a-pane-whose-process-exited-closes-on-the-first-c-q-x"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/session:session-windows s)))
             (left (first (nerimux/window:window-panes win))))
        (setf (nerimux/pane:pane-fd left) -1)
        (nerimux::%set-client-focus conn left)
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(120))
        (expect (null (member left (nerimux/window:window-panes win) :test #'eq))))))
)
