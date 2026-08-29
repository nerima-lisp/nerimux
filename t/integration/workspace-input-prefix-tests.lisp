(in-package #:nerimux/test)

;;;; R4: input path and the C-q prefix, driven one byte per
;;;; %handle-multi-key-message call -- the same framing client.lisp's
;;;; %forward-stdin-byte actually produces (one stdin byte -> one msg-key
;;;; frame). §6 of docs/notes/workspace-requirements.md requires at least one
;;;; such byte-stream-driven test per new behaviour, because the arrow-key
;;;; bug this redesign fixes (§2.1) hid behind tests that fed a 3-byte
;;;; payload to the handler directly, bypassing the one-byte-at-a-time
;;;; framing no production client can bypass.
;;;;
;;;; Magit alignment (nerimux-magit-contract.md §1/§5): CLIENT-CONN's MODE and
;;;; VIEW :overview/:detail are gone, replaced by VIEW :repolist/:status/:pane
;;;; and MODAL. Where a key goes when MODAL is NIL is now DERIVED from VIEW
;;;; (%CLIENT-UI-KEYS-P, FR-007) rather than tracked as a separate MODE slot,
;;;; so the old ":detail view + :normal mode" cell this file used to drive
;;;; pane-navigation keys through no longer exists to be constructed: VIEW
;;;; :pane now forwards every byte straight to the shell, unconditionally,
;;;; and pane navigation lives only behind the C-q prefix (§2).

(describe "workspace-input-prefix-suite"

  ;; FR-007 (contract §1): VIEW :pane has no navigation meaning of its own --
  ;; there is no more "normal mode moves panes with bare j/k/h/l" cell; that
  ;; behaviour now lives ONLY behind the C-q prefix (§2's C-q h/j/k/l). A bare
  ;; j/k/h/l byte while a pane has focus must therefore reach the pane's
  ;; screen exactly like any other keystroke, and focus must not move.
  (it "r4-1-pane-view-forwards-bare-j-k-h-l-to-the-shell-instead-of-moving-focus"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/model:session-windows s)))
             (left (first (nerimux/model:window-panes win)))
             (fed nil)
             (orig (fdefinition 'nerimux/model:pane-feed)))
        ;; make-fake-window gives every pane the same rectangle; that no
        ;; longer matters here since no direction lookup is exercised, but a
        ;; real neighbour would make a silent regression to the old move-
        ;; focus behaviour observable too (focus would jump instead of
        ;; staying put).
        (nerimux::%set-client-focus conn left)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/model:pane-feed)
                     (lambda (p bytes) (push (list p bytes) fed) (funcall orig p bytes)))
               (dolist (byte '(108 104 107 106)) ; l h k j
                 (nerimux::%handle-multi-key-message s conn (vector byte))))
          (setf (fdefinition 'nerimux/model:pane-feed) orig))
        (expect (= 4 (length fed)))
        (expect (every (lambda (call) (eq left (first call))) fed))
        (expect (eq left (nerimux::client-conn-focus conn))))))

  ;; R4.1's original guarantee, restated for the new state model: an arrow-
  ;; escape sequence sent the way a real client actually sends it -- ESC,
  ;; then `[`, then `A` as three SEPARATE one-byte messages -- must not be
  ;; reassembled or reinterpreted partway through. Under FR-007 there is no
  ;; (:pane, UI-owns-keys) cell left to leak into: every one of the three
  ;; bytes goes straight to the shell, unconditionally, and no MODAL is
  ;; entered by any of them.
  (it "r4-1-arrow-escape-sequence-one-byte-at-a-time-forwards-every-byte-to-the-pane"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/model:session-windows s)))
             (left (first (nerimux/model:window-panes win)))
             (fed nil)
             (orig (fdefinition 'nerimux/model:pane-feed)))
        (nerimux::%set-client-focus conn left)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/model:pane-feed)
                     (lambda (p bytes) (push (list p bytes) fed) (funcall orig p bytes)))
               (nerimux::%handle-multi-key-message s conn #(27)) ; ESC
               (nerimux::%handle-multi-key-message s conn #(91)) ; [
               (nerimux::%handle-multi-key-message s conn #(65))) ; A
          (setf (fdefinition 'nerimux/model:pane-feed) orig))
        ;; PUSH is newest-first: A, then [, then ESC.
        (expect (equalp (list (list left #(65)) (list left #(91)) (list left #(27)))
                        fed))
        (expect (eq left (nerimux::client-conn-focus conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  ;; R4.2: VIEW :pane has no keyboard exit of its own. ESC is forwarded to
  ;; the focused pane's PTY like any other byte, and the client stays in
  ;; :pane with no MODAL entered -- this is the exact production path that
  ;; used to kick the client out to :normal on the arrow key's leading ESC
  ;; byte (§2.1).
  (it "r4-2-esc-is-forwarded-to-the-pane-in-pane-view-and-view-stays-pane"
    (with-minimal-session (pane win sess)
      (declare (ignore win))
      (setf (nerimux/model:pane-fd pane) 9999) ; "live" without a real PTY
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

  ;; R4.2/FR-008: scrollback (copy-mode's successor) is entered only through
  ;; the C-q [ prefix binding now -- the bare `c` key that used to reach it
  ;; straight from a focused pane is retired (contract §2, "KEYS THAT NO
  ;; LONGER EXIST"; VIEW :pane would just forward it to the shell like any
  ;; other byte, per FR-007). Exit is q only; ESC is a plain unbound byte
  ;; inside scrollback and must not leave it.
  (it "r4-2-scrollback-exits-only-on-q-not-esc"
    (with-minimal-session (pane win sess)
      (declare (ignore win))
      (let* ((conn (%make-test-conn))
             (screen (nerimux/model:pane-screen pane)))
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

  ;; R4.3, restated for the new state model (contract §5, MODAL replacing
  ;; MODE): leaving :command modal via ESC still arms a 2-byte swallow,
  ;; because the client forwards stdin one byte at a time and an arrow key's
  ;; trailing `[`/letter bytes must not land on whatever comes next. 1/3/4
  ;; (the visibility-level keys, contract §2/FR-005) stand in for "a key that
  ;; would visibly do something if it reached dispatch" now that h/j/k/l have
  ;; no meaning at all in :repolist to tell a swallowed byte apart from an
  ;; unbound one.
  (it "r4-3-esc-in-command-modal-swallows-exactly-the-next-two-bytes"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (nerimux::%handle-multi-key-message s conn #(58)) ; :
        (expect (eq :command (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC: cancels + arms swallow(2)
        (expect (null (nerimux::client-conn-modal conn)))
        ;; The next two bytes -- "1" and "3", which would otherwise set the
        ;; visibility level -- are swallowed rather than reaching dispatch.
        (nerimux::%handle-multi-key-message s conn #(49)) ; "1" -- swallowed
        (nerimux::%handle-multi-key-message s conn #(51)) ; "3" -- swallowed
        (expect (= 2 (nerimux::client-conn-visibility-level conn))) ; default, unchanged
        ;; The third byte is no longer swallowed and dispatches normally.
        (nerimux::%handle-multi-key-message s conn #(52)) ; "4" -- live again
        (expect (= 4 (nerimux::client-conn-visibility-level conn))))))

  ;; R4.3: same swallow mechanism from :picker modal. ESC closes the picker
  ;; (and arms the swallow); the following two bytes are discarded before
  ;; they can land in whatever MODAL/VIEW the close left the client in --
  ;; proving the requirement's literal concern ("[A must not leak into the
  ;; search term") even though ESC has already left :picker by the time they
  ;; arrive.
  (it "r4-3-esc-in-picker-modal-swallows-exactly-the-next-two-bytes"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/model:make-worktree
                :id "feature" :repository repository
                :path "/tmp/feature" :branch "feature/ux"))
             (conn (%make-test-conn)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-modal conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization)))
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC: closes + arms swallow(2)
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (string= "" (nerimux::client-conn-picker-query conn)))
        ;; `[` and `A` -- what a real arrow key's trailing bytes look like --
        ;; are swallowed rather than reopening the picker or reaching MODAL nil.
        (nerimux::%handle-multi-key-message s conn #(91))
        (nerimux::%handle-multi-key-message s conn #(65))
        (expect (null (nerimux::client-conn-modal conn))))))

  ;; R4.4: a byte struck right after C-q that the table does not bind is
  ;; discarded -- it must not fall through to the pane the way an unprefixed
  ;; key used to (the old tmux-keytable fallthrough, gone since R1). A
  ;; stdin-target is armed so a leak would be directly observable via
  ;; pane-feed.
  (it "r4-4-prefix-unbound-key-is-discarded-not-forwarded-to-the-pane"
    (with-minimal-session (pane win sess)
      (declare (ignore win))
      (let* ((conn (%make-test-conn))
             (fed nil)
             (orig (fdefinition 'nerimux/model:pane-feed)))
        (setf (nerimux::client-conn-stdin-target conn) pane)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/model:pane-feed)
                     (lambda (p bytes) (push (list p bytes) fed) (funcall orig p bytes)))
               (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
               (expect (nerimux::client-conn-ui-prefix-p conn))
               (nerimux::%handle-multi-key-message sess conn #(101)) ; e: unbound
               (expect (null (nerimux::client-conn-ui-prefix-p conn))
                       )
               (expect (null fed) ))
          (setf (fdefinition 'nerimux/model:pane-feed) orig)))))

  ;; contract §2: C-q F and C-q C-f are REMOVED -- fetch moves to the `f`
  ;; transient, whose own coverage of %WORKSPACE-PREFIX-FETCH-REPOSITORY/
  ;; -ORGANIZATION belongs to the TRANSIENT unit's test file, not here (those
  ;; two functions are unaffected and still exercised directly below by
  ;; r7-1-*). What belongs in THIS file is that the C-q BINDING is gone: both
  ;; bytes must be discarded at the prefix like any other unbound key
  ;; (R4.4's "no fallthrough" rule), routed through the full byte-stream
  ;; entry point with a stdin-target armed so a fallthrough would be directly
  ;; observable via pane-feed -- the same shape as the unbound-key case
  ;; above, since %workspace-prefix-dispatch returning NIL alone cannot tell
  ;; "unbound" apart from "bound to an action that happens to return NIL"
  ;; (h/j/k/l/n/p all do).
  (it "r4-4-prefix-F-and-C-f-are-unbound-now-not-forwarded-to-the-pane"
    (with-minimal-session (pane win sess)
      (declare (ignore win))
      (dolist (byte (list (char-code #\F) 6)) ; F, C-f
        (let* ((conn (%make-test-conn))
               (fed nil)
               (orig (fdefinition 'nerimux/model:pane-feed)))
          (setf (nerimux::client-conn-stdin-target conn) pane)
          (unwind-protect
               (progn
                 (setf (fdefinition 'nerimux/model:pane-feed)
                       (lambda (p bytes) (push (list p bytes) fed) (funcall orig p bytes)))
                 (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
                 (expect (nerimux::client-conn-ui-prefix-p conn))
                 (nerimux::%handle-multi-key-message sess conn (vector byte))
                 (expect (null (nerimux::client-conn-ui-prefix-p conn))))
            (setf (fdefinition 'nerimux/model:pane-feed) orig))
          (expect (null fed))))))

  ;; R4.4: C-q C-q returns to no MODAL, handing the keyboard back to whatever
  ;; VIEW is on screen (FR-007) -- the one prefix action with no pane or
  ;; worktree precondition.
  (it "r4-4-prefix-c-q-c-q-clears-modal"
    (with-minimal-session (pane win sess)
      (declare (ignore pane win))
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-modal conn) :scrollback)
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
        (expect (nerimux::client-conn-ui-prefix-p conn))
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q again
        (expect (null (nerimux::client-conn-ui-prefix-p conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  ;; contract §2, ADDED: C-q w opens the status view for the focused pane's
  ;; worktree, and remembers that worktree as CONN's selected one -- the
  ;; status view (renderer-workspace-status.lisp) renders CLIENT-CONN-
  ;; SELECTED-WORKTREE, not the focus pane directly.
  (it "r4-4-prefix-w-opens-status-view-for-the-focused-worktree"
    (with-minimal-session (pane win sess)
      (declare (ignore win))
      (let* ((organization
               (nerimux/model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/model:make-worktree
                :id "wt" :repository repository
                :path "/tmp/wt" :branch "main"))
             (conn (%make-test-conn)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (nerimux/model:worktree-add-pane worktree pane)
        (nerimux::%set-client-focus conn pane)
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message sess conn #(119)) ; w
        (expect (eq :status (nerimux::client-conn-view conn)))
        (expect (eq worktree (nerimux::client-conn-selected-worktree conn))))))

  ;; contract §2, ADDED: with no pane focused -- or a focused pane whose
  ;; worktree the status view has nothing to render for -- C-q w falls back
  ;; to :repolist instead of notifying and leaving the screen untouched, so
  ;; the key is never a dead end.
  (it "r4-4-prefix-w-with-no-focused-worktree-falls-back-to-repolist"
    (with-minimal-session (pane win sess)
      (declare (ignore pane win))
      (let ((conn (%make-test-conn)))
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message sess conn #(119)) ; w
        (expect (eq :repolist (nerimux::client-conn-view conn))))))

  ;; contract §2, ADDED: C-q [ enters scrollback on the focused pane -- the
  ;; success path; the exit/no-op-ESC behaviour is pinned above by
  ;; r4-2-scrollback-exits-only-on-q-not-esc, so this only needs to cover
  ;; entry and the no-focus report.
  (it "r4-4-prefix-open-bracket-enters-scrollback-on-the-focused-pane"
    (with-minimal-session (pane win sess)
      (declare (ignore win))
      (let ((conn (%make-test-conn)))
        (nerimux::%set-client-focus conn pane)
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message sess conn #(91)) ; [
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p
                 (nerimux/model:pane-screen pane))))))

  (it "r4-4-prefix-open-bracket-with-no-focused-pane-reports-and-stays-unmodal"
    (with-fake-session (s :nwindows 0)
      (let ((conn (%make-test-conn)))
        (nerimux::%handle-multi-key-message s conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message s conn #(91)) ; [
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "r4-4-prefix-dispatch-drops-only-the-explicit-detach-key"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (dolist (byte '(104 106 108 110 70 6))
          (expect (null (nerimux::%workspace-prefix-dispatch s conn byte))))
        (expect (eq :drop
                    (nerimux::%workspace-prefix-dispatch
                     s conn (char-code #\d))))
        (expect (null (nerimux::%workspace-prefix-dispatch s conn 255)))
        (expect (null (nerimux::%workspace-prefix-dispatch s conn :unknown))))))

  (it "r4-5-prefix-actions-report-missing-focus-without-mutating-session"
    (with-fake-session (s :nwindows 0)
      (let ((conn (%make-test-conn)))
        (expect (null (nerimux::%workspace-prefix-split s conn :h)))
        (expect (null (nerimux::%workspace-prefix-close-pane s conn)))
        (expect (null (nerimux::%workspace-prefix-toggle-zoom s conn)))
        (expect (null (nerimux::%workspace-prefix-move-focus s conn :right)))
        (expect (null (nerimux::%workspace-prefix-cycle-window s conn 1)))
        (expect (null (nerimux::client-conn-focus conn)))))))

  (it "r5-6-prefix-unzoom-restores-a-zoomed-window-before-action"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (window (first (nerimux/model:session-windows s))))
        (nerimux::%set-client-focus conn (nerimux/model:window-active-pane window))
        (nerimux/model:window-zoom-toggle window)
        (expect (nerimux/model:window-zoom-p window))
        (nerimux::%workspace-prefix-unzoom window)
        (expect (not (nerimux/model:window-zoom-p window))))))

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
               (let ((organization (nerimux/model:make-organization
                                    :id "org" :host "github.com" :name "team"))
                     (repository nil))
                 (setf repository (nerimux/model:make-repository
                                   :id "repo" :organization organization
                                   :specification "github.com/team/repo"))
                 (nerimux::%set-client-selected-tree-object conn repository)
                 (nerimux::%workspace-prefix-fetch-repository conn)
                 (funcall callback t)
                 (expect refreshed)
                 (expect (search "fetch complete" (first messages)))
                 (funcall error-callback (make-condition 'simple-error
                                                          :format-control "offline"))
                 (expect (search "fetch failed" (first messages)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:fetch-repository-async) fetch
                (fdefinition 'nerimux::%refresh-client-picker) refresh
                (fdefinition 'nerimux::%client-notify) notify)))))

  (it "r7-1-organization-fetch-reports-unavailable-and-in-progress"
    (with-fake-session (s)
      (expect s)
      (let ((conn (%make-test-conn))
            (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
            (fetch (fdefinition 'nerimux/vcs:fetch-organization-async))
            (notify (fdefinition 'nerimux::%client-notify))
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
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:fetch-organization-async)
                     (lambda (organization &key on-complete on-error
                                        callback-dispatch)
                       (declare (ignore organization on-error callback-dispatch))
                       (funcall on-complete nil)))
               (let ((organization (nerimux/model:make-organization
                                    :id "org" :host "github.com" :name "team")))
                 (nerimux::%set-client-selected-tree-object conn organization)
                 (nerimux::%workspace-prefix-fetch-organization conn)
                 (expect (search "already in progress" (first messages)))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:fetch-organization-async) fetch
                (fdefinition 'nerimux::%client-notify) notify)))))
