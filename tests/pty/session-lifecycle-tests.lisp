(in-package #:nerimux/pty-test)

;;;; Session lifecycle tests: PTY-backed session / window creation flows.
;;;;
;;;; Moved wholesale from tests/unit/domain/model/session-lifecycle-tests.lisp
;;;; (R9.2): every case here uses WITH-SESSION, i.e. spawns a real PTY-backed
;;;; shell via create-initial-session, so the whole file belongs in
;;;; nerimux/pty-test rather than nerimux/test.  The pty-available-p guards
;;;; are left in place: a real PTY is still not guaranteed inside
;;;; nix run .#test-pty's own sandbox, so this suite must still be able to
;;;; skip cleanly there.
(describe "model-suite"

  ;; ── Session bootstrap ──────────────────────────────────────────────────────

  ;; create-initial-session produces 1 window containing 1 full-width pane.
  (it "initial-session"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      ;; Exactly one window.
      (expect (= 1 (length (session-windows session))))
      (let* ((win   (session-active-window session))
             (panes (window-panes win)))
        ;; Exactly one pane.
        (expect (= 1 (length panes)))
        (let ((pane (first panes)))
          ;; Pane geometry: full width; height shrunk by status-line-count (= 1).
          (expect (= 80 (pane-width  pane)))
          (expect (= 23 (pane-height pane)))
          ;; window-active-pane must return the same pane.
          (expect (eq pane (window-active-pane win)))))))

  ;; ── Adding a second window ─────────────────────────────────────────────────

  ;; session-new-window appends a window and switches the active window.
  (it "session-new-window"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((first-win (session-active-window session)))
        (session-new-window session "2" 23 80)
        ;; Two windows now.
        (expect (= 2 (length (session-windows session))))
        ;; Active window switched to the new one.
        (let ((new-win (session-active-window session)))
          (expect (not (eq first-win new-win)))
          ;; New window starts with exactly one pane.
          (expect (= 1 (length (window-panes new-win))))))))

  ;; ── Selecting a window by reference ───────────────────────────────────────

  ;; session-select-window switches the active window back to an earlier one.
  (it "session-select-window"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((first-win (session-active-window session)))
        (session-new-window session "2" 23 80)
        ;; Sanity: active is now the second window.
        (expect (not (eq first-win (session-active-window session))))
        ;; Select the first window back.
        (session-select-window session first-win)
        (expect (eq first-win (session-active-window session))))))

  ;; ── Window index stability ──────────────────────────────────────────────────

  ;; The first window created by create-initial-session gets id 1 (§1.4 of
  ;; docs/notes/workspace-requirements.md: window / pane numbering starts at 1).
  (it "window-index-starts-at-one"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((win (session-active-window session)))
        (expect (= 1 (window-id win))))))

  ;; session-new-window assigns the lowest free id >= base-index, not
  ;; 1+length.  §1.4 fixes base-index at 1 everywhere the app actually calls
  ;; this (bootstrap/workspace-window.lisp's +first-window-index+), so the
  ;; explicit 1 here mirrors production rather than relying on the function's
  ;; own optional default of 0.
  (it "session-new-window-uses-lowest-free-id"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (with-session (session 24 80)
      (let ((first-win (session-active-window session)))
        (expect (= 1 (window-id first-win)))
        ;; Add a second window; should get id=2.
        (session-new-window session "b" 23 80 1)
        (let* ((wins      (session-windows session))
               (second-win (find 2 wins :key #'window-id)))
          (expect second-win :to-be-truthy)))))

  ;; ── create-initial-session ID counter ───────────────────────────────────────

  ;; create-initial-session increments *session-id-counter* and assigns the new id
  ;; to the session.  Two successive calls yield strictly increasing ids.
  (it "create-initial-session-increments-id-counter"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (let ((before nerimux/session::*session-id-counter*))
      (with-session (sess1 24 80)
        (expect (= (1+ before) (session-id sess1)))
        (expect (= (1+ before) nerimux/session::*session-id-counter*)))))

  ;; create-initial-session sets session-last-active to a non-zero universal time.
  (it "create-initial-session-session-touch-called"
    (unless (pty-available-p)
      (skip "no PTY available (sandboxed environment)"))
    (let ((before (get-universal-time)))
      (with-session (sess 24 80)
        (expect (>= (session-last-active sess) before))))))
