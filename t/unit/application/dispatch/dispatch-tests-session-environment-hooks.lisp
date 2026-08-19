(in-package #:nerimux/test)

;;;; Dispatch session environment, client size, and hook tests

(describe "dispatch-suite"

  ;;; ── set-environment -h / show-environment -h (hidden variables) ──────────────

  ;; set-environment -h marks a session variable hidden: excluded from the child
  ;; environment and the plain show-environment listing, listed only by -h, and
  ;; unhidden again by a later plain set (tmux ENVIRON_HIDDEN).
  (it "set-environment-h-hides-variable"
    (with-fake-session (s)
      (nerimux::%cmd-set-environment-prompt s '("NERIMUX_VIS" "v1"))
      (nerimux::%cmd-set-environment-prompt s '("-h" "NERIMUX_HID" "secret"))
      ;; Child environment: hidden var excluded, visible var included.
      (let ((child (nerimux/model:session-child-environment s)))
        (expect (notany (lambda (e) (eql 0 (search "NERIMUX_HID=" e))) child))
        (expect (some (lambda (e) (eql 0 (search "NERIMUX_VIS=" e))) child)))
      ;; Plain listing excludes hidden; -h lists only hidden.
      (let ((*overlay* nil))
        (nerimux::%cmd-show-environment-arg s '())
        (expect (null (search "NERIMUX_HID" *overlay*)))
        (expect (search "NERIMUX_VIS" *overlay*)))
      (let ((*overlay* nil))
        (nerimux::%cmd-show-environment-arg s '("-h"))
        (expect (search "NERIMUX_HID" *overlay*))
        (expect (null (search "NERIMUX_VIS" *overlay*))))
      ;; A later plain set unhides.
      (nerimux::%cmd-set-environment-prompt s '("NERIMUX_HID" "public-now"))
      (expect (some (lambda (e) (eql 0 (search "NERIMUX_HID=" e)))
                    (nerimux/model:session-child-environment s)))))

  ;; set-environment -hg marks a GLOBAL variable hidden: stripped from child
  ;; environments even though it lives in the real process environment.
  (it "set-environment-hg-hides-global-variable"
    (with-fake-session (s)
      (let ((nerimux/model:*global-hidden-environment-names* nil))
        (unwind-protect
             (progn
               (nerimux::%cmd-set-environment-prompt
                s '("-h" "-g" "NERIMUX_GHID" "gsecret"))
               (expect (string= "gsecret" (sb-ext:posix-getenv "NERIMUX_GHID")))
               (expect (notany (lambda (e) (eql 0 (search "NERIMUX_GHID=" e)))
                               (nerimux/model:session-child-environment s))))
          (nerimux/model:process-unset-environment "NERIMUX_GHID")))))

  ;;; ── refresh-client -C (client size) ──────────────────────────────────────────

  ;; refresh-client -C WxH updates the client size and relayouts; a malformed or
  ;; absent size leaves the dimensions untouched.
  (it "refresh-client-C-sets-client-size"
    (with-fake-session (s)
      (let ((nerimux::*term-rows* 24)
            (nerimux::*term-cols* 80))
        (nerimux::%cmd-refresh-client-arg s '("-C" "100x40"))
        (expect (= 40 nerimux::*term-rows*))
        (expect (= 100 nerimux::*term-cols*))
        (nerimux::%cmd-refresh-client-arg s '("-C" "garbage"))
        (expect (= 40 nerimux::*term-rows*))
        (nerimux::%cmd-refresh-client-arg s '("-S"))
        (expect (= 100 nerimux::*term-cols*)))))

  ;;; ── set-hook -t (session-scoped hooks) ───────────────────────────────────────

  ;; set-hook -t SESSION scopes the hook: it fires only when the event's derived
  ;; session is the named one (tmux per-target hooks; previously -t was consumed
  ;; and the hook fired globally).
  (it "set-hook-t-scopes-hook-to-named-session"
    (with-isolated-config
     (with-isolated-hooks
      (with-fake-session (alpha)
        (with-fake-session (beta)
          (setf (nerimux/model:session-name alpha) "alpha"
                (nerimux/model:session-name beta)  "beta")
          (let ((*overlay* nil))
            (apply-config-directive
             '("set-hook" "-t" "alpha" "my-scoped-event" "set-option -g @scoped fired"))
            ;; Firing for the OTHER session must not run the hook.
            (nerimux::run-command-hooks "my-scoped-event" beta)
            (expect (null (nerimux/options:get-option "@scoped" nil)))
            ;; Firing for the named session runs it.
            (nerimux::run-command-hooks "my-scoped-event" alpha)
            (expect (string= "fired" (nerimux/options:get-option "@scoped")))
            ;; A global hook (no -t) still fires for any session.
            (apply-config-directive
             '("set-hook" "my-global-event" "set-option -g @global fired"))
            (nerimux::run-command-hooks "my-global-event" beta)
            (expect (string= "fired" (nerimux/options:get-option "@global")))))))))

  ;; set-hook -w -t / -p -t scope hooks to a window/pane id: the hook fires only
  ;; when the event's fire-time target is that object (tmux per-target hooks).
  (it "set-hook-w-and-p-scope-to-object-ids"
    (with-isolated-config
     (with-isolated-hooks
      (with-fake-session (s :nwindows 2)
        (let* ((wins (nerimux/model:session-windows s))
               (w0   (first wins))
               (w1   (second wins))
               (p0   (first (nerimux/model:window-panes w0))))
          ;; %derive-hook-session resolves window/pane targets via the registry.
          (let ((*overlay* nil)
                (nerimux::*server-sessions* (list (cons "s" s))))
            ;; Window scope: fires for that window (or a pane inside it) only.
            (apply-config-directive
             (list "set-hook" "-w" "-t"
                   (format nil "@~D" (nerimux/model:window-id w0))
                   "win-scoped-event" "set-option -g @wscope fired"))
            (nerimux::run-command-hooks "win-scoped-event" w1)
            (expect (null (nerimux/options:get-option "@wscope" nil)))
            (nerimux::run-command-hooks "win-scoped-event" p0)
            (expect (string= "fired" (nerimux/options:get-option "@wscope")))
            ;; Pane scope: fires for that pane only.
            (apply-config-directive
             (list "set-hook" "-p" "-t"
                   (format nil "%~D" (nerimux/model:pane-id p0))
                   "pane-scoped-event" "set-option -g @pscope fired"))
            (nerimux::run-command-hooks "pane-scoped-event" w0)
            (expect (null (nerimux/options:get-option "@pscope" nil)))
            (nerimux::run-command-hooks "pane-scoped-event" p0)
            (expect (string= "fired" (nerimux/options:get-option "@pscope"))))))))))
