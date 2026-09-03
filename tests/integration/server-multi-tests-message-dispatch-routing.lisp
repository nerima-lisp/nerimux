(in-package #:nerimux/test)

;;;; Server multi-client message dispatch tests.
(describe "server-multi-suite"

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

  ;; A key the workspace UI does not bind (default CONN: modal NIL, view
  ;; :repolist, no stdin-target set) is a no-op: NIL disposition, CONN's
  ;; modal/view unchanged, and -- unlike the deleted tmux-keytable
  ;; fallthrough, which used to write an unprefixed key straight into the
  ;; active pane's pty, and unlike :pane's FR-007 straight-to-shell rule --
  ;; nothing is written to the pane. :repolist/:status DROP an unbound key
  ;; rather than passing it through (contract §5's routing rule).
  (it "multi-handle-unbound-normal-key-is-noop"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (before-modal (nerimux::client-conn-modal conn))
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
        (expect (eq before-modal (nerimux::client-conn-modal conn)))
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

  (it "workspace-prefix-dispatch-has-total-input-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-modal conn) :command)
        (expect (null (nerimux::%workspace-prefix-dispatch s conn :not-a-byte)))
        (expect (null (nerimux::%workspace-prefix-dispatch s conn 255)))
        (expect (eq :command (nerimux::client-conn-modal conn)))
        (expect (null
                 (nerimux::%workspace-prefix-dispatch
                  s conn (nerimux::client-conn-workspace-prefix-code conn))))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq :drop
                    (nerimux::%workspace-prefix-dispatch
                     s conn (char-code #\d)))))))

  ;; Rewritten for the magit-alignment key model (contract §1/§2/§5): `i`/
  ;; :input/:normal and the bare `c` -> copy-mode are retired, so this test
  ;; no longer walks through them. Getting a pane focused with keys already
  ;; routed to it is now a navigation outcome (%set-client-focus, exercised
  ;; by attach-selector-resolution-tests.lisp), not a mode toggle, so this
  ;; test starts by setting VIEW :pane directly, the state `i` used to
  ;; produce. Scrollback is reached with C-q [ straight from :pane -- unlike
  ;; the old `c`, it needs no stop at a UI view first.
  (it "multi-client-ui-keymaps-drive-pane-scrollback-search-and-command"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux::window-active-pane
                    (nerimux::session-active-window s)))
             (screen (nerimux/pane:pane-screen pane))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-focus conn) pane)
        (nerimux/pane:pane-feed
         pane
         (cl-codec-kit:string-to-octets "needle" :encoding :utf-8))
        (nerimux::%set-client-view conn :pane)
        ;; FR-007: :pane has no keyboard exit of its own -- every byte, ESC
        ;; included, is forwarded straight to the shell rather than
        ;; toggling any mode (the retired :input/:normal pair used to).
        (nerimux::%handle-multi-key-message s conn #(105)) ; i -- ordinary input now
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC -- forwarded
        (expect (eq :pane (nerimux::client-conn-view conn)))
        ;; C-q [ (FR-008).
        (nerimux::%handle-multi-key-message s conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message s conn #(91)) ; [
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen))
        (nerimux::%handle-multi-key-message s conn #(47)) ; /
        (expect (eq :command (nerimux::client-conn-modal conn)))
        (expect (string= "search-forward "
                         (nerimux::client-conn-command-buffer conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "needle" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        ;; A search submitted while the screen is still in copy mode returns
        ;; to :scrollback rather than dropping the modal outright
        ;; (%submit-client-search).
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(113)) ; q
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen) :to-be-falsy)
        ;; q only drops the MODAL; VIEW stays :pane (contract §5 -- there is
        ;; no %client-exit-copy-mode transition to also restore a UI view
        ;; anymore). C-q w reaches :repolist here because the focused pane
        ;; carries no worktree (%workspace-prefix-open-status's fallback),
        ;; the "never a dead end" property the old :normal exit used to give.
        (nerimux::%handle-multi-key-message s conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message s conn #(119)) ; w
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (nerimux::%handle-multi-key-message s conn #(58)) ; :
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "detail" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "command-submit-contract-covers-empty-unknown-and-failure"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (original (fdefinition 'nerimux::%handle-client-ui-command)))
        (unwind-protect
             (progn
               (setf nerimux::*clients* (list conn))
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (nerimux::%client-ui-keys-p conn))
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn (cl-codec-kit:string-to-octets "not-a-command"
                                                       :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (string= "unknown command: not-a-command"
                                (first (nerimux::client-conn-message-log conn))))
               (setf (fdefinition 'nerimux::%handle-client-ui-command)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (error "expected command failure")))
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn (cl-codec-kit:string-to-octets "home" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (search "command failed: expected command failure"
                               (first (nerimux::client-conn-message-log conn))))
               (expect (nerimux::%client-ui-keys-p conn)))
          (setf (fdefinition 'nerimux::%handle-client-ui-command) original))))))
