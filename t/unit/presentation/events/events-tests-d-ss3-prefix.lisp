(in-package #:nerimux/test)

;;;; SS3 function keys, prefix function keys, and modified root keys

(describe "events-suite"

  ;;; ── SS3 function keys: ESC O P/Q/R/S (F1-F4), ESC O H/F (Home/End) ───────────

  ;; %ss3-key-name maps the SS3 finals to canonical key names; SS3 arrows and
  ;; unrecognised finals map to NIL (forwarded raw).
  (it "ss3-key-name-maps-f1-through-f4-and-home-end"
    (dolist (c '((#\P "F1") (#\Q "F2") (#\R "F3") (#\S "F4")
                 (#\H "Home") (#\F "End")
                 (#\A nil) (#\Z nil)))
      (destructuring-bind (ch expected) c
        (expect (equal expected (nerimux::%ss3-key-name (char-code ch)))))))

  ;; ESC O does not resolve immediately (it could be F1-F4); the decoder keeps
  ;; accumulating and exposes the partial buffer for the escape-time flush replay.
  (it "ss3-introducer-defers-one-byte-and-tracks-buffer"
    (with-fake-session (s)
      (let ((nerimux::*esc-accum-buffer* nil)
            (state (nerimux::make-input-state)))
        (nerimux::process-byte s 27 state)              ; ESC
        (nerimux::process-byte s (char-code #\O) state) ; O
        (expect (not (eq #'nerimux::%ground-input-state
                     (nerimux::input-state-continuation state))))
        (expect (and nerimux::*esc-accum-buffer*
                 (equalp (coerce (subseq nerimux::*esc-accum-buffer* 0
                                         (fill-pointer nerimux::*esc-accum-buffer*))
                                 'list)
                         '(27 79)))))))

  ;; bind -n F1 fires when ESC O P is fed through the input state machine, and the
  ;; buffer-replay state is cleared once the sequence completes (back to ground).
  (it "ss3-f1-root-binding-fires-from-byte-stream"
    (with-fake-session (s :nwindows 2)
      (let ((nerimux::*esc-accum-buffer* nil)
            (state (nerimux::make-input-state)))
        (key-table-bind "root" "F1" :next-window)
        (unwind-protect
             (progn
               (dolist (byte (list 27 (char-code #\O) (char-code #\P)))
                 (nerimux::process-byte s byte state))
               (expect (eq (second (session-windows s)) (session-active-window s)))
               (expect (eq #'nerimux::%ground-input-state
                       (nerimux::input-state-continuation state)))
               (expect (null nerimux::*esc-accum-buffer*)))
          (let ((tbl (gethash "root" *key-tables*)))
            (when tbl (remhash "F1" tbl)))))))

  ;; An unbound F1 (ESC O P) must not trigger a command and must leave the state
  ;; machine at ground — the raw key is forwarded to the pane for transparency.
  (it "ss3-unbound-f1-does-not-fire-and-returns-to-ground"
    (with-fake-session (s :nwindows 2)
      (let ((nerimux::*esc-accum-buffer* nil)
            (state  (nerimux::make-input-state))
            (before (session-active-window s)))
        (dolist (byte (list 27 (char-code #\O) (char-code #\P)))
          (nerimux::process-byte s byte state))
        (expect (eq before (session-active-window s)))
        (expect (eq #'nerimux::%ground-input-state
                (nerimux::input-state-continuation state))))))

  ;;; ── Prefix-table function keys: C-b then F5 / F1 (bind F5, bind F1) ──────────

  ;; bind F5 next-window fires on C-b then ESC [ 15 ~ — the prefix-table path now
  ;; resolves CSI function keys (previously the multi-digit tilde was swallowed).
  (it "prefix-function-key-csi-binding-fires"
    (with-isolated-config
      (nerimux/config:apply-config-directive '("bind" "F5" "next-window"))
      (with-fake-session (s :nwindows 2)
        (let ((nerimux::*esc-accum-buffer* nil)
              (state (nerimux::make-input-state)))
          ;; C-b (2) then ESC [ 1 5 ~
          (dolist (byte '(2 27 91 49 53 126))
            (nerimux::process-byte s byte state))
          (expect (eq (second (session-windows s)) (session-active-window s)))
          (expect (eq #'nerimux::%ground-input-state
                  (nerimux::input-state-continuation state)))))))

  ;; bind F1 next-window fires on C-b then ESC O P — the prefix-table path now
  ;; resolves the SS3 function-key form too.
  (it "prefix-function-key-ss3-binding-fires"
    (with-isolated-config
      (nerimux/config:apply-config-directive '("bind" "F1" "next-window"))
      (with-fake-session (s :nwindows 2)
        (let ((nerimux::*esc-accum-buffer* nil)
              (state (nerimux::make-input-state)))
          ;; C-b (2) then ESC O P
          (dolist (byte (list 2 27 (char-code #\O) (char-code #\P)))
            (nerimux::process-byte s byte state))
          (expect (eq (second (session-windows s)) (session-active-window s)))))))

  ;; Regression guard: widening the 3-byte branch to accumulate on any digit final
  ;; must not break the plain arrow path — C-b then ESC [ A still selects up.
  (it "prefix-arrow-binding-still-fires-after-digit-change"
    (with-isolated-config
      (nerimux/config:apply-config-directive '("bind" "Up" "next-window"))
      (with-fake-session (s :nwindows 2)
        (let ((nerimux::*esc-accum-buffer* nil)
              (state (nerimux::make-input-state)))
          ;; C-b (2) then ESC [ A
          (dolist (byte (list 2 27 91 (char-code #\A)))
            (nerimux::process-byte s byte state))
          (expect (eq (second (session-windows s)) (session-active-window s)))))))

  ;;; ── Modified function keys & combined-modifier arrows (root bind -n) ─────────

  ;; bind -n C-F5 fires when ESC [ 15 ; 5 ~ (Ctrl+F5) is fed through the machine —
  ;; the modified-function-key form the unmodified path previously dropped.
  (it "modified-function-key-root-binding-fires-from-byte-stream"
    (with-fake-session (s :nwindows 2)
      (let ((nerimux::*esc-accum-buffer* nil)
            (state (nerimux::make-input-state)))
        (key-table-bind "root" "C-F5" :next-window)
        (unwind-protect
             (progn
               ;; ESC [ 1 5 ; 5 ~
               (dolist (byte '(27 91 49 53 59 53 126))
                 (nerimux::process-byte s byte state))
               (expect (eq (second (session-windows s)) (session-active-window s))))
          (let ((tbl (gethash "root" *key-tables*)))
            (when tbl (remhash "C-F5" tbl)))))))

  ;; bind -n C-S-Up fires when ESC [ 1 ; 6 A (Ctrl+Shift+Up) is fed — combined
  ;; modifiers now resolve, matching the CSI-u path's handling of letter keys.
  (it "combined-modifier-arrow-root-binding-fires-from-byte-stream"
    (with-fake-session (s :nwindows 2)
      (let ((nerimux::*esc-accum-buffer* nil)
            (state (nerimux::make-input-state)))
        (key-table-bind "root" "C-S-Up" :next-window)
        (unwind-protect
             (progn
               ;; ESC [ 1 ; 6 A
               (dolist (byte (list 27 91 49 59 54 (char-code #\A)))
                 (nerimux::process-byte s byte state))
               (expect (eq (second (session-windows s)) (session-active-window s))))
          (let ((tbl (gethash "root" *key-tables*)))
            (when tbl (remhash "C-S-Up" tbl))))))))
