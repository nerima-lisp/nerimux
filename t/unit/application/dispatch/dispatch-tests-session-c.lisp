(in-package #:nerimux/test)

;;;; Options, session management, control mode, and server-lifecycle tests.
;;;;  (dispatch-commands-option.lisp, dispatch-commands-auto.lisp,
;;;;   session-registry.lisp, dispatch-control.lisp, dispatch-handlers.lisp)

(describe "dispatch-suite"

  ;;; ── main-pane-width/height options flow into the main layouts ────────────────

  ;; %apply-named-layout-to-session :main-vertical sizes the main pane from the
  ;; main-pane-width option (read at the nerimux layer, threaded into the model).
  (it "apply-named-layout-main-vertical-reads-main-pane-width-option"
    (with-isolated-options ("main-pane-width" 50)
      (let* ((p0  (make-no-pty-pane 1 0 0 100 30))
             (p1  (make-no-pty-pane 2 0 0 100 30))
             (win (make-window :id 1 :name "w" :width 100 :height 30
                               :panes (list p0 p1)))
             (sess (make-session :id 1 :name "0" :windows (list win))))
        (session-select-window sess win)
        (nerimux::%apply-named-layout-to-session sess :main-vertical)
        (expect (= 50 (pane-width p0))))))

  ;; %apply-named-layout-to-session :main-vertical reads other-pane-width and sizes
  ;; the other panes to it (main pane takes the rest).
  (it "apply-named-layout-main-vertical-reads-other-pane-width-option"
    (with-isolated-options ("other-pane-width" 25)
      (let* ((p0  (make-no-pty-pane 1 0 0 200 30))
             (p1  (make-no-pty-pane 2 0 0 200 30))
             (win (make-window :id 1 :name "w" :width 200 :height 30
                               :panes (list p0 p1)))
             (sess (make-session :id 1 :name "0" :windows (list win))))
        (session-select-window sess win)
        (nerimux::%apply-named-layout-to-session sess :main-vertical)
        (expect (= 25 (pane-width p1))))))

  ;;; ── default-size: detached new-session sizing ────────────────────────────────

  ;; %parse-wxh parses "WxH" into (values W H); rejects malformed input.
  (it "parse-wxh-parses-size-strings"
    (multiple-value-bind (w h) (nerimux::%parse-wxh "80x24")
      (expect (= 80 w)) (expect (= 24 h)))
    (multiple-value-bind (w h) (nerimux::%parse-wxh "100x40")
      (expect (= 100 w)) (expect (= 40 h)))
    (multiple-value-bind (w h) (nerimux::%parse-wxh "junk")
      (expect (null w)) (expect (null h)))
    (multiple-value-bind (w h) (nerimux::%parse-wxh "80x")
      (expect (null w)) (expect (null h))))

  ;; new-session -d with no -x/-y sizes the detached session from the default-size
  ;; option (it has no client to size it), not the current terminal.
  (it "cmd-new-session-detached-uses-default-size"
    (with-isolated-config
      (with-isolated-options ("default-size" "100x40")
        (with-fake-session (s)
          (let* ((nerimux::*server-sessions* nil)
                 (new (nerimux::%cmd-new-session-arg s '("-d" "-s" "bg")))
                 (win (session-active-window new))
                 (expected-height (- 40 nerimux/config:*status-height*)))
            (expect (= 100 (window-width win)))
            (expect (= expected-height (window-height win))))))))

  ;;; ── popup-border-lines: popup box-drawing character set ──────────────────────

  ;; %popup-border-chars returns the box-drawing set for each popup-border-lines
  ;; value; an unknown value falls back to single.
  (it "popup-border-chars-per-style"
    (with-isolated-options ("popup-border-lines" "double")
      (multiple-value-bind (tl tr bl br h) (nerimux::%popup-border-chars)
        (expect (char= #\╔ tl)) (expect (char= #\╗ tr)) (expect (char= #\╚ bl))
        (expect (char= #\╝ br)) (expect (char= #\═ h))))
    (with-isolated-options ("popup-border-lines" "rounded")
      (multiple-value-bind (tl tr bl br h) (nerimux::%popup-border-chars)
        (declare (ignore h))
        (expect (char= #\╭ tl)) (expect (char= #\╮ tr)) (expect (char= #\╰ bl)) (expect (char= #\╯ br))))
    (with-isolated-options ("popup-border-lines" "simple")
      (multiple-value-bind (tl tr bl br h) (nerimux::%popup-border-chars)
        (expect (char= #\+ tl)) (expect (char= #\+ tr)) (expect (char= #\+ bl))
        (expect (char= #\+ br)) (expect (char= #\- h))))
    (with-isolated-options ("popup-border-lines" "bogus")
      (multiple-value-bind (tl tr bl br h) (nerimux::%popup-border-chars)
        (declare (ignore tr bl br h))
        (expect (char= #\┌ tl)))))

  ;; %format-popup-overlay draws the box with the popup-border-lines characters.
  (it "format-popup-overlay-uses-border-lines-option"
    (with-isolated-options ("popup-border-lines" "double")
      (let ((result (nerimux::%format-popup-overlay "t" "body")))
        (expect (search "╔" result))
        (expect (search "╝" result))
        (expect (search "body" result)))))

  ;;; ── %current-session: the standalone loop follows the front session ──────────

  ;; %current-session returns the session with the highest last-active, and falls
  ;; back to its argument when the registry is empty.  This is what makes the
  ;; single-client display follow session-switch commands.
  (it "current-session-follows-most-recently-touched"
    (with-fake-session (s0)
      (let ((s1 (make-fake-session)))
        (with-empty-registry
          (expect (eq s0 (nerimux::%current-session s0))))
        (setf (nerimux::session-last-active s0) 10
              (nerimux::session-last-active s1) 20)
        (with-registered-sessions (("0" s0) ("1" s1))
          (expect (eq s1 (nerimux::%current-session s0)))
          (setf (nerimux::session-last-active s0) 30)
          (expect (eq s0 (nerimux::%current-session s1)))))))

  ;; %switch-to-session(target) makes target the %current-session, so the loop's
  ;; re-resolution displays it (end-to-end switch → display).
  (it "switch-to-session-makes-it-the-current-session"
    (with-fake-session (s0)
      (let ((s1 (make-fake-session)))
        (setf (nerimux::session-last-active s0) 100
              (nerimux::session-last-active s1) 50)
        (with-registered-sessions (("0" s0) ("1" s1))
          (expect (eq s0 (nerimux::%current-session s0)))
          (nerimux::%switch-to-session s1)
          (expect (eq s1 (nerimux::%current-session s0)))))))

  ;;; ── detach-on-destroy: client fate when its session is destroyed ─────────────

  ;; detach-on-destroy on→:quit (detach); off→nil (switch to survivor).
  ;; Each row: (opt-val expected description).
  (it "detach-on-destroy-with-survivors-table"
    (dolist (row '(("on"  :quit "on + survivors → :quit (detach)")
                   ("off" nil   "off + survivors → nil (switch, loop follows)")))
      (destructuring-bind (opt-val expected desc) row
        (declare (ignore desc))
        (with-fake-session (s1)
          (with-isolated-options ("detach-on-destroy" opt-val)
            (with-registered-sessions (("1" s1))
              (expect (eq expected (nerimux::%detach-on-destroy-action "0")))))))))

  ;; With no surviving sessions, detach-on-destroy always detaches (:quit).
  (it "detach-on-destroy-no-survivors-always-quits"
    (with-loop-state
      (with-isolated-options ("detach-on-destroy" "off")
        (with-empty-registry
          (expect (eq :quit (nerimux::%detach-on-destroy-action "0")))))))

  ;; %alphabetical-neighbour finds the next/prev surviving session by name, wrapping.
  (it "alphabetical-neighbour-prev-next-and-wrap"
    (let ((sa (make-fake-session)) (sc (make-fake-session)) (se (make-fake-session)))
      (setf (nerimux::session-name sa) "a"
            (nerimux::session-name sc) "c"
            (nerimux::session-name se) "e")
      (with-registered-sessions (("a" sa) ("c" sc) ("e" se))
        (expect (eq se (nerimux::%alphabetical-neighbour "c"  1)))
        (expect (eq sa (nerimux::%alphabetical-neighbour "c" -1)))
        (expect (eq sa (nerimux::%alphabetical-neighbour "z"  1)))
        (expect (eq se (nerimux::%alphabetical-neighbour "0" -1))))))

  ;; detach-on-destroy next switches to the alphabetically-next surviving session.
  (it "detach-on-destroy-next-switches-to-alphabetical-neighbour"
    (with-fake-session (sa)
      (with-isolated-options ("detach-on-destroy" "next")
        (let ((sc (make-fake-session)))
          (setf (nerimux::session-name sa) "a" (nerimux::session-last-active sa) 5
                (nerimux::session-name sc) "c" (nerimux::session-last-active sc) 5)
          (with-registered-sessions (("a" sa) ("c" sc))
            (expect (null (nerimux::%detach-on-destroy-action "b")))
            (expect (eq sc (nerimux::%current-session sa))))))))

  ;; :kill-session on→:quit (detach); off→nil (switch to survivor).
  ;; Each row: (opt-val expected description).
  (it "dispatch-kill-session-detach-on-destroy-table"
    (dolist (row '(("on"  :quit "on + survivors → :quit (detach)")
                   ("off" nil   "off + survivors → nil (keep running)")))
      (destructuring-bind (opt-val expected desc) row
        (declare (ignore desc))
        (with-fake-session (s1)
          (with-isolated-options ("detach-on-destroy" opt-val)
            (let ((s2 (make-fake-session)))
              (setf (nerimux::session-name s1) "cur" (nerimux::session-name s2) "other")
              (with-registered-sessions (("cur" s1) ("other" s2))
                (expect (eq expected (nerimux::dispatch-command s1 :kill-session nil))))))))))

  ;;; ── destroy-unattached: destroy the session left behind on a switch ──────────

  ;; destroy-unattached off keeps the old session; on destroys it on switch-away.
  ;; Each row: (opt-val expect-a-survives description).
  (it "destroy-unattached-table"
    (dolist (row '((nil t "off: old session survives")
                   (t   nil "on: old session is destroyed")))
      (destructuring-bind (opt-val expect-a-survives desc) row
        (declare (ignore desc))
        (with-fake-session (a)
          (with-isolated-options ("destroy-unattached" opt-val)
            (let ((b (make-fake-session)))
              (setf (nerimux::session-name a) "a" (nerimux::session-last-active a) 20
                    (nerimux::session-name b) "b" (nerimux::session-last-active b) 10)
              (with-registered-sessions (("a" a) ("b" b))
                (nerimux::%switch-to-session b)
                (if expect-a-survives
                    (expect (nerimux::server-find-session "a") :to-be-truthy)
                    (expect (nerimux::server-find-session "a") :to-be-falsy))
                (expect (nerimux::server-find-session "b") :to-be-truthy))))))))

  ;; Switching to the already-current session destroys nothing (old == target).
  (it "destroy-unattached-no-destroy-switching-to-current"
    (with-fake-session (a)
      (with-isolated-options ("destroy-unattached" t)
        (setf (nerimux::session-name a) "a" (nerimux::session-last-active a) 20)
        (with-registered-sessions (("a" a))
          (nerimux::%switch-to-session a)
          (expect (nerimux::server-find-session "a"))))))

  ;;; ── rename-session: registry key + duplicate-name refusal ────────────────────

  ;; %rename-session-checked re-keys *server-sessions* under the new name.
  (it "rename-session-checked-updates-registry-key"
    (with-fake-session (s)
      (setf (nerimux::session-name s) "old")
      (with-registered-sessions (("old" s))
        (expect (eq t (nerimux::%rename-session-checked s "new")))
        (expect (string= "new" (nerimux::session-name s)))
        (expect (eq s (nerimux::server-find-session "new")))
        (expect (null (nerimux::server-find-session "old"))))))

  ;; Renaming onto a name already used by a DIFFERENT session is refused — the other
  ;; session must not be orphaned.
  (it "rename-session-checked-refuses-duplicate-name"
    (with-fake-session (a)
      (let ((b (make-fake-session)))
        (setf (nerimux::session-name a) "a" (nerimux::session-name b) "b")
        (with-registered-sessions (("a" a) ("b" b))
          (expect (null (nerimux::%rename-session-checked a "b")))
          (expect (string= "a" (nerimux::session-name a)))
          (expect (eq b (nerimux::server-find-session "b")))
          (expect (eq a (nerimux::server-find-session "a")))))))

  ;; Renaming a session to its own current name succeeds as a harmless no-op.
  (it "rename-session-checked-to-own-name-noop-success"
    (with-fake-session (s)
      (setf (nerimux::session-name s) "x")
      (with-registered-sessions (("x" s))
        (expect (eq t (nerimux::%rename-session-checked s "x")))
        (expect (eq s (nerimux::server-find-session "x"))))))

  ;; %rename-session-checked fires +hook-session-renamed+ on a successful rename.
  (it "rename-session-checked-fires-hook"
    (with-isolated-hooks
      (with-fake-session (s)
        (let ((fired nil))
          (setf (nerimux::session-name s) "old")
          (nerimux/hooks:add-hook nerimux/hooks:+hook-session-renamed+
                                  (lambda (&rest _) (declare (ignore _)) (setf fired t)))
          (with-registered-sessions (("old" s))
            (nerimux::%rename-session-checked s "new")
            (expect fired :to-be-truthy))))))

  ;;; ── move-window: index collision shifts others up; -a inserts after ──────────

  ;; %window-id-occupied-p and the exclude argument.
  (it "window-id-occupied-and-shuffle-helpers"
    (with-fake-session (s :nwindows 3)
      (let* ((w0 (find 0 (session-windows s) :key #'window-id)))
        (expect (nerimux::%window-id-occupied-p s 1 nil) :to-be-truthy)
        (expect (nerimux::%window-id-occupied-p s 9 nil) :to-be-falsy)
        (expect (nerimux::%window-id-occupied-p s 0 w0) :to-be-falsy))))

  ;; move-window -s W -t N to a free index just reassigns the id.
  (it "move-window-to-free-index"
    (with-fake-session (s :nwindows 2)
      (let* ((w1 (find 1 (session-windows s) :key #'window-id)))
        (nerimux::%cmd-move-window s '("-s" "1" "-t" "5"))
        (expect (= 5 (window-id w1)))
        (expect (find 0 (session-windows s) :key #'window-id)))))

  ;; move-window onto an occupied index shifts the occupants up (no overwrite/no-op).
  (it "move-window-to-occupied-index-shifts-up"
    (with-fake-session (s :nwindows 3)
      (let* ((w0 (find 0 (session-windows s) :key #'window-id))
             (w2 (find 2 (session-windows s) :key #'window-id)))
        (nerimux::%cmd-move-window s '("-s" "2" "-t" "0"))
        (expect (= 0 (window-id w2)))
        (expect (= 1 (window-id w0)))
        (expect (= 3 (length (remove-duplicates (mapcar #'window-id (session-windows s)))))))))

  ;; move-window -a -t N inserts after index N (at N+1), shifting if occupied.
  (it "move-window-a-inserts-after-target"
    (with-fake-session (s :nwindows 3)
      (let* ((w2 (find 2 (session-windows s) :key #'window-id)))
        (nerimux::%cmd-move-window s '("-s" "2" "-a" "-t" "0"))
        (expect (= 1 (window-id w2)))
        (expect (= 3 (length (remove-duplicates (mapcar #'window-id (session-windows s))))))))))
