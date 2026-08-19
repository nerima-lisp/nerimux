(in-package #:nerimux/test)

;;;; Popup and menu dispatch runtime tests.

(describe "dispatch-suite"

  ;; ── %format-popup-overlay helper ─────────────────────────────────────────────

  ;; %format-popup-overlay produces a box-drawing overlay string.
  (it "format-popup-overlay-produces-box"
    (let ((result (nerimux::%format-popup-overlay "test" "body-text")))
      (expect (stringp result))
      (expect (search "test" result))
      (expect (search "body-text" result))
      (expect (search "┌" result))
      (expect (search "└" result))))

  ;; %format-popup-overlay with NIL output substitutes an empty string.
  (it "format-popup-overlay-nil-output-uses-empty-string"
    (let ((result (nerimux::%format-popup-overlay "cmd" nil)))
      (expect (stringp result))
      (expect (search "cmd" result))))

  ;; ── Popup and buffer-preview positive-constant checks ────────────────────────

  ;; Popup dimension and buffer-preview constants must all be positive.
  (it "popup-and-buffer-preview-constants-positive-table"
    (dolist (row (list (list nerimux::+popup-max-width+      "+popup-max-width+")
                       (list nerimux::+popup-max-height+     "+popup-max-height+")
                       (list nerimux::+popup-margin+         "+popup-margin+")
                       (list nerimux::+buffer-preview-length+ "+buffer-preview-length+")))
      (destructuring-bind (val name) row
        (declare (ignore name))
        (expect (> val 0)))))

  ;; ── :display-popup dispatch ──────────────────────────────────────────────────

  ;; :display-popup opens a prompt for the shell command.
  (it "dispatch-display-popup-opens-prompt"
    (with-fake-session (s)
      (let ((*prompt* nil))
        (nerimux::dispatch-command s :display-popup nil)
        (expect (prompt-active-p))
        (expect (string= "popup command" (prompt-label *prompt*))))))

  ;; :display-popup-dismiss clears *active-popup*.
  (it "dispatch-display-popup-dismiss-clears-popup"
    (with-fake-session (s)
      (setf nerimux::*active-popup*
            (make-popup :title "t" :width 40 :height 10 :screen nil :pane nil))
      (nerimux::dispatch-command s :display-popup-dismiss nil)
      (expect (null nerimux::*active-popup*))))

  ;; ── :display-menu / :menu-next / :menu-prev / :menu-select / :menu-dismiss ──

  ;; :display-menu sets *active-menu* and opens an overlay.
  (it "dispatch-display-menu-opens-menu-and-overlay"
    (with-fake-session (s)
      (let ((*overlay* nil)
            (nerimux::*active-menu* nil))
        (nerimux::dispatch-command s :display-menu nil)
        (expect (not (null nerimux::*active-menu*)))
        (assert-overlay-active ":display-menu must open an overlay"))))

  ;; display-menu -x/-y stores the position on the menu struct (default NIL = centred).
  (it "cmd-display-menu-x-y-sets-menu-position"
    (with-fake-session (s)
      (let ((*overlay* nil)
            (nerimux::*active-menu* nil))
        (nerimux::%cmd-display-menu-arg
         s '("-x" "10" "-y" "5" "Item" "a" "next-window"))
        (expect (not (null nerimux::*active-menu*)))
        (expect (= 10 (nerimux/prompt:menu-x nerimux::*active-menu*)))
        (expect (= 5 (nerimux/prompt:menu-y nerimux::*active-menu*))))))

  ;; display-menu without -x/-y leaves menu-x/menu-y NIL (centred default).
  (it "cmd-display-menu-no-x-y-is-centered"
    (with-fake-session (s)
      (let ((*overlay* nil)
            (nerimux::*active-menu* nil))
        (nerimux::%cmd-display-menu-arg s '("Item" "a" "next-window"))
        (expect (not (null nerimux::*active-menu*)))
        (expect (null (nerimux/prompt:menu-x nerimux::*active-menu*)))
        (expect (null (nerimux/prompt:menu-y nerimux::*active-menu*))))))

  ;; %run-command-line display-menu with no item args reports canonical syntax error.
  (it "run-command-line-display-menu-empty-args-reports-too-few"
    (with-fake-session (s)
      (let ((*overlay* nil)
            (nerimux::*active-menu* nil))
        (expect (null (nerimux::%run-command-line s "display-menu")))
        (expect (null nerimux::*active-menu*))
        (assert-overlay-contains "command display-menu: too few arguments (need at least 1)"
                                 (overlay-lines)
                                 "display-menu empty args"))))

  ;; :menu-next from 0 advances to 1; :menu-prev from 0 wraps to last index (1).
  (it "dispatch-menu-next-prev-table"
    (dolist (cmd '(:menu-next :menu-prev))
      (with-fake-session (s)
        (let ((nerimux::*active-menu*
                (make-menu :title "t"
                           :items (list (cons "a" :ka) (cons "b" :kb))
                           :selected-index 0)))
          (nerimux::dispatch-command s cmd nil)
          (expect (= 1 (menu-selected-index nerimux::*active-menu*)))))))

  ;; :menu-dismiss clears *active-menu* and the overlay.
  (it "dispatch-menu-dismiss-clears-menu-and-overlay"
    (with-fake-session (s)
      (let ((nerimux::*active-menu*
              (make-menu :title "t" :items (list (cons "a" :ka)) :selected-index 0)))
        (nerimux::dispatch-command s :menu-dismiss nil)
        (expect (null nerimux::*active-menu*)))))

  ;; ── :menu-select / %execute-menu-cmd cmd-shape dispatch ─────────────────────
  ;;
  ;; %execute-menu-cmd's cmd shapes beyond the plain keyword already covered by
  ;; dispatch-menu-select-executes-selected-command (dispatch-tests-commands-c.lisp)
  ;; — string, list-encoded :select-window/:switch-client, the case's `otherwise`
  ;; fallthrough, and display-menu -O keep-open — previously had no dedicated test.

  ;; :menu-select with a string-command item runs it via %run-command-line.
  (it "dispatch-menu-select-string-cmd-runs-command-line"
    (with-fake-session (s)
      (let ((*overlay* nil)
            (nerimux::*active-menu*
              (make-menu :title "t" :items (list (cons "hi" "display-message from-menu"))
                        :selected-index 0)))
        (nerimux::dispatch-command s :menu-select nil)
        (assert-overlay-contains "from-menu" *overlay*
                                 "dispatch-menu-select-string-cmd-runs-command-line"))))

  ;; :menu-select with a (:select-window ID) item — the choose-window menu's
  ;; per-item command shape — selects that window by id.
  (it "dispatch-menu-select-list-select-window-switches-window"
    (with-fake-session (s :nwindows 2)
      (let* ((target (second (session-windows s)))
             (nerimux::*active-menu*
               (make-menu :title "t"
                          :items (list (cons "w1" (list :select-window
                                                        (window-id target))))
                          :selected-index 0)))
        (nerimux::dispatch-command s :menu-select nil)
        (expect (eq target (session-active-window s))))))

  ;; :menu-select with a (:switch-client NAME) item — the choose-session menu's
  ;; per-item command shape — switches the current session.
  (it "dispatch-menu-select-list-switch-client-switches-session"
    (with-loop-state
      (with-empty-registry
        (let* ((s0 (make-fake-session :nwindows 1))
               (s1 (make-fake-session :nwindows 1)))
          (setf (nerimux::session-name s0) "0"
                (nerimux::session-name s1) "work"
                (nerimux::session-last-active s0) 10
                (nerimux::session-last-active s1) 0
                nerimux::*server-sessions* (list (cons "0" s0)
                                                 (cons "work" s1))
                nerimux::*active-menu*
                (make-menu :title "t"
                           :items (list (cons "work" (list :switch-client "work")))
                           :selected-index 0))
          (nerimux::dispatch-command s0 :menu-select nil)
          (expect (eq s1 (nerimux::server-current-session)))))))

  ;; :menu-select with a keyword-headed list item that is NEITHER :select-window
  ;; nor :switch-client falls through the case's `otherwise` arm to
  ;; %run-command-tokens (rather than being silently dropped or erroring) — here
  ;; that resolves to nothing (a keyword is never a valid arg-command or
  ;; named-command lookup key, both of which are string-keyed), surfacing the
  ;; same "unknown command" overlay %dispatch-named-command shows elsewhere.
  (it "dispatch-menu-select-list-otherwise-falls-through-to-run-command-tokens"
    (with-fake-session (s)
      (let ((*overlay* nil))
        (setf nerimux::*active-menu*
              (make-menu :title "t"
                         :items (list (cons "bogus" (list :bogus-menu-cmd)))
                         :selected-index 0))
        (nerimux::dispatch-command s :menu-select nil)
        (assert-overlay-contains "unknown command" *overlay*
                                 "dispatch-menu-select-list-otherwise-falls-through-to-run-command-tokens"))))

  ;; display-menu -O (keep-open) keeps the menu open across a selection instead
  ;; of closing it — the inverse of the default-close behaviour above.
  (it "dispatch-menu-select-keep-open-leaves-menu-active"
    (with-fake-session (s :nwindows 2)
      (let ((nerimux::*active-menu*
              (make-menu :title "t" :items (list (cons "next" :next-window))
                        :selected-index 0 :keep-open t)))
        (nerimux::dispatch-command s :menu-select nil)
        (expect (not (null nerimux::*active-menu*)))))))
