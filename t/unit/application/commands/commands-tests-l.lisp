(in-package #:nerimux/test)

;;;; commands tests — part L: copy-mode-begin-line-selection multi-row,
;;;; copy-line right-trim, copy-end-of-line col-0, with-shell-timeout,
;;;; window-after-kill, kill-pane/kill-window hooks, copy-mode-toggle-rectangle,
;;;; copy-mode-append-selection, copy-mode-copy-pipe, rectangle-text, renumber-windows.

(describe "commands-suite"

  ;;; ── copy-mode-begin-line-selection: multi-row window ────────────────────────

  ;; copy-mode-begin-line-selection marks col width-1 on a non-default screen width.
  (it "copy-mode-begin-line-selection-selects-correct-width"
    (let ((s (make-screen 40 5)))
      (nerimux/commands::copy-mode-enter s)
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 2 10))
      (nerimux/commands::copy-mode-begin-line-selection s)
      (expect (= 39 (cdr (nerimux/terminal/types:screen-copy-cursor s))))
      (expect (= 0 (cdr (nerimux/terminal/types:screen-copy-mark s))))))

  ;;; ── copy-mode-copy-line: preserves content without trailing spaces ───────────

  ;; copy-mode-copy-line right-trims trailing spaces before pushing to paste buffer.
  (it "copy-mode-copy-line-right-trims-trailing-spaces"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 20 5)))
        (feed s "hi")          ; "hi" followed by 18 spaces on row 0
        (nerimux/commands::copy-mode-enter s)
        (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 5))
        (nerimux/commands::copy-mode-copy-line s)
        (let ((yanked (nerimux/buffer:get-paste-buffer 0)))
          (expect (and yanked (string= "hi" yanked)))))))

  ;;; ── copy-mode-copy-end-of-line: cursor at column 0 ──────────────────────────

  ;; copy-mode-copy-end-of-line from col 0 copies the full row content.
  (it "copy-mode-copy-end-of-line-from-col-0-copies-entire-row"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 20 5)))
        (feed s "hello world")
        (nerimux/commands::copy-mode-enter s)
        (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 0))
        (nerimux/commands::copy-mode-copy-end-of-line s)
        (let ((yanked (nerimux/buffer:get-paste-buffer 0)))
          (expect (and yanked (search "hello world" yanked)))))))

  ;;; ── with-shell-timeout macro coverage ───────────────────────────────────────

  ;; with-shell-timeout macro returns the result when thunk completes in time.
  (it "with-shell-timeout-returns-result-on-success"
    (let ((result (nerimux/commands::with-shell-timeout (shell 30)
                    (string= "/bin/sh" shell)
                    42)))
      ;; result is the value of the last form in the body
      (expect (= 42 result))))

  ;;; ── %window-after-kill: empty list returns nil ───────────────────────────────

  ;; %window-after-kill with an empty remaining list returns NIL.
  (it "window-after-kill-empty-list-returns-nil"
    (expect (null (nerimux/commands::%window-after-kill nil 5))))

  ;;; ── kill-pane: fires hook ────────────────────────────────────────────────────

  ;; kill-pane fires +hook-after-kill-pane+ with the killed pane.
  (it "kill-pane-fires-after-kill-pane-hook"
    (with-isolated-hooks
      (let ((hooked-pane nil))
        (nerimux/hooks:add-hook nerimux/hooks:+hook-after-kill-pane+
                                (lambda (p) (setf hooked-pane p)))
        (let* ((win  (%vsplit-window 20))
               (p0   (first  (window-panes win)))
               (p1   (second (window-panes win)))
               (sess (make-session :id 1 :name "0" :windows (list win))))
          (session-select-window sess win)
          (window-select-pane win p0)
          (kill-pane sess p1)
          (expect (eq p1 hooked-pane))))))

  ;;; ── kill-window: fires hook ──────────────────────────────────────────────────

  ;; kill-window fires +hook-after-kill-window+ with the killed window.
  (it "kill-window-fires-after-kill-window-hook"
    (with-isolated-hooks
      (let ((hooked-win nil))
        (nerimux/hooks:add-hook nerimux/hooks:+hook-after-kill-window+
                                (lambda (w) (setf hooked-win w)))
        (let* ((p0   (%make-test-pane))
               (w1   (make-window :id 1 :name "a" :width 20 :height 5
                                  :tree (make-layout-leaf p0) :panes (list p0)))
               (w2   (make-window :id 2 :name "b" :width 20 :height 5
                                  :panes (list (%make-test-pane :id 2))))
               (sess (make-session :id 1 :name "0" :windows (list w1 w2))))
          (session-select-window sess w1)
          (kill-window sess w1)
          (expect (eq w1 hooked-win))))))

  ;;; ── copy-mode-toggle-rectangle ───────────────────────────────────────────────

  ;; copy-mode-toggle-rectangle toggles screen-copy-rect-select-p between NIL and T.
  (it "copy-mode-toggle-rectangle-flips-flag"
    (let ((s (copy-mode-screen)))
      (expect (nerimux/terminal/types:screen-copy-rect-select-p s) :to-be-falsy)
      (nerimux/commands::copy-mode-toggle-rectangle s)
      (expect (nerimux/terminal/types:screen-copy-rect-select-p s) :to-be-truthy)
      (nerimux/commands::copy-mode-toggle-rectangle s)
      (expect (nerimux/terminal/types:screen-copy-rect-select-p s) :to-be-falsy)))

  ;; copy-mode-toggle-rectangle does nothing when not in copy mode.
  (it "copy-mode-toggle-rectangle-noop-outside-copy-mode"
    (let ((s (make-screen 20 5)))
      (expect (screen-copy-mode-p s) :to-be-falsy)
      (nerimux/commands::copy-mode-toggle-rectangle s)
      (expect (nerimux/terminal/types:screen-copy-rect-select-p s) :to-be-falsy)))

  ;; copy-mode-exit clears screen-copy-rect-select-p.
  (it "copy-mode-exit-resets-rect-select"
    (let ((s (copy-mode-screen)))
      (setf (nerimux/terminal/types:screen-copy-rect-select-p s) t)
      (nerimux/commands::copy-mode-exit s)
      (expect (nerimux/terminal/types:screen-copy-rect-select-p s) :to-be-falsy)))

  ;;; ── copy-mode-append-selection ───────────────────────────────────────────────

  ;; copy-mode-append-selection appends selected text to the current paste buffer entry.
  (it "copy-mode-append-selection-appends-to-existing-buffer"
    (let ((nerimux/buffer:*paste-buffers* nil))
      ;; Seed a buffer entry.
      (nerimux/buffer:add-paste-buffer "hello")
      (let ((s (make-screen 20 5)))
        (feed s " world")
        (nerimux/commands::copy-mode-enter s)
        ;; Manually set a selection spanning " world" on row 0.
        (setf (nerimux/terminal/types:screen-copy-selecting s) t
              (nerimux/terminal/types:screen-copy-mark      s) (cons 0 0)
              (nerimux/terminal/types:screen-copy-cursor    s) (cons 0 6))
        (nerimux/commands::copy-mode-append-selection s)
        ;; Exactly one buffer entry (appended, not pushed).
        (expect (= 1 (length nerimux/buffer:*paste-buffers*)))
        (let ((buf (nerimux/buffer:get-paste-buffer 0)))
          (expect (and (stringp buf) (search "hello" buf)))
          (expect (and (stringp buf) (search " world" buf)))))))

  ;; copy-mode-append-selection pushes a new entry when the paste buffer is empty.
  (it "copy-mode-append-selection-creates-new-entry-when-empty"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 20 5)))
        (feed s "hello")
        (nerimux/commands::copy-mode-enter s)
        (setf (nerimux/terminal/types:screen-copy-selecting s) t
              (nerimux/terminal/types:screen-copy-mark      s) (cons 0 0)
              (nerimux/terminal/types:screen-copy-cursor    s) (cons 0 5))
        (nerimux/commands::copy-mode-append-selection s)
        (expect (= 1 (length nerimux/buffer:*paste-buffers*)))
        (expect (string= "hello" (nerimux/buffer:get-paste-buffer 0))))))

  ;; copy-mode-append-selection must NOT exit copy mode (tmux append-selection stays in copy mode).
  (it "copy-mode-append-selection-stays-in-copy-mode"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 20 5)))
        (feed s "hello")
        (nerimux/commands::copy-mode-enter s)
        (setf (nerimux/terminal/types:screen-copy-selecting s) t
              (nerimux/terminal/types:screen-copy-mark      s) (cons 0 0)
              (nerimux/terminal/types:screen-copy-cursor    s) (cons 0 5))
        (nerimux/commands::copy-mode-append-selection s)
        (expect (nerimux/terminal/types:screen-copy-mode-p s)))))

  ;; copy-mode-append-selection-and-cancel exits copy mode after appending.
  (it "copy-mode-append-selection-and-cancel-exits-copy-mode"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 20 5)))
        (feed s "hello")
        (nerimux/commands::copy-mode-enter s)
        (setf (nerimux/terminal/types:screen-copy-selecting s) t
              (nerimux/terminal/types:screen-copy-mark      s) (cons 0 0)
              (nerimux/terminal/types:screen-copy-cursor    s) (cons 0 5))
        (nerimux/commands::copy-mode-append-selection-and-cancel s)
        (expect (not (nerimux/terminal/types:screen-copy-mode-p s)))
        (expect (string= "hello" (nerimux/buffer:get-paste-buffer 0))))))

  ;;; ── copy-mode-copy-pipe ──────────────────────────────────────────────────────

  ;; copy-mode-copy-pipe adds the selected text to the paste buffer.
  (it "copy-mode-copy-pipe-puts-text-in-paste-buffer"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 20 5)))
        (feed s "pipe-me")
        (nerimux/commands::copy-mode-enter s)
        (setf (nerimux/terminal/types:screen-copy-selecting s) t
              (nerimux/terminal/types:screen-copy-mark      s) (cons 0 0)
              (nerimux/terminal/types:screen-copy-cursor    s) (cons 0 7))
        ;; Pass an empty CMD so only the buffer side runs (no real shell invoked).
        (nerimux/commands::copy-mode-copy-pipe s "")
        (expect (= 1 (length nerimux/buffer:*paste-buffers*)))
        (expect (string= "pipe-me" (nerimux/buffer:get-paste-buffer 0))))))

  ;; copy-mode-copy-pipe exits copy mode after yanking.
  (it "copy-mode-copy-pipe-exits-copy-mode"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 20 5)))
        (feed s "data")
        (nerimux/commands::copy-mode-enter s)
        (setf (nerimux/terminal/types:screen-copy-selecting s) t
              (nerimux/terminal/types:screen-copy-mark      s) (cons 0 0)
              (nerimux/terminal/types:screen-copy-cursor    s) (cons 0 4))
        (nerimux/commands::copy-mode-copy-pipe s "")
        (expect (screen-copy-mode-p s) :to-be-falsy))))

  ;; copy-mode-copy-pipe-end-of-line copies from cursor to EOL and exits copy mode.
  (it "copy-mode-copy-pipe-end-of-line-puts-row-tail-in-paste-buffer"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 20 5)))
        (feed s "hello world")
        (nerimux/commands::copy-mode-enter s)
        (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 0 6))
        (nerimux/commands::copy-mode-copy-pipe-end-of-line s "")
        (expect (= 1 (length nerimux/buffer:*paste-buffers*)))
        (expect (string= "world" (nerimux/buffer:get-paste-buffer 0)))
        (expect (screen-copy-mode-p s) :to-be-falsy))))

  ;; copy-mode-copy-pipe-end-of-line does nothing outside copy mode.
  (it "copy-mode-copy-pipe-end-of-line-noop-outside-copy-mode"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 20 5)))
        (feed s "hello")
        (nerimux/commands::copy-mode-copy-pipe-end-of-line s "")
        (expect (null nerimux/buffer:*paste-buffers*))
        (expect (screen-copy-mode-p s) :to-be-falsy))))

  ;;; ── rectangle selection text ─────────────────────────────────────────────────

  ;; When rect-select is T, yank uses column bounds from mark and cursor on every row.
  (it "copy-mode-yank-rectangle-uses-fixed-columns"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 10 5)))
        ;; Write row 0 "abcde" and row 1 "ABCDE" using CR+LF to ensure row 1 starts at col 0.
        (feed s (format nil "abcde~C~CABCDE" #\Return #\Linefeed))
        (nerimux/commands::copy-mode-enter s)
        ;; Rectangle col 1-3, rows 0-1.
        ;; %extract-row-chars from-col=1 to-col=3 → 2 chars at cols 1 and 2.
        ;; Row 0: "bc"; row 1: "BC".
        (setf (nerimux/terminal/types:screen-copy-rect-select-p s) t
              (nerimux/terminal/types:screen-copy-selecting s) t
              (nerimux/terminal/types:screen-copy-mark      s) (cons 0 1)
              (nerimux/terminal/types:screen-copy-cursor    s) (cons 1 3))
        (nerimux/commands::copy-mode-yank s)
        (let ((buf (nerimux/buffer:get-paste-buffer 0)))
          (expect (and (stringp buf) (search "bc" buf)))
          (expect (and (stringp buf) (search "BC" buf)))))))

  ;;; ── renumber-windows option ───────────────────────────────────────────────────

  ;; kill-window renumbers remaining windows from base-index when renumber-windows is on.
  (it "renumber-windows-renumbers-after-kill"
    (let ((nerimux/options:*global-options*
           (let ((h (make-hash-table :test #'equal)))
             (setf (gethash "renumber-windows" h) t
                   (gethash "base-index"       h) 0)
             h)))
      (let* ((s    (make-fake-session :nwindows 3))
             (wins (nerimux/model:session-windows s))
             ;; Manually give them non-contiguous IDs as if gaps already existed.
             (_ (setf (nerimux/model:window-id (first  wins)) 1
                      (nerimux/model:window-id (second wins)) 3
                      (nerimux/model:window-id (third  wins)) 5))
             ;; Kill the first window (id=1); remaining are 3 and 5.
             (_2 (kill-window s (first wins))))
        (declare (ignore _ _2))
        (let ((ids (mapcar #'nerimux/model:window-id (nerimux/model:session-windows s))))
          (expect (equal '(0 1) ids))))))

  ;; kill-window does not renumber windows when renumber-windows is off.
  (it "renumber-windows-off-preserves-ids"
    (let ((nerimux/options:*global-options*
           (let ((h (make-hash-table :test #'equal)))
             (setf (gethash "renumber-windows" h) nil)
             h)))
      (let* ((s    (make-fake-session :nwindows 3))
             (wins (nerimux/model:session-windows s))
             (_ (setf (nerimux/model:window-id (first  wins)) 1
                      (nerimux/model:window-id (second wins)) 3
                      (nerimux/model:window-id (third  wins)) 5))
             (_2 (kill-window s (first wins))))
        (declare (ignore _ _2))
        (let ((ids (mapcar #'nerimux/model:window-id (nerimux/model:session-windows s))))
          (expect (equal '(3 5) ids)))))))
