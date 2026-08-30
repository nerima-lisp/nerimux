(in-package #:nerimux/test/model)

;;;; Session tests — start-directory slot, all-panes ordering, and window flag clearing.

(describe "model-suite"

  ;;; ── session-start-directory slot ─────────────────────────────────────────────

  ;; session-start-directory defaults to NIL for a freshly created session.
  (it "session-start-directory-defaults-nil"
    (let ((sess (make-session :id 1 :name "s")))
      (expect (null (nerimux/session::session-start-directory sess)))))

  ;; session-start-directory can be set to a path string and read back.
  (it "session-start-directory-settable"
    (let ((sess (make-session :id 1 :name "s")))
      (setf (nerimux/session::session-start-directory sess) "/home/user")
      (expect (string= "/home/user" (nerimux/session::session-start-directory sess)))))

  ;;; ── all-panes ordering ───────────────────────────────────────────────────────

  ;; all-panes returns panes in window-list order (first window's panes first).
  (it "all-panes-preserves-window-order"
    (let* ((p0   (make-no-pty-pane 1 0 0 20 5))
           (p1   (make-no-pty-pane 2 0 0 20 5))
           (w0   (make-window :id 0 :name "w0" :panes (list p0)))
           (w1   (make-window :id 1 :name "w1" :panes (list p1)))
           (sess (make-session :id 1 :name "s" :windows (list w0 w1))))
      (let ((panes (all-panes sess)))
        (expect (eq p0 (first panes)))
        (expect (eq p1 (second panes))))))

  ;;; ── session-windows returns the window list ──────────────────────────────────

  ;; session-windows returns all windows inserted via session-insert-window.
  (it "session-windows-returns-complete-list"
    (let* ((w0   (make-window :id 0 :name "a"))
           (w1   (make-window :id 1 :name "b"))
           (w2   (make-window :id 2 :name "c"))
           (sess (make-session :id 1 :name "s" :windows nil)))
      (session-insert-window sess w0)
      (session-insert-window sess w2)
      (session-insert-window sess w1)
      (expect (= 3 (length (session-windows sess))))
      (expect (member w0 (session-windows sess)) :to-be-truthy)
      (expect (member w1 (session-windows sess)) :to-be-truthy)
      (expect (member w2 (session-windows sess)) :to-be-truthy)))

  (it "session-window-index-uses-overrides-and-clears-defaults"
    (let* ((window (make-window :id 2 :name "w"))
           (session (make-session :id 1 :name "s" :windows (list window))))
      (expect (= 2 (nerimux/session::session-window-index session window)))
      (nerimux/session::set-session-window-index session window 7)
      (expect (= 7 (nerimux/session::session-window-index session window)))
      (nerimux/session::set-session-window-index session window 2)
      (expect (= 2 (nerimux/session::session-window-index session window)))
      (expect (= 0 (hash-table-count (nerimux/session::session-window-index-map session))))))

  (it "session-windows-in-index-order-is-non-destructive"
    (let* ((w0 (make-window :id 0 :name "w0"))
           (w1 (make-window :id 1 :name "w1"))
           (session (make-session :id 1 :name "s" :windows (list w0 w1))))
      (nerimux/session::set-session-window-index session w0 3)
      (nerimux/session::set-session-window-index session w1 1)
      (let ((ordered (nerimux/session::session-windows-in-index-order session)))
        (expect (eq w1 (first ordered)))
        (expect (eq w0 (second ordered)))
        (expect (eq w0 (first (session-windows session)))))))

  (it "session-remove-window-clears-all-references"
    (let* ((window (make-window :id 1 :name "w"))
           (session (make-session :id 1 :name "s" :windows (list window)
                                  :active window :window-stack (list window))))
      (nerimux/session::set-session-window-index session window 9)
      (nerimux/session::session-remove-window session window)
      (expect (null (nerimux/session::session-windows session)))
      (expect (null (nerimux/session::session-active session)))
      (expect (null (nerimux/session::session-window-stack session)))
      (expect (= 0 (hash-table-count (nerimux/session::session-window-index-map session)))))))
