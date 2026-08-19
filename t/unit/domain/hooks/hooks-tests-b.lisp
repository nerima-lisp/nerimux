(in-package #:nerimux/test)

;;;; hooks tests — part B: command hooks (set-hook directive), set-hook -u,
;;;; list-command-hooks, runtime set-hook, config set-hook -g, show-hooks.

(describe "hooks-suite"

  ;;; ── Command hooks (the `set-hook` directive) ──────────────────────────────────

  ;; set-command-hook registers a command keyword under an event name.
  (it "set-command-hook-stores-keyword"
    (with-isolated-hooks
      (nerimux/hooks:set-command-hook "after-new-window" :next-window)
      (expect (equal '(:next-window) (nerimux/hooks:command-hooks "after-new-window")))))

  ;; set-command-hook REPLACES the event's hook list (tmux set-hook without -a).
  (it "set-command-hook-replaces-existing"
    (with-isolated-hooks
      (nerimux/hooks:set-command-hook "after-new-window" :next-window)
      (nerimux/hooks:set-command-hook "after-new-window" :rename-window)
      (expect (equal '(:rename-window)
                 (nerimux/hooks:command-hooks "after-new-window")))))

  ;; append-command-hook accumulates in registration order (tmux set-hook -a).
  (it "append-command-hook-accumulates-in-order"
    (with-isolated-hooks
      (nerimux/hooks:append-command-hook "after-new-window" :next-window)
      (nerimux/hooks:append-command-hook "after-new-window" :rename-window)
      (expect (equal '(:next-window :rename-window)
                 (nerimux/hooks:command-hooks "after-new-window")))))

  ;; clear-command-hooks removes every command hook for an event.
  (it "clear-command-hooks-removes-all"
    (with-isolated-hooks
      (nerimux/hooks:set-command-hook "after-new-window" :next-window)
      (nerimux/hooks:clear-command-hooks "after-new-window")
      (expect (null (nerimux/hooks:command-hooks "after-new-window")))))

  ;; clear-command-hooks on an event with no registered command hooks is a safe no-op.
  (it "clear-command-hooks-unregistered-event-is-noop"
    (with-isolated-hooks
      (finishes (nerimux/hooks:clear-command-hooks "totally-unknown-event"))
      (finishes (nerimux/hooks:clear-command-hooks "after-new-window"))
      (expect (null (nerimux/hooks:command-hooks "after-new-window")))))

  ;;; ── set-hook -u (unset) directive ────────────────────────────────────────────
  ;;;
  ;;; The `set-hook -u <event>` directive clears every command hook registered for
  ;;; the event (same effect as -r), reverting the event to having no hooks.

  ;; set-hook -u <event> clears the command hooks previously registered for that event.
  (it "set-hook-u-unsets-registered-command-hook"
    (with-isolated-hooks
      (with-isolated-config
        ;; Register a command hook via the config directive.
        (nerimux/config:load-config-from-string "set-hook after-new-window next-window")
        (expect (equal '("next-window") (nerimux/hooks:command-hooks "after-new-window")))
        ;; Now unset it via -u.
        (nerimux/config:load-config-from-string "set-hook -u after-new-window")
        (expect (null (nerimux/hooks:command-hooks "after-new-window"))))))

  ;; The set-hook directive REPLACES the event's hook by default and APPENDS with
  ;; -a (tmux semantics), so a config re-setting the same event does not silently
  ;; accumulate duplicate command runs.
  (it "set-hook-replaces-by-default-and-appends-with-a"
    (with-isolated-hooks
      (with-isolated-config
        (nerimux/config:load-config-from-string "set-hook after-new-window next-window")
        (nerimux/config:load-config-from-string "set-hook after-new-window previous-window")
        (expect (equal '("previous-window") (nerimux/hooks:command-hooks "after-new-window")))
        (nerimux/config:load-config-from-string "set-hook -a after-new-window last-window")
        (expect (equal '("previous-window" "last-window")
                   (nerimux/hooks:command-hooks "after-new-window"))))))

  ;;; ── list-command-hooks ────────────────────────────────────────────────────────

  ;; list-command-hooks returns an alist of (event-name . command-keyword-list)
  ;; for every registered command hook event.
  (it "list-command-hooks-returns-alist"
    (with-isolated-hooks
      (nerimux/hooks:append-command-hook "after-new-window" :next-window)
      (nerimux/hooks:append-command-hook "after-new-window" :rename-window)
      (nerimux/hooks:set-command-hook "pane-exited"      :kill-pane)
      (let ((alist (nerimux/hooks:list-command-hooks)))
        (expect (= 2 (length alist)))
        (let ((nw-entry (assoc "after-new-window" alist :test #'string=))
              (pe-entry (assoc "pane-exited"      alist :test #'string=)))
          (expect (not (null nw-entry)))
          (expect (equal '(:next-window :rename-window) (cdr nw-entry)))
          (expect (not (null pe-entry)))
          (expect (equal '(:kill-pane) (cdr pe-entry)))))))

  ;; list-command-hooks returns NIL on an empty *command-hooks* table.
  (it "list-command-hooks-empty-registry"
    (with-isolated-hooks
      (expect (null (nerimux/hooks:list-command-hooks)))))

  ;; Sorting the result of list-command-hooks does not corrupt *command-hooks*.
  ;; (Ensures the caller — describe-command-hooks — uses copy-list before sorting.)
  (it "list-command-hooks-does-not-mutate-on-sort"
    (with-isolated-hooks
      (nerimux/hooks:set-command-hook "z-event" :next-window)
      (nerimux/hooks:set-command-hook "a-event" :prev-window)
      ;; Sort the result in place (worst-case destructive caller).
      (sort (nerimux/hooks:list-command-hooks) #'string< :key #'car)
      ;; Both events must still be retrievable from the live registry.
      (expect (equal '(:next-window) (nerimux/hooks:command-hooks "z-event")))
      (expect (equal '(:prev-window) (nerimux/hooks:command-hooks "a-event")))))

  ;; set-hook <event> <command> stores the raw command string for later execution.
  (it "set-hook-directive-registers-command-hook"
    (with-isolated-hooks
      (let ((applied (nerimux/config:load-config-from-string
                      "set-hook after-new-window next-window")))
        (expect (= 1 applied))
        ;; Command hooks are stored as raw command strings rather than
        ;; pre-resolved keywords, preserving format expansion and argument
        ;; passing in the stored hook text (the dispatch-layer runner that
        ;; used to execute these strings at fire time has been removed).
        (expect (equal '("next-window") (nerimux/hooks:command-hooks "after-new-window"))))))

  ;; set-hook stores multi-token command strings (e.g. 'display-message #{session_name}').
  (it "set-hook-directive-stores-string-with-args"
    (with-isolated-hooks
      (nerimux/config:load-config-from-string
       "set-hook after-new-window display-message #{session_name}")
      (let ((hooks (nerimux/hooks:command-hooks "after-new-window")))
        (expect (= 1 (length hooks)))
        (expect (stringp (first hooks)))
        (expect (search "display-message" (first hooks))))))

  ;; set-hook stores any command string, even unknown names (validated at fire time).
  (it "set-hook-directive-accepts-any-command-name"
    (with-isolated-hooks
      (nerimux/config:load-config-from-string "set-hook after-new-window no-such-command")
      ;; String is stored and validated at fire time, not at config-load time.
      ;; This matches real tmux behavior where set-hook doesn't validate command names.
      (expect (equal '("no-such-command") (nerimux/hooks:command-hooks "after-new-window")))))

  ;; set-hook -g <event> <cmd> in .tmux.conf registers under EVENT, not "-g"
  ;; (regression: leading flags other than -r/-u were previously taken as the event).
  (it "config-set-hook-g-flag-registers-under-event"
    (with-isolated-hooks
      (nerimux/config:load-config-from-string "set-hook -g after-new-window next-window")
      (expect (equal '("next-window") (nerimux/hooks:command-hooks "after-new-window")))
      (expect (null (nerimux/hooks:command-hooks "-g")))))

  ;;; ── *command-hook-runner* and run-command-hooks-via-runner ───────────────────

  ;; run-command-hooks-via-runner is a safe no-op when *command-hook-runner* is NIL.
  (it "command-hook-runner-nil-is-noop"
    (with-isolated-hooks
      (let ((nerimux/hooks:*command-hook-runner* nil))
        (finishes
          (nerimux/hooks:run-command-hooks-via-runner "after-new-window" nil)
          "run-command-hooks-via-runner with nil runner must not signal"))))

  ;; run-command-hooks-via-runner calls *command-hook-runner* with event-name and session
  ;; when a runner is installed.
  (it "command-hook-runner-installed-is-called"
    (with-isolated-hooks
      (let ((received-event nil)
            (received-session nil))
        (let ((nerimux/hooks:*command-hook-runner*
               (lambda (event session)
                 (setf received-event event
                       received-session session))))
          (nerimux/hooks:run-command-hooks-via-runner "after-new-window" :fake-session)
          (expect (string= "after-new-window" received-event))
          (expect (eq :fake-session received-session))))))

  ;; Setting *command-hook-runner* to NIL still allows lisp-function hooks to run
  ;; normally; only the command-hook dispatch is skipped.
  (it "command-hook-runner-nil-does-not-suppress-lisp-hooks"
    (with-isolated-hooks
      (let ((nerimux/hooks:*command-hook-runner* nil)
            (called nil))
        (nerimux/hooks:add-hook "after-new-window" (lambda () (setf called t)))
        (nerimux/hooks:run-hooks "after-new-window")
        (expect called :to-be-truthy))))

  ;;; ── show-hooks (inspect registered command hooks) ─────────────────────────────

  ;; describe-command-hooks reports the empty state when no command hooks are set.
  (it "describe-command-hooks-empty-message"
    (with-isolated-hooks
      (expect (search "no command hooks" (nerimux/hooks:describe-command-hooks)))))

  ;; describe-command-hooks lists each event and its (downcased) commands.
  (it "describe-command-hooks-lists-registered"
    (with-isolated-hooks
      (nerimux/hooks:set-command-hook "after-new-window" :next-window)
      (let ((desc (nerimux/hooks:describe-command-hooks)))
        (expect (search "after-new-window" desc))
        (expect (search "next-window" desc)))))

  ;; show-overlay opens an overlay with describe-command-hooks' listing, the same
  ;; behavior the deleted :show-hooks dispatch case used to drive.
  (it "show-hooks-opens-overlay"
    (with-isolated-hooks
      (with-clean-overlay
        (nerimux/hooks:set-command-hook "after-new-window" :next-window)
        (show-overlay (nerimux/hooks:describe-command-hooks))
        (assert-overlay-active "show-overlay must open an overlay")
        (expect (search "after-new-window" (or *overlay* "")))))))
