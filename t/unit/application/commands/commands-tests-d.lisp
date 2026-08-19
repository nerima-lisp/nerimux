(in-package #:nerimux/test)

;;;; rename-window and resize-pane hooks — part VIII
;;;;
;;;; rename-session, select-pane, select-window, server-access, list-commands,
;;;; list-panes, and customize-mode were all reached only through the deleted
;;;; dispatch layer (%cmd-rename-session, %cmd-select-pane, %cmd-select-window,
;;;; %run-command-line, %cmd-server-access, dispatch-command).  Their hooks
;;;; (+hook-session-renamed+, +hook-after-select-pane+, +hook-after-select-window+,
;;;; +hook-session-window-changed+, +hook-window-pane-changed+) are now fired by
;;;; nothing in surviving src, and *server-access-list* no longer exists at all.
;;;; Only rename-window and resize-pane still fire their hooks directly.

(describe "commands-suite"

  ;;; ── rename-window: fires hook ────────────────────────────────────────────────

  ;; rename-window fires +hook-after-rename-window+ with the window and new name.
  (it "rename-window-fires-after-rename-window-hook"
    (with-isolated-hooks
      (let ((hook-win nil)
            (hook-name nil))
        (nerimux/hooks:add-hook nerimux/hooks:+hook-after-rename-window+
                                (lambda (w n) (setf hook-win w hook-name n)))
        (let ((win (make-window :id 1 :name "old" :width 20 :height 5 :panes nil)))
          (rename-window win "new")
          (expect (eq win hook-win)))
        (expect (stringp hook-name))
        (expect (string= "new" hook-name)))))

  ;; A manual rename-window (default) disables automatic-rename; passing
  ;; :disable-automatic-rename NIL (the auto-rename path) keeps it on.
  (it "rename-window-disable-automatic-rename-flag"
    (let ((win (make-window :id 1 :name "x" :width 20 :height 5 :panes nil)))
      (setf (window-automatic-rename-p win) t)
      (rename-window win "manual")
      (expect (window-automatic-rename-p win) :to-be-falsy)
      (setf (window-automatic-rename-p win) t)
      (rename-window win "auto" :disable-automatic-rename nil)
      (expect (window-automatic-rename-p win) :to-be-truthy)))

  ;; rename-window also fires +hook-window-renamed+ (tmux's window-renamed hook).
  (it "rename-window-fires-window-renamed-hook"
    (with-isolated-hooks
      (let ((fired nil))
        (nerimux/hooks:add-hook nerimux/hooks:+hook-window-renamed+
                                (lambda (&rest _) (declare (ignore _)) (setf fired t)))
        (let ((win (make-window :id 1 :name "old" :width 20 :height 5 :panes nil)))
          (rename-window win "new"))
        (expect fired :to-be-truthy))))

  ;;; ── resize-pane: fires hook ──────────────────────────────────────────────────

  ;; resize-pane fires +hook-after-resize-pane+ (covers both the resize-pane command
  ;; and the C-b H/J/K/L keybind path, which share this function).
  (it "resize-pane-fires-after-resize-pane-hook"
    (with-isolated-hooks
      (with-fake-two-pane-session (s)
        (let* ((win (nerimux/model:session-active-window s))
               (fired nil))
          (nerimux/hooks:add-hook nerimux/hooks:+hook-after-resize-pane+
                                  (lambda (&rest _) (declare (ignore _)) (setf fired t)))
          (resize-pane win :up 2)
          (expect fired :to-be-truthy))))))
