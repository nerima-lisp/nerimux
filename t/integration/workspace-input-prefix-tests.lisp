(in-package #:nerimux/test)

;;;; R4: input path and the C-q prefix, driven one byte per
;;;; %handle-multi-key-message call -- the same framing client.lisp's
;;;; %forward-stdin-byte actually produces (one stdin byte -> one msg-key
;;;; frame). §6 of docs/notes/workspace-requirements.md requires at least one
;;;; such byte-stream-driven test per new behaviour, because the arrow-key
;;;; bug this redesign fixes (§2.1) hid behind tests that fed a 3-byte
;;;; payload to the handler directly, bypassing the one-byte-at-a-time
;;;; framing no production client can bypass.

(describe "workspace-input-prefix-suite"

  ;; R4.1: movement is j/k/h/l only. A 2-pane :h window gives l/h a real
  ;; neighbour to move to; there is no vertical neighbour, so k/j exercise the
  ;; "no pane <direction>" branch instead -- still proof the dispatch wiring
  ;; for all four directions exists, without any 3-byte arrow-escape judgment.
  (it "r4-1-normal-mode-detail-view-moves-with-j-k-h-l-only"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/model:session-windows s)))
             (left (first (nerimux/model:window-panes win)))
             (right (second (nerimux/model:window-panes win))))
        (setf (nerimux::client-conn-view conn) :detail)
        (nerimux::%set-client-focus conn left)
        (nerimux::%handle-multi-key-message s conn #(108)) ; l
        (expect (eq right (nerimux::client-conn-focus conn)))
        (nerimux::%handle-multi-key-message s conn #(104)) ; h
        (expect (eq left (nerimux::client-conn-focus conn)))
        ;; k/j: no vertical neighbour in this layout, so the dispatch reaches
        ;; %client-select-pane-direction and reports "no pane <dir>" rather
        ;; than silently doing nothing or crashing -- proving j/k are wired,
        ;; not merely absent.
        (nerimux::%handle-multi-key-message s conn #(107)) ; k
        (expect (string= "no pane UP" (first (nerimux::client-conn-message-log conn))))
        (nerimux::%handle-multi-key-message s conn #(106)) ; j
        (expect (string= "no pane DOWN" (first (nerimux::client-conn-message-log conn))))
        (expect (eq left (nerimux::client-conn-focus conn)) "k/j did not move focus"))))

  ;; R4.1: an arrow-escape sequence sent the way a real client actually sends
  ;; it -- ESC, then `[`, then `A` as three SEPARATE one-byte messages -- must
  ;; not move focus at all. ESC alone is unbound in :normal mode (dropped);
  ;; `[` and `A` are likewise unbound. This is the direct byte-stream
  ;; counterpart to %client-key-sequence-p's removal: there is no 3-byte
  ;; judgment left anywhere on this path to accidentally re-trigger.
  (it "r4-1-arrow-escape-sequence-one-byte-at-a-time-does-not-move-focus"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/model:session-windows s)))
             (left (first (nerimux/model:window-panes win))))
        (setf (nerimux::client-conn-view conn) :detail)
        (nerimux::%set-client-focus conn left)
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC
        (nerimux::%handle-multi-key-message s conn #(91)) ; [
        (nerimux::%handle-multi-key-message s conn #(65)) ; A
        (expect (eq left (nerimux::client-conn-focus conn)))
        (expect (eq :normal (nerimux::client-conn-mode conn))))))

  ;; R4.2: :input mode has no keyboard exit of its own. ESC is forwarded to
  ;; the focused pane's PTY like any other byte, and the client's mode stays
  ;; :input -- this is the exact production path that used to kick the
  ;; client out to :normal on the arrow key's leading ESC byte (§2.1).
  (it "r4-2-esc-is-forwarded-to-the-pane-in-input-mode-and-mode-stays-input"
    (with-minimal-session (pane win sess)
      (declare (ignore win))
      (setf (nerimux/model:pane-fd pane) 9999) ; "live" without a real PTY
      (let* ((conn (%make-test-conn))
             (writes nil)
             (orig (fdefinition 'nerimux::pty-write)))
        (nerimux::%set-client-focus conn pane)
        (setf (nerimux::client-conn-mode conn) :input)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux::pty-write)
                     (lambda (fd bytes) (push (list fd bytes) writes)))
               (nerimux::%handle-multi-key-message sess conn #(27)))
          (setf (fdefinition 'nerimux::pty-write) orig))
        (expect (equal (list (list 9999 #(27))) writes))
        (expect (eq :input (nerimux::client-conn-mode conn))))))

  ;; R4.2: copy-mode exit is q only; ESC is a plain unbound byte inside
  ;; copy-mode and must not exit it.
  (it "r4-2-copy-mode-exits-only-on-q-not-esc"
    (with-minimal-session (pane win sess)
      (declare (ignore win))
      (let* ((conn (%make-test-conn))
             (screen (nerimux/model:pane-screen pane)))
        (nerimux::%set-client-focus conn pane)
        (nerimux::%handle-multi-key-message sess conn #(99)) ; c: enter copy-mode
        (expect (eq :copy (nerimux::client-conn-mode conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen))
        (nerimux::%handle-multi-key-message sess conn #(27)) ; ESC: no-op
        (expect (eq :copy (nerimux::client-conn-mode conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen))
        (nerimux::%handle-multi-key-message sess conn #(113)) ; q: exits
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen) :to-be-falsy))))

  ;; R4.3: in :command mode, ESC discards exactly the next two bytes -- even
  ;; when those bytes would otherwise be live keys (h/j move focus in
  ;; :detail/:normal) -- and a third byte after the swallow is dispatched
  ;; normally again. This is the mechanism that keeps a real arrow key's
  ;; trailing `[`/letter bytes out of whatever mode ESC leaves the client in.
  (it "r4-3-esc-in-command-mode-swallows-exactly-the-next-two-bytes"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/model:session-windows s)))
             (left (first (nerimux/model:window-panes win)))
             (right (second (nerimux/model:window-panes win))))
        (setf (nerimux::client-conn-view conn) :detail)
        (nerimux::%set-client-focus conn left)
        (nerimux::%handle-multi-key-message s conn #(58)) ; :
        (expect (eq :command (nerimux::client-conn-mode conn)))
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC: cancels + arms swallow(2)
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        ;; Bytes 1 and 2 after ESC are swallowed: h/j would normally move
        ;; focus in :detail/:normal, but neither reaches dispatch here.
        (nerimux::%handle-multi-key-message s conn #(104)) ; h -- swallowed
        (nerimux::%handle-multi-key-message s conn #(106)) ; j -- swallowed
        (expect (eq left (nerimux::client-conn-focus conn)) "both swallowed bytes had no effect")
        ;; Byte 3 is no longer swallowed and dispatches normally.
        (nerimux::%handle-multi-key-message s conn #(108)) ; l -- live again
        (expect (eq right (nerimux::client-conn-focus conn))))))

  ;; R4.3: same swallow mechanism from :picker mode. ESC closes the picker
  ;; (and arms the swallow); the following two bytes are discarded before
  ;; they can land in whatever mode the close left the client in -- proving
  ;; the requirement's literal concern ("[A must not leak into the search
  ;; term") even though ESC has already left :picker by the time they arrive.
  (it "r4-3-esc-in-picker-mode-swallows-exactly-the-next-two-bytes"
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
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization)))
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC: closes + arms swallow(2)
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (expect (string= "" (nerimux::client-conn-picker-query conn)))
        ;; `[` and `A` -- what a real arrow key's trailing bytes look like --
        ;; are swallowed rather than reopening the picker or reaching :normal.
        (nerimux::%handle-multi-key-message s conn #(91))
        (nerimux::%handle-multi-key-message s conn #(65))
        (expect (eq :normal (nerimux::client-conn-mode conn))
                "swallowed: neither byte reopened the picker or acted in :normal"))))

  ;; R4.4: a byte struck right after C-q that the 1.5 table does not bind is
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
                       "the prefix byte was consumed either way")
               (expect (null fed) "the unbound key never reached the pane"))
          (setf (fdefinition 'nerimux/model:pane-feed) orig)))))

  ;; R4.4: C-q C-q returns to :normal -- the one prefix action with no pane
  ;; or worktree precondition.
  (it "r4-4-prefix-c-q-c-q-returns-to-normal-mode"
    (with-minimal-session (pane win sess)
      (declare (ignore pane win))
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-mode conn) :copy)
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q
        (expect (nerimux::client-conn-ui-prefix-p conn))
        (nerimux::%handle-multi-key-message sess conn #(17)) ; C-q again
        (expect (null (nerimux::client-conn-ui-prefix-p conn)))
        (expect (eq :normal (nerimux::client-conn-mode conn)))))))
