(in-package #:nerimux/test)

;;;; copy-mode-exit, break-pane, clear-history, rotate-window — part VI

(defun %break-arg-fixture ()
  "A window \"w\" with two panes p0 (active), p1 in session \"0\".
   Returns (values sess win p0 p1)."
  (let* ((p0  (%make-test-pane :id 1 :w 10))
         (p1  (%make-test-pane :id 2 :x 11 :w 10))
         (win (make-window :id 1 :name "w" :width 21 :height 5
                           :tree (make-layout-split :h (make-layout-leaf p0)
                                                    (make-layout-leaf p1) 1/2)
                           :panes (list p0 p1)))
         (sess (make-session :id 1 :name "0" :windows (list win))))
    (session-select-window sess win)
    (window-select-pane win p0)
    (values sess win p0 p1)))

(defun %break-extra-window (id)
  (let* ((pane (%make-test-pane :id (+ 100 id) :w 10))
         (win (make-window :id id :name (format nil "w~D" id)
                           :width 10 :height 5
                           :tree (make-layout-leaf pane)
                           :panes (list pane))))
    (window-select-pane win pane)
    win))

(defun %clear-history-fixture ()
  "Single-pane window \"w\" in session \"0\" whose screen has a non-empty
   scrollback.  Returns (values sess win screen)."
  (let* ((screen (make-screen 10 3))
         (pane   (make-pane :id 1 :x 0 :y 0 :width 10 :height 3
                            :fd -1 :pid -1 :screen screen))
         (win    (make-window :id 1 :name "w" :width 10 :height 3
                              :tree (make-layout-leaf pane) :panes (list pane)))
         (sess   (make-session :id 1 :name "0" :windows (list win))))
    (session-select-window sess win)
    (window-select-pane win pane)
    (setf (nerimux/terminal/types:screen-scrollback screen)
          (list (make-array 10 :initial-element
                            (nerimux/terminal/types:make-cell
                             :char #\X :fg 7 :bg 0 :attrs 0 :width 1))))
    (values sess win screen)))

(defun %rotate-window-fixture ()
  "Three-pane window \"w\" (p0 p1 p2) in session \"0\".
   Returns (values sess win p0 p1 p2)."
  (let* ((p0 (%make-test-pane :id 1))
         (p1 (%make-test-pane :id 2))
         (p2 (%make-test-pane :id 3))
         (win (make-window :id 1 :name "w" :width 30 :height 6
                           :tree (make-layout-split :h (make-layout-leaf p0)
                                   (make-layout-split :h (make-layout-leaf p1)
                                                      (make-layout-leaf p2) 1/2)
                                   1/2)
                           :panes (list p0 p1 p2)))
         (sess (make-session :id 1 :name "0" :windows (list win))))
    (session-select-window sess win)
    (values sess win p0 p1 p2)))

(describe "commands-suite"

  ;;; ── copy-mode-exit ───────────────────────────────────────────────────────────

  ;; copy-mode-exit resets copy-mode-p, offset, mark, cursor, and selecting.
  (it "copy-mode-exit-resets-all-copy-state"
    (let ((s (copy-mode-screen)))
      ;; Set all copy-mode fields to non-default values.
      (setf (nerimux/terminal/types:screen-copy-offset    s) 5
            (nerimux/terminal/types:screen-copy-mark      s) (cons 2 3)
            (nerimux/terminal/types:screen-copy-cursor    s) (cons 2 5)
            (nerimux/terminal/types:screen-copy-selecting s) t)
      (nerimux/commands::copy-mode-exit s)
      (expect (screen-copy-mode-p s) :to-be-falsy)
      (expect (= 0 (nerimux/terminal/types:screen-copy-offset s)))
      (expect (null (nerimux/terminal/types:screen-copy-mark s)))
      (expect (null (nerimux/terminal/types:screen-copy-cursor s)))
      (expect (nerimux/terminal/types:screen-copy-selecting s) :to-be-falsy)))

  ;;; ── copy-mode-half-page-down ─────────────────────────────────────────────────

  ;; copy-mode-half-page-down scrolls forward by floor(screen-height/2) lines.
  (it "copy-mode-half-page-down-scrolls-forward-by-half-height"
    (let ((s (%screen-with-scrollback 30)))
      ;; First scroll back enough to allow scrolling forward.
      (setf (nerimux/terminal/types:screen-copy-offset s) 20)
      (nerimux/commands::copy-mode-half-page-down s)
      ;; height=5, floor(5/2)=2, so offset decreases by 2: 20-2=18.
      (expect (= 18 (screen-copy-offset s)))))

  ;;; ── break-pane ───────────────────────────────────────────────────────────────

  ;; break-pane on a window with only one pane is a no-op and returns NIL.
  (it "break-pane-sole-pane-returns-nil"
    (let* ((pane (%make-test-pane))
           (win  (make-window :id 1 :name "w" :width 20 :height 5
                              :tree (make-layout-leaf pane)
                              :panes (list pane)))
           (sess (make-session :id 1 :name "0" :windows (list win))))
      (session-select-window sess win)
      (window-select-pane win pane)
      (expect (null (nerimux/commands:break-pane sess)))))

  ;; break-pane when session has no active window returns NIL.
  (it "break-pane-nil-src-win-returns-nil"
    ;; Build a session with no windows to exercise the nil-src-win guard.
    (let ((sess (make-session :id 1 :name "0" :windows nil)))
      (expect (null (nerimux/commands:break-pane sess)))))

  ;; break-pane removes the active pane and places it in a new window.
  (it "break-pane-moves-pane-to-new-window"
    (let* ((p0  (%make-test-pane :id 1 :w 10))
           (p1  (%make-test-pane :id 2 :x 11 :w 10))
           (win (make-window :id 1 :name "w" :width 21 :height 5
                             :tree (make-layout-split :h
                                      (make-layout-leaf p0) (make-layout-leaf p1)
                                      1/2)
                             :panes (list p0 p1)))
           (sess (make-session :id 1 :name "0" :windows (list win))))
      (session-select-window sess win)
      (window-select-pane win p0)
      (let ((new-win (nerimux/commands:break-pane sess)))
        (expect new-win :to-be-truthy)
        (expect (member new-win (session-windows sess)))
        (expect (member p0 (window-panes new-win)))
        (expect (= 1 (length (window-panes new-win))))
        ;; Source window still has p1.
        (expect (member p1 (window-panes win))))))

  ;; break-pane assigns the lowest free window id at or above base-index.
  (it "break-pane-respects-base-index"
    (with-isolated-options ("base-index" 1)
      (let* ((p0  (%make-test-pane :id 1 :w 10))
             (p1  (%make-test-pane :id 2 :x 11 :w 10))
             (win (make-window :id 1 :name "w" :width 21 :height 5
                               :tree (make-layout-split :h
                                        (make-layout-leaf p0) (make-layout-leaf p1)
                                        1/2)
                               :panes (list p0 p1)))
             (sess (make-session :id 1 :name "0" :windows (list win))))
        (session-select-window sess win)
        (window-select-pane win p0)
        (let ((new-win (nerimux/commands:break-pane sess)))
          (expect (= 2 (window-id new-win)))
          (expect (null (find 0 (session-windows sess) :key #'window-id)))))))

  ;;; ── break-pane keyword variants ───────────────────────────────────────────────
  ;;;
  ;;; The break-pane/clear-history/rotate-window tmux command-line surface (flag
  ;;; parsing, target-string resolution, unsupported-argument rejection, -P/-F
  ;;; overlay formatting) was dispatch-layer sugar on top of these domain
  ;;; functions; that layer is gone.  These tests drive BREAK-PANE, CLEAR-SCROLLBACK,
  ;;; and rotate-window-arg-equivalent domain functions directly via keyword
  ;;; arguments, which is exactly what the old dispatch wrapper reduced to.

  ;; break-pane always moves the active pane to a new window; :select controls
  ;; whether the session switches to that new window (the old -d flag).
  ;; Each row: (select expect-switch-to-new description).
  (it "cmd-break-pane-switch-variants-table"
    (dolist (row '((t   t   "no -d: session switches to the new window")
                   (nil nil "-d: session stays on the current window")))
      (destructuring-bind (select expect-switch desc) row
        (declare (ignore desc))
        (multiple-value-bind (sess win p0 p1) (%break-arg-fixture)
          (declare (ignore p1))
          (with-command-test-state (sess)
            (nerimux/commands:break-pane sess :select select)
            (expect (= 2 (length (session-windows sess))))
            (let* ((new-win (find-if (lambda (w) (not (eq w win))) (session-windows sess)))
                   (expected-active (if expect-switch new-win win)))
              (expect (member p0 (window-panes new-win)))
              (expect (eq expected-active (session-active-window sess)))))))))

  ;; break-pane :name gives the new window that name (the old -n flag).
  (it "cmd-break-pane-n-names-new-window"
    (multiple-value-bind (sess win p0 p1) (%break-arg-fixture)
      (declare (ignore p0 p1))
      (with-command-test-state (sess)
        (nerimux/commands:break-pane sess :name "logs")
        (let ((new-win (find-if (lambda (w) (not (eq w win))) (session-windows sess))))
          (expect (string= "logs" (window-name new-win)))))))

  ;; break-pane :target-window-id places the new window at the requested free index
  ;; (the old -t flag).
  (it "cmd-break-pane-t-places-new-window-at-target-index"
    (multiple-value-bind (sess win p0 p1) (%break-arg-fixture)
      (declare (ignore p1))
      (with-command-test-state (sess)
        (expect (nerimux/commands:break-pane sess :select nil :target-window-id 5)
                :to-be-truthy)
        (let ((new-win (find 5 (session-windows sess) :key #'window-id)))
          (expect new-win :to-be-truthy)
          (expect (member p0 (window-panes new-win))))
        (expect (eq win (session-active-window sess))))))

  ;; break-pane rejects an occupied target index before moving the pane.
  (it "cmd-break-pane-t-occupied-index-is-rejected-before-moving-pane"
    (multiple-value-bind (sess win p0 p1) (%break-arg-fixture)
      (let ((other (%break-extra-window 2)))
        (session-insert-window sess other)
        (with-command-test-state (sess)
          (expect (nerimux/commands:break-pane sess :select nil :target-window-id 2)
                  :to-be-falsy)
          (expect (equal '(1 2) (mapcar #'window-id (session-windows sess))))
          (expect (equal (list p0 p1) (window-panes win)))
          (expect (eq win (session-active-window sess)))
          (expect nerimux::*dirty* :to-be-falsy)))))

  ;; break-pane :insert-after inserts after the target index and shifts collisions
  ;; upward (the old -a flag).
  (it "cmd-break-pane-a-shifts-colliding-windows-after-target"
    (multiple-value-bind (sess win p0 p1) (%break-arg-fixture)
      (declare (ignore p1))
      (let ((other (%break-extra-window 2)))
        (session-insert-window sess other)
        (with-command-test-state (sess)
          (expect (nerimux/commands:break-pane
                   sess :select nil :target-window-id 1 :insert-after t)
                  :to-be-truthy)
          (expect (equal '(1 2 3) (mapcar #'window-id (session-windows sess))))
          (let ((new-win (find 2 (session-windows sess) :key #'window-id)))
            (expect (member p0 (window-panes new-win))))
          (expect (= 3 (window-id other)))
          (expect (eq win (session-active-window sess)))))))

  ;; break-pane :insert-before inserts before the target index and shifts
  ;; collisions upward (the old -b flag).
  (it "cmd-break-pane-b-shifts-colliding-windows-before-target"
    (multiple-value-bind (sess win p0 p1) (%break-arg-fixture)
      (declare (ignore p1))
      (let ((other (%break-extra-window 2)))
        (session-insert-window sess other)
        (with-command-test-state (sess)
          (expect (nerimux/commands:break-pane
                   sess :select nil :target-window-id 1 :insert-before t)
                  :to-be-truthy)
          (expect (equal '(1 2 3) (mapcar #'window-id (session-windows sess))))
          (let ((new-win (find 1 (session-windows sess) :key #'window-id)))
            (expect (member p0 (window-panes new-win))))
          (expect (= 2 (window-id win)))
          (expect (= 3 (window-id other)))))))

  ;;; ── clear-history ────────────────────────────────────────────────────────────

  ;; clear-scrollback empties the target pane's scrollback.
  (it "cmd-clear-history-clears-scrollback"
    (multiple-value-bind (sess win screen) (%clear-history-fixture)
      (declare (ignore win))
      (with-command-test-state (sess)
        (nerimux/terminal/actions:clear-scrollback screen)
        (expect (null (nerimux/terminal/types:screen-scrollback screen))))))

  ;;; ── rotate-window ────────────────────────────────────────────────────────────

  ;; window-rotate with :up (the default, tmux forward) moves the first pane to end.
  (it "cmd-rotate-window-forward-default"
    (multiple-value-bind (sess win p0 p1 p2) (%rotate-window-fixture)
      (declare (ignore p2))
      (with-command-test-state (sess)
        (nerimux/model:window-rotate win :up)
        (expect (eq p1 (first (window-panes win))))
        (expect (eq p0 (car (last (window-panes win))))))))

  ;; window-rotate :down (tmux backward) moves the last pane to the front.
  (it "cmd-rotate-window-d-rotates-backward"
    (multiple-value-bind (sess win p0 p1 p2) (%rotate-window-fixture)
      (declare (ignore p0 p1))
      (with-command-test-state (sess)
        (nerimux/model:window-rotate win :down)
        (expect (eq p2 (first (window-panes win))))))))
