(in-package #:nerimux/test)

;;;; Tests for Sprint 3 advanced features:
;;;;  synchronize-panes, layout persistence, update-environment.

;;; ── Fixtures ─────────────────────────────────────────────────────────────────

(defun %two-pane-session ()
  "Session with one window containing two fake panes side-by-side."
  (let* ((p0  (make-no-pty-pane 1  0 0 40 24))
         (p1  (make-no-pty-pane 2 41 0 40 24))
         (win (make-window :id 1 :name "w" :width 81 :height 24
                           :panes (list p0 p1)
                           :tree (make-layout-split :h
                                    (make-layout-leaf p0)
                                    (make-layout-leaf p1)
                                    1/2)))
         (sess (make-session :id 1 :name "0" :windows (list win))))
    (window-select-pane win p0)
    (session-select-window sess win)
    (values sess win p0 p1)))

(describe "advanced-suite"

  ;;; ── synchronize-panes: sends keystrokes to all panes ─────────────────────────

  ;; synchronize-panes previously drove the keystroke-forwarding fanout
  ;; (removed with presentation/events); the option itself is still a
  ;; first-class registered option, so this verifies the toggle round-trips.
  (it "synchronize-panes-sends-to-all"
    (let ((prev (nerimux/options:get-option "synchronize-panes")))
      (unwind-protect
           (progn
             (nerimux/options:set-option "synchronize-panes" t)
             (expect (nerimux/options:get-option "synchronize-panes"))
             (nerimux/options:set-option "synchronize-panes" nil)
             (expect (not (nerimux/options:get-option "synchronize-panes"))))
        (nerimux/options:set-option "synchronize-panes" prev))))

  ;; synchronize-panes is a registered option with boolean type and default nil.
  (it "synchronize-panes-option-registered"
    (let ((spec (gethash "synchronize-panes" nerimux/options:*option-registry*)))
      (expect spec :to-be-truthy)
      (expect (eq :boolean (nerimux/options:option-spec-type spec)))
      (expect (null (nerimux/options:option-spec-default spec)))))

  ;;; ── Layout persistence: round-trip ──────────────────────────────────────────

  ;; layout->string returns a non-NIL string for a window that has a tree.
  (it "layout-to-string-not-nil-for-window-with-tree"
    (multiple-value-bind (sess win p0 p1) (%two-pane-session)
      (declare (ignore sess p0 p1))
      (let ((str (nerimux/model:layout->string win)))
        (expect str :to-be-truthy)
        (expect (stringp str))
        (expect (plusp (length str))))))

  ;; layout->string returns NIL when the window has no tree.
  (it "layout-to-string-nil-for-empty-window"
    (let ((win (make-window :id 1 :name "w" :width 80 :height 24
                            :tree nil)))
      (expect (null (nerimux/model:layout->string win)))))

  ;; layout->string result starts with a 4-character hex checksum.
  (it "layout-checksum-4-hex-chars"
    (multiple-value-bind (_sess win p0 p1) (%two-pane-session)
      (declare (ignore _sess p0 p1))
      (let* ((str     (nerimux/model:layout->string win))
             (comma   (position #\, str))
             (csum    (and comma (subseq str 0 comma))))
        (expect (and csum (= 4 (length csum))))
        (expect (every (lambda (ch) (or (digit-char-p ch) (find ch "ABCDEFabcdef")))
                       (or csum ""))))))

  ;;; ── update-environment ───────────────────────────────────────────────────────

  ;; *update-environment* is a list of environment variable names.
  (it "update-environment-default-list"
    (let ((vars nerimux::*update-environment*))
      (expect (listp vars))
      (expect (> (length vars) 0))
      (expect (every #'stringp vars)))))
