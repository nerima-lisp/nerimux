(in-package #:nerimux/test)

;;;; events tests: copy-mode numeric-prefix repeat counts.

(describe "events-suite"

  ;;; ── Copy-mode numeric-prefix repeat counts ───────────────────────────────────
  ;;;
  ;;; %make-copy-mode-digit-k folds digit bytes 1-9 (and 0 once a non-zero
  ;;; prefix has started) into the *copy-mode-prefix-k* continuation; the next
  ;;; non-digit byte resolves the accumulated count (clamped to a minimum of 1)
  ;;; and resets *copy-mode-prefix-k* to NIL.  These end-to-end tests drive the
  ;;; accumulator entirely through process-byte, one byte at a time, matching
  ;;; how real keystrokes arrive.  Mid-sequence, only whether accumulation is
  ;;; still in progress (*copy-mode-prefix-k* non-NIL) is observable from
  ;;; outside the continuation — the accumulated value itself is closed over,
  ;;; not stored anywhere inspectable, so correctness is verified by the final
  ;;; dispatched effect (cursor moves by the right count) rather than by
  ;;; reading an intermediate integer.
  ;;;
  ;;; Every test here pins mode-keys to "vi" via WITH-ISOLATED-CONFIG because
  ;;; numeric prefixes are applied to repeatable entries in the active copy-mode
  ;;; key table.  The emacs table keeps emacs meanings for the same bytes instead
  ;;; of falling through to vi behavior.

  ;; A numeric prefix (e.g. "3j") repeats the following navigation command that
  ;; many times; digits 1-9 always start/continue accumulation.
  (it "copy-mode-numeric-prefix-repeats-scroll-table"
    (with-isolated-config
      (nerimux/options:set-option "mode-keys" "vi")
      (dolist (c (list (list "3j" 0 3 "3j must move the cursor down 3 rows")
                        (list "9j" 0 4 "9j must move the cursor to the viewport bottom")))
        (destructuring-bind (keys start-row expected-row desc) c
          (declare (ignore desc))
          (with-copy-mode-state (s screen input-state)
            (seed-scrollback screen 10)
            (setf (nerimux/terminal/types:screen-copy-cursor screen)
                  (cons start-row 0))
            (loop for ch across keys
                  do (nerimux::process-byte s (char-code ch) input-state))
            (expect (= expected-row
                   (car (nerimux/terminal/types:screen-copy-cursor screen))))
            (expect (null nerimux::*copy-mode-prefix-k*)))))))

  ;; "12j" accumulates a two-digit prefix (1 then 2 -> 12) before dispatching.
  (it "copy-mode-numeric-prefix-multi-digit-accumulates"
    (with-isolated-config
      (nerimux/options:set-option "mode-keys" "vi")
      (with-copy-mode-state (s screen input-state)
        (seed-scrollback screen 20)
        (setf (nerimux/terminal/types:screen-copy-cursor screen) (cons 0 0))
        (nerimux::process-byte s (char-code #\1) input-state)
        (expect (functionp nerimux::*copy-mode-prefix-k*))
        (nerimux::process-byte s (char-code #\2) input-state)
        (expect (functionp nerimux::*copy-mode-prefix-k*))
        (nerimux::process-byte s (char-code #\j) input-state)
        (expect (= 4 (car (nerimux/terminal/types:screen-copy-cursor screen))))
        (expect (null nerimux::*copy-mode-prefix-k*)))))

  ;; A bare '0' (no prior non-zero prefix digit) is the vi 'beginning of line'
  ;; command, not the start of a numeric prefix — matching tmux's vi convention.
  (it "copy-mode-bare-zero-goes-to-line-start-not-accumulated"
    (with-isolated-config
      (nerimux/options:set-option "mode-keys" "vi")
      (with-copy-mode-state (s screen input-state)
        (seed-scrollback screen 10)
        (expect (null nerimux::*copy-mode-prefix-k*))
        (nerimux::process-byte s (char-code #\0) input-state)
        (expect (null nerimux::*copy-mode-prefix-k*)))))

  ;; Once a non-zero digit has started a prefix, a following '0' DOES continue
  ;; the accumulation (vi convention: "10j" means repeat count 10).
  (it "copy-mode-zero-after-nonzero-prefix-is-accumulated"
    (with-isolated-config
      (nerimux/options:set-option "mode-keys" "vi")
      (with-copy-mode-state (s screen input-state)
        (seed-scrollback screen 20)
        (setf (nerimux/terminal/types:screen-copy-cursor screen) (cons 0 0))
        (nerimux::process-byte s (char-code #\1) input-state)
        (expect (functionp nerimux::*copy-mode-prefix-k*))
        (nerimux::process-byte s (char-code #\0) input-state)
        (expect (functionp nerimux::*copy-mode-prefix-k*))
        (nerimux::process-byte s (char-code #\j) input-state)
        (expect (= 4 (car (nerimux/terminal/types:screen-copy-cursor screen))))))))
