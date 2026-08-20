(in-package #:nerimux/test)

;;;; Commands tests — part XIV: copy-mode-begin-selection multi-row, yank, cancel-selection.

(describe "commands-suite"

  ;;; ── copy-mode-begin-selection and copy-mode-yank ────────────────────────────

  ;; copy-mode-begin-selection sets screen-copy-selecting to T and places mark at cursor.
  (it "copy-mode-begin-selection-sets-selecting-flag"
    (let ((s (copy-mode-screen)))
      (setf (nerimux/terminal/types:screen-copy-cursor s) (cons 2 5))
      (nerimux/commands::copy-mode-begin-selection s)
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-truthy)
      (expect (equal (cons 2 5) (nerimux/terminal/types:screen-copy-mark s)))))

  ;; copy-mode-begin-selection is a no-op when copy mode is not active.
  (it "copy-mode-begin-selection-noop-outside-copy-mode"
    (let ((s (make-screen 20 5)))
      ;; Do NOT enter copy mode — screen-copy-mode-p is NIL.
      (nerimux/commands::copy-mode-begin-selection s)
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-falsy)))

  ;; copy-mode-yank copies the selected region to *paste-buffers* and exits copy mode.
  (it "copy-mode-yank-pushes-text-to-paste-buffers"
    ;; Use a small screen so we can predict cell content precisely.
    ;; Feed "hello" to row 0; mark at col 0 row 0, cursor at col 4 row 0.
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (make-screen 20 5)))
        (feed s "hello")
        (nerimux/commands::copy-mode-enter s)
        ;; mark at col 0, cursor at col 5 (exclusive end), both on row 0
        ;; → the copy loop runs col from 0 below 5 → "hello"
        (setf (nerimux/terminal/types:screen-copy-selecting s) t
              (nerimux/terminal/types:screen-copy-mark   s) (cons 0 0)
              (nerimux/terminal/types:screen-copy-cursor s) (cons 0 5))
        (nerimux/commands::copy-mode-yank s)
        ;; Copy mode must be deactivated after yank.
        (expect (screen-copy-mode-p s) :to-be-falsy)
        ;; Selection must be cleared.
        (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-falsy)
        ;; Text must have landed in *paste-buffers*.
        (expect (= 1 (length nerimux/buffer:*paste-buffers*)))
        (let ((yanked (nerimux/buffer:get-paste-buffer 0)))
          (expect (string= "hello" yanked))))))

  ;; With set-clipboard on (tmux default), copy-mode-yank enqueues an OSC 52
  ;; sequence on the screen's clipboard-queue so the renderer copies the selection
  ;; to the host system clipboard.
  (it "copy-mode-yank-enqueues-osc52-when-set-clipboard-on"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (with-isolated-options ("set-clipboard" "on")
        (let ((s (make-screen 20 5)))
          (feed s "hello")
          (nerimux/commands::copy-mode-enter s)
          (setf (nerimux/terminal/types:screen-copy-selecting s) t
                (nerimux/terminal/types:screen-copy-mark   s) (cons 0 0)
                (nerimux/terminal/types:screen-copy-cursor s) (cons 0 5))
          (nerimux/commands::copy-mode-yank s)
          (let ((q (nerimux/terminal/types:screen-clipboard-queue s)))
            (expect (= 1 (length q)))
            (expect (search "]52;c;" (first q)))
            (expect (search "aGVsbG8=" (first q))))))))

  ;; With set-clipboard off, copy-mode-yank does NOT enqueue an OSC 52 sequence.
  (it "copy-mode-yank-no-osc52-when-set-clipboard-off"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (with-isolated-options ("set-clipboard" "off")
        (let ((s (make-screen 20 5)))
          (feed s "hello")
          (nerimux/commands::copy-mode-enter s)
          (setf (nerimux/terminal/types:screen-copy-selecting s) t
                (nerimux/terminal/types:screen-copy-mark   s) (cons 0 0)
                (nerimux/terminal/types:screen-copy-cursor s) (cons 0 5))
          (nerimux/commands::copy-mode-yank s)
          (expect (null (nerimux/terminal/types:screen-clipboard-queue s)))))))

  ;; copy-mode-yank with no active selection does not push to *paste-buffers*.
  (it "copy-mode-yank-noop-when-no-selection"
    (let ((nerimux/buffer:*paste-buffers* nil))
      (let ((s (copy-mode-screen :content "data")))
        ;; Ensure no selection is active.
        (setf (nerimux/terminal/types:screen-copy-selecting s) nil)
        (nerimux/commands::copy-mode-yank s)
        (expect (null nerimux/buffer:*paste-buffers*)))))

  ;; copy-mode-cancel-selection resets mark, cursor, and selecting flag.
  (it "copy-mode-cancel-selection-clears-all-state"
    (let ((s (copy-mode-screen)))
      (setf (nerimux/terminal/types:screen-copy-selecting s) t
            (nerimux/terminal/types:screen-copy-mark      s) (cons 1 2)
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 1 5))
      (nerimux/commands::copy-mode-cancel-selection s)
      (expect (null (nerimux/terminal/types:screen-copy-mark s)))
      (expect (null (nerimux/terminal/types:screen-copy-cursor s)))
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-falsy))))
