(in-package #:nerimux/test)

;;;; Copy-mode mouse entry, indicators, and -X command dispatch cases.

(describe "dispatch-suite"

  ;; copy-mode -M places the copy cursor at the in-flight mouse position and
  ;; begins a selection (the MouseDrag1Pane entry); without a mouse event -M
  ;; enters copy mode normally.
  (it "copy-mode-M-enters-at-mouse-position-with-selection"
    (with-fake-session (s)
      (let* ((win  (nerimux/model:session-active-window s))
             (pane (nerimux/model:window-active-pane win))
             (screen (nerimux/model:pane-screen pane)))
        ;; With a mouse event over the pane: cursor jumps + selection begins.
        (let ((nerimux::*current-mouse-event*
                (list :btn 32 :col 5 :row 2 :release-p nil)))
          (nerimux::%cmd-copy-mode-arg s '("-M"))
          (expect (nerimux/terminal/types:screen-copy-mode-p screen) :to-be-truthy)
          (expect (equal (cons (- 2 (nerimux/model:pane-y pane))
                               (- 5 (nerimux/model:pane-x pane)))
                         (nerimux/terminal/types:screen-copy-cursor screen)))
          (expect (nerimux/terminal/types:screen-copy-selecting screen) :to-be-truthy)
          (nerimux/commands:copy-mode-exit screen))
        ;; Without a mouse event: plain entry, no selection.
        (let ((nerimux::*current-mouse-event* nil))
          (nerimux::%cmd-copy-mode-arg s '("-M"))
          (expect (nerimux/terminal/types:screen-copy-mode-p screen) :to-be-truthy)
          (expect (null (nerimux/terminal/types:screen-copy-selecting screen)))))))

  ;; copy-mode -H suppresses the position indicator for this entry; a later plain
  ;; entry shows it again.
  (it "copy-mode-H-hides-position-indicator"
    (with-fake-session (s)
      (let ((screen (nerimux/model:pane-screen (nerimux/model:session-active-pane s))))
        (nerimux::%cmd-copy-mode-arg s '("-H"))
        (expect (nerimux/terminal/types:screen-copy-hide-position screen) :to-be-truthy)
        (nerimux/commands:copy-mode-exit screen)
        (nerimux::%cmd-copy-mode-arg s '())
        (expect (null (nerimux/terminal/types:screen-copy-hide-position screen))))))

  ;; The newly-added send-keys -X names resolve through the X dispatch tables:
  ;; stop-selection keeps the mark but stops extending; halfpage-down-and-cancel
  ;; and copy-pipe-end-of-line / jump-to-forward are registered.
  (it "copy-mode-x-new-command-names-resolve"
    (with-fake-session (s)
      (let* ((pane   (nerimux/model:session-active-pane s))
             (screen (nerimux/model:pane-screen pane)))
        (nerimux/commands:copy-mode-enter screen)
        (nerimux/commands:copy-mode-begin-selection screen)
        (expect (nerimux/terminal/types:screen-copy-selecting screen) :to-be-truthy)
        (nerimux::%run-command-line s "send-keys -X stop-selection")
        (expect (null (nerimux/terminal/types:screen-copy-selecting screen)))
        (expect (nerimux/terminal/types:screen-copy-mark screen) :to-be-truthy)
        ;; Registration checks for the other names.
        (expect (assoc "halfpage-down-and-cancel"
                       nerimux::*copy-mode-x-commands* :test #'string=)
                :to-be-truthy)
        (expect (find "copy-pipe-end-of-line"
                      nerimux::*send-keys-x-explicit-arg-specs*
                      :key #'first :test #'string=)
                :to-be-truthy)
        (expect (find "jump-to-forward"
                      nerimux::*send-keys-x-explicit-arg-specs*
                      :key #'first :test #'string=)
                :to-be-truthy))))

  ;; send-keys -X toggle-position flips the position-indicator visibility flag.
  (it "copy-mode-toggle-position-flips-indicator-visibility"
    (with-fake-session (s)
      (let ((screen (nerimux/model:pane-screen (nerimux/model:session-active-pane s))))
        (nerimux::%cmd-copy-mode-arg s '())
        (expect (null (nerimux/terminal/types:screen-copy-hide-position screen)))
        (nerimux::%run-command-line s "send-keys -X toggle-position")
        (expect (nerimux/terminal/types:screen-copy-hide-position screen) :to-be-truthy)
        (nerimux::%run-command-line s "send-keys -X toggle-position")
        (expect (null (nerimux/terminal/types:screen-copy-hide-position screen))))))

  ;; OSC 133;A records prompt marks; copy-mode previous-prompt/next-prompt jump
  ;; between them (shell-integration prompt jumping).
  (it "osc-133-prompt-marks-and-copy-mode-prompt-jumps"
    (with-fake-session (s)
      (let* ((pane   (nerimux/model:session-active-pane s))
             (screen (nerimux/model:pane-screen pane)))
        ;; Two prompts: one at row 0, output, one at row 2.
        (nerimux/terminal/emulator:screen-process-bytes
         screen (cl-codec-kit:string-to-octets
                 (format nil "~C]133;A~Cprompt-1~%output~%~C]133;A~Cprompt-2"
                         #\Escape (code-char 7) #\Escape (code-char 7))
                 :encoding :utf-8))
        (expect (= 2 (length (nerimux/terminal/types:screen-prompt-marks screen))))
        (nerimux/commands:copy-mode-enter screen)
        ;; Cursor starts at the bottom; previous-prompt goes to the second
        ;; prompt (row 2), a second one to the first (row 0).
        (nerimux/commands:copy-mode-previous-prompt screen)
        (expect (= 2 (car (nerimux/terminal/types:screen-copy-cursor screen))))
        (nerimux/commands:copy-mode-previous-prompt screen)
        (expect (= 0 (car (nerimux/terminal/types:screen-copy-cursor screen))))
        (nerimux/commands:copy-mode-next-prompt screen)
        (expect (= 2 (car (nerimux/terminal/types:screen-copy-cursor screen))))))))
