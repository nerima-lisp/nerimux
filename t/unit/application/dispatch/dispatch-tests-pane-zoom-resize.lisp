(in-package #:nerimux/test)

;;;; Pane zoom, navigation, and resize dispatch cases.

(describe "dispatch-suite"

  ;; Pane-navigation commands on a zoomed window unzoom it; the pane-configuring
  ;; select-pane forms leave zoom untouched.
  ;; Each row: (command-line expect-zoomed-after description).
  (it "pane-navigation-unzooms-table"
    (dolist (row '(("select-pane -t %2"    nil "select-pane must pop zoom")
                   ("select-pane -m"       t   "select-pane -m (configure) must keep zoom")
                   ("swap-pane -U"         nil "swap-pane must pop zoom")
                   ("rotate-window"        nil "rotate-window must pop zoom")
                   ("last-pane"            nil "last-pane must pop zoom")))
      (destructuring-bind (command expect-zoomed desc) row
        (declare (ignore desc))
        (with-two-pane-h-session (s win p0 p1)
          (with-command-test-state (s :overlay t)
            ;; Arm last-pane's target and zoom the window.
            (nerimux/model:window-select-pane win p1)
            (nerimux/model:window-select-pane win p0)
            (nerimux/model:window-zoom-toggle win)
            (expect (nerimux/model:window-zoom-p win) :to-be-truthy)
            (nerimux::%run-command-line s command)
            (expect (eq expect-zoomed
                        (and (nerimux/model:window-zoom-p win) t))))))))

  ;; Pane-navigation commands reject the removed -Z flag before
  ;; mutating pane focus/order or zoom state.
  ;; Each row: (command-line description).
  (it "pane-navigation-rejects-z-table"
    (dolist (row '(("select-pane -Z -t %2" "select-pane -Z")
                   ("swap-pane -UZ"        "swap-pane -Z")
                   ("rotate-window -Z"     "rotate-window -Z")
                   ("last-pane -Z"         "last-pane -Z")))
      (destructuring-bind (command desc) row
        (with-two-pane-h-session (s win p0 p1)
          (expect (not (null p1)))
          (let (before-panes)
            (with-command-rejection-state (s
                                            (progn
                                              (nerimux/model:window-zoom-toggle win)
                                              (setf before-panes
                                                    (copy-list (nerimux/model:window-panes win)))
                                              (nerimux::%run-command-line s command))
                                            "unsupported argument"
                                            desc)
              (expect (eq p0 (nerimux/model:window-active-pane win)))
              (expect (equal before-panes (nerimux/model:window-panes win)))
              (expect (nerimux/model:window-zoom-p win) :to-be-truthy)))))))

  ;; The interactive pane-navigation keyword handlers unzoom a zoomed window before
  ;; moving. Previously a zoomed window's single-leaf tree made them no-ops.
  ;; Each row: (command expect-focus-moved description).
  (it "keyboard-pane-navigation-pops-zoom-table"
    (dolist (row '((:select-pane-right t "prefix-arrow must unzoom and move")
                   (:next-pane         t "prefix-o must unzoom and cycle")
                   (:last-pane         t ":last-pane must unzoom and jump")
                   (:swap-pane-forward nil "swap keeps the same active pane")))
      (destructuring-bind (command expect-moved desc) row
        (declare (ignore desc))
        (with-two-pane-h-session (s win p0 p1)
          (with-command-test-state (s :overlay t)
            ;; Arm last-pane's target, focus p0, then zoom.
            (nerimux/model:window-select-pane win p1)
            (nerimux/model:window-select-pane win p0)
            (nerimux/model:window-zoom-toggle win)
            (expect (nerimux/model:window-zoom-p win) :to-be-truthy)
            (nerimux::dispatch-command s command nil)
            (expect (nerimux/model:window-zoom-p win) :to-be-falsy)
            (if expect-moved
                (expect (eq p1 (nerimux/model:window-active-pane win)))
                (expect (eq p0 (nerimux/model:window-active-pane win)))))))))

  ;; resize-pane -T drops the rows below the cursor and pulls rows out of the
  ;; scrollback to refill the screen; the cursor lands on the bottom row.
  (it "resize-pane-T-trims-below-cursor-from-history"
    (with-fake-session (s)
      (let* ((pane   (nerimux/model:session-active-pane s))
             (screen (nerimux/model:pane-screen pane))
             (h      (nerimux/terminal/types:screen-height screen)))
        ;; History: one saved row of 'H' cells (newest).
        (let ((saved (make-array (nerimux/terminal/types:screen-width screen))))
          (dotimes (col (length saved))
            (setf (aref saved col) (nerimux/terminal/types:make-cell :char #\H)))
          (push saved (nerimux/terminal/types:screen-scrollback screen)))
        ;; Visible content: 'A' on row 0, cursor on row 0 -> everything below trims.
        (setf (nerimux/terminal/types:cell-char
               (nerimux/terminal/types:screen-cell screen 0 0)) #\A)
        (setf (nerimux/terminal/types:screen-cursor-y screen) 0)
        (nerimux::%cmd-resize-pane-arg s '("-T"))
        (expect (= (1- h) (nerimux/terminal/types:screen-cursor-y screen)))
        (expect (char= #\A (nerimux/terminal/types:cell-char
                            (nerimux/terminal/types:screen-cell screen 0 (1- h)))))
        (expect (char= #\H (nerimux/terminal/types:cell-char
                            (nerimux/terminal/types:screen-cell screen 0 (- h 2)))))
        (expect (null (nerimux/terminal/types:screen-scrollback screen))))))

  ;; resize-pane -M with an in-flight mouse event on a pane border arms the
  ;; border-drag state used by MouseDrag1Border.
  (it "resize-pane-M-arms-border-drag-state"
    (with-two-pane-h-session (s win p0 p1)
      (with-command-test-state (s :overlay t)
        (let* ((border-col (+ (nerimux/model:pane-x p0)
                              (nerimux/model:pane-width p0)))
               (nerimux::*mouse-drag-state* nil)
               (nerimux::*current-mouse-event*
                 (list :btn 32 :col border-col
                       :row (nerimux/model:pane-y p0) :release-p nil)))
          (nerimux::%cmd-resize-pane-arg s '("-M"))
          (expect nerimux::*mouse-drag-state* :to-be-truthy))
        (let ((nerimux::*mouse-drag-state* nil)
              (nerimux::*current-mouse-event* nil))
          (nerimux::%cmd-resize-pane-arg s '("-M"))
          (expect (null nerimux::*mouse-drag-state*)))))))
