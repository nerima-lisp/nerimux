(in-package #:nerimux/test)

;;;; renderer tests — part E: set-cursor-shape in rendered output,
;;;; render-session nil-window, render-panes-borders nil-window, inline style
;;;; blocks, SGR-aware width, background-window bell relay.
;;;;
;;;; R6.5 deleted %status-justify-line/%justify-right/%justify-centre and
;;;; %clamp-status-segment along with the session-name/window-list/clock
;;;; status bar they composed — see renderer-statusbar.lisp and
;;;; renderer-statusbar-workspace-tests.lisp.
;;;;
;;;; §1.1 retired the alert machinery outright: bell-action and visual-bell
;;;; (domain/options, deleted R2.2) are gone, so %emit-bell always writes an
;;;; audible BEL and %discard-background-bells always swallows a background
;;;; window's pending bell without relaying it — see
;;;; renderer-compose-effects.lisp.  %status-style-block-sgr (R2.4) no longer
;;;; parses its BODY argument at all: every #[…] block resets to BASE-SGR
;;;; regardless of content, since there is no config-authored style for a
;;;; non-trivial BODY to mean anything any more — see
;;;; renderer-statusbar-layout.lisp.

(describe "renderer-suite"

  ;;; ── set-cursor-shape in rendered output ──────────────────────────────────────

  ;; render-session-to-string emits the DECSCUSR sequence for the pane cursor shape.
  (it "render-session-emits-cursor-shape"
    (let* ((sess  (make-renderer-test-session 20 5))
           (ap    (session-active-pane sess))
           (sc    (pane-screen ap)))
      ;; Set a non-default cursor shape (2 = steady block)
      (setf (nerimux/terminal/types:screen-cursor-shape sc) 2)
      (let ((out (render-session-to-string sess 6 20)))
        (expect (search (format nil "~C[2 q" #\Escape) out)))))

  ;;; ── render-session-to-string with nil window ────────────────────────────────

  ;; render-session-to-string with a session that has no active window still renders.
  (it "render-session-no-window-produces-output"
    (let* ((sess (make-session :id 1 :name "0" :windows nil)))
      (finishes
        (let ((out (render-session-to-string sess 5 20)))
          (expect (plusp (length out)))))))

  ;;; ── %render-panes-and-borders with nil window ───────────────────────────────

  ;; %render-panes-and-borders with NIL window does not signal.
  (it "render-panes-borders-nil-window-finishes"
    (finishes
      (let ((buf (make-string-output-stream)))
        (nerimux/renderer::%render-panes-and-borders buf nil nil nil nil 80))))

  ;;; ── inline #[attr] style blocks + SGR-aware width (renderer-statusbar) ────────
  ;;;
  ;;; tmux status strings carry inline #[fg=…] style blocks and embedded SGR.  Those
  ;;; sequences are zero-width on screen, so the renderer expands #[…] into SGR and
  ;;; measures width by VISIBLE cells.  %visible-length/%visible-truncate must reduce
  ;;; to LENGTH/SUBSEQ on escape-free input (proven below) so older tests are intact.

  ;; %visible-length equals LENGTH for strings with no escape sequences.
  (it "visible-length-escape-free-equals-length"
    (expect (= 5 (nerimux/renderer::%visible-length "hello")))
    (expect (= 0 (nerimux/renderer::%visible-length "")))
    (expect (= (length "a:b 12:34")
               (nerimux/renderer::%visible-length "a:b 12:34"))))

  ;; %visible-length counts only visible cells, skipping CSI SGR escapes.
  (it "visible-length-skips-sgr-sequences"
    (let ((esc #\Escape))
      (expect (= 2 (nerimux/renderer::%visible-length
                    (format nil "~C[32mhi~C[0m" esc esc))))
      (expect (= 3 (nerimux/renderer::%visible-length
                    (format nil "~C[1;44;97mABC" esc))))))

  ;; %visible-truncate equals SUBSEQ for escape-free strings.
  (it "visible-truncate-escape-free-equals-subseq"
    (check-visible-truncate-cases
     '(("hello" 3  "hel"   "truncate to 3")
       ("hello" 5  "hello" "truncate at exact length")
       ("hello" 99 "hello" "truncate past length -> unchanged")
       ("hello" 0  ""      "truncate to 0 -> empty string"))))

  ;; %visible-truncate copies SGR escapes through without counting them toward N.
  (it "visible-truncate-passes-sgr-through"
    (let* ((esc  #\Escape)
           (in   (format nil "~C[32mABCDE" esc))
           (out  (nerimux/renderer::%visible-truncate in 2)))
      (expect (= 2 (nerimux/renderer::%visible-length out)))
      (expect (search "AB" out))
      (expect (char= esc (char out 0)))))

  ;; %status-style-block-sgr no longer parses BODY at all: an attribute-bearing
  ;; body like "fg=green" resets to BASE-SGR exactly like "default"/"none"/"" do.
  (it "status-style-block-body-ignored-always-resets-to-base"
    (let ((out (nerimux/renderer::%status-style-block-sgr "fg=green" "44;97")))
      (expect (string= (format nil "~C[0;44;97m" #\Escape) out))
      (expect (not (search (format nil "~C[32m" #\Escape) out)))))

  ;; %status-style-block-sgr default/none/empty resets to the base status SGR.
  (it "status-style-block-default-resets-to-base"
    (check-status-style-reset-cases "44;97" '("default" "none" "" "  ")))

  ;; %status-expand-style-blocks returns escape-free / block-free text unchanged.
  (it "status-expand-style-blocks-no-block-unchanged"
    (check-status-expand-unchanged-cases "44;97" '("plain text" " 0 1:1* ")))

  ;; %status-expand-style-blocks turns every #[…] block into the same reset-to-
  ;; base SGR, regardless of the block's body — #[fg=green] no longer differs
  ;; from #[default].
  (it "status-expand-style-blocks-converts-blocks"
    (let* ((esc      #\Escape)
           (out      (nerimux/renderer::%status-expand-style-blocks
                      "#[fg=green]X#[default]Y" "44;97"))
           (expected (format nil "~C[0;44;97mX~C[0;44;97mY" esc esc)))
      (expect (null (search "#[" out)))
      (expect (string= expected out))))

  ;;; ── Background-window bell relay ─────────────────────────────────────────────
  ;;;
  ;;; bell-action (domain/options, deleted R2.2) always resolved to "any" with
  ;;; no config able to set "none"/"other" (suppress relay): §1.1 retires the
  ;;; alert machinery outright, so a background window's pending bell is now
  ;;; always swallowed by %discard-background-bells before the frame is built
  ;;; — see renderer-compose-effects.lisp.

  ;; A pending bell in a non-active window never reaches the rendered frame,
  ;; but is still consumed so it does not ring later when that window becomes active.
  (it "render-session-background-bell-always-swallowed"
    (let* ((sess  (make-fake-session :nwindows 2))
           (win2  (second (nerimux/model:session-windows sess)))
           (pane2 (first (nerimux/model:window-panes win2))))
      (setf (nerimux/terminal/types:screen-bell-pending
             (nerimux/model:pane-screen pane2)) t)
      (let ((out (nerimux/renderer::render-session-to-string sess 5 20)))
        (expect (null (find (code-char 7) out)))
        (expect (null (nerimux/terminal/types:screen-bell-pending
                       (nerimux/model:pane-screen pane2)))))))

  ;; %emit-bell always writes the audible BEL — visual-bell's suppression
  ;; branch is gone with the rest of the alert machinery (§1.1).
  (it "emit-bell-always-audible"
    (let ((out (with-output-to-string (s) (nerimux/renderer::%emit-bell s))))
      (expect (find (code-char 7) out)))))
