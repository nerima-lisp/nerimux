(in-package #:nerimux/test)

;;;; Cross-session window linking, unlinking, and grouped-session teardown.

(describe "server-suite"

  ;; %window-session-count returns the number of registered sessions holding a window.
  (it "window-session-count-counts-sessions-containing-window"
    (with-empty-registry
      (let* ((alpha (make-fake-session :nwindows 1))
             (beta  (make-fake-session :nwindows 1))
             (win   (first (nerimux/model:session-windows alpha))))
        (setf (nerimux/model:session-name alpha) "alpha"
              (nerimux/model:session-name beta)  "beta")
        (nerimux::server-add-session alpha)
        (nerimux::server-add-session beta)
        (expect (= 1 (nerimux::%window-session-count win)))
        (nerimux/model:session-insert-window beta win)
        (expect (= 2 (nerimux::%window-session-count win))))))

  ;; link-window -s src -t dst makes the source window appear in dst (no collision).
  (it "link-window-shares-window-into-destination"
    (with-empty-registry
      (let* ((alpha (make-fake-session :nwindows 1))
             (beta  (make-fake-session :nwindows 1))
             (alpha-win (first (nerimux/model:session-windows alpha))))
        (setf (nerimux/model:session-name alpha) "alpha"
              (nerimux/model:session-name beta)  "beta")
        (setf (nerimux/model:window-id (first (nerimux/model:session-windows beta))) 9)
        (nerimux::server-add-session alpha)
        (nerimux::server-add-session beta)
        (let ((nerimux/prompt:*overlay* nil))
          (nerimux::%cmd-link-window alpha '("-s" "alpha:0" "-t" "beta")))
        (expect (member alpha-win (nerimux/model:session-windows beta)) :to-be-truthy))))

  ;; unlink-window on a window shared by 2 sessions removes it from the target only.
  (it "unlink-window-shared-removes-from-one-session-only"
    (with-empty-registry
      (let* ((alpha (make-fake-session :nwindows 1))
             (beta  (make-fake-session :nwindows 1))
             (win   (first (nerimux/model:session-windows alpha))))
        (setf (nerimux/model:session-name alpha) "alpha"
              (nerimux/model:session-name beta)  "beta")
        (nerimux::server-add-session alpha)
        (nerimux::server-add-session beta)
        (nerimux/model:session-insert-window beta win)
        (nerimux/model:session-select-window beta win)
        (let ((nerimux/prompt:*overlay* nil))
          (nerimux::%cmd-unlink-window beta nil))
        (expect (member win (nerimux/model:session-windows beta)) :to-be-falsy)
        (expect (member win (nerimux/model:session-windows alpha)) :to-be-truthy))))

  ;; link-window fires +hook-window-linked+ when a window is linked in.
  (it "link-window-fires-window-linked-hook"
    (with-empty-registry
      (with-isolated-hooks
        (let* ((alpha (make-fake-session :nwindows 1))
               (beta  (make-fake-session :nwindows 1))
               (fired nil))
          (setf (nerimux/model:session-name alpha) "alpha"
                (nerimux/model:session-name beta)  "beta")
          (setf (nerimux/model:window-id (first (nerimux/model:session-windows beta))) 9)
          (nerimux::server-add-session alpha)
          (nerimux::server-add-session beta)
          (nerimux/hooks:add-hook "window-linked"
                                  (lambda (&rest _) (declare (ignore _)) (setf fired t)))
          (let ((nerimux/prompt:*overlay* nil))
            (nerimux::%cmd-link-window alpha '("-s" "alpha:0" "-t" "beta")))
          (expect fired :to-be-truthy)))))

  ;; unlink-window fires +hook-window-unlinked+ when a shared window is unlinked.
  (it "unlink-window-fires-window-unlinked-hook"
    (with-empty-registry
      (with-isolated-hooks
        (let* ((alpha (make-fake-session :nwindows 1))
               (beta  (make-fake-session :nwindows 1))
               (win   (first (nerimux/model:session-windows alpha)))
               (fired nil))
          (setf (nerimux/model:session-name alpha) "alpha"
                (nerimux/model:session-name beta)  "beta")
          (nerimux::server-add-session alpha)
          (nerimux::server-add-session beta)
          (nerimux/model:session-insert-window beta win)
          (nerimux/model:session-select-window beta win)
          (nerimux/hooks:add-hook "window-unlinked"
                                  (lambda (&rest _) (declare (ignore _)) (setf fired t)))
          (let ((nerimux/prompt:*overlay* nil))
            (nerimux::%cmd-unlink-window beta nil))
          (expect fired :to-be-truthy)))))

  ;; %destroy-session removes the session AND fires +hook-session-closed+.
  (it "destroy-session-fires-session-closed-hook"
    (with-empty-registry
      (with-isolated-hooks
        (let ((fired nil))
          (with-fake-session (s :nwindows 1)
            (nerimux::server-add-session s)
            (nerimux/hooks:add-hook "session-closed"
                                    (lambda (&rest _) (declare (ignore _)) (setf fired t)))
            (nerimux::%destroy-session s)
            (expect fired :to-be-truthy))))))

  ;; Destroying ONE session in a group must NOT close the PTYs of a window another
  ;; grouped session still shares.
  (it "destroy-grouped-session-keeps-shared-window-ptys-open"
    (with-empty-registry
      (let ((target  (make-fake-session :nwindows 1))
            (grouped (make-fake-session :nwindows 1))
            (closed  0))
        (setf (nerimux::session-name target)  "base"
              (nerimux::session-name grouped) "clone"
              (nerimux::session-windows grouped) (nerimux::session-windows target))
        (nerimux::server-add-session target)
        (nerimux::server-add-session grouped)
        (let ((orig (fdefinition 'nerimux/pty:pty-close)))
          (unwind-protect
               (progn
                 (setf (fdefinition 'nerimux/pty:pty-close)
                       (lambda (fd pid) (declare (ignore fd pid)) (incf closed)))
                 (nerimux::%destroy-session grouped))
            (setf (fdefinition 'nerimux/pty:pty-close) orig)))
        (expect (zerop closed))
        (expect (null (nerimux::server-find-session "clone")))
        (expect (not (null (nerimux::server-find-session "base")))))))

  ;; Regression guard: an ungrouped (single-reference) session's PTYs ARE still
  ;; closed on destroy - the reference-counted guard does not change the common case.
  (it "destroy-ungrouped-session-closes-its-ptys"
    (with-empty-registry
      (let ((sess   (make-fake-session :nwindows 1 :npanes 2))
            (closed  0))
        (setf (nerimux::session-name sess) "solo")
        (nerimux::server-add-session sess)
        (let ((orig (fdefinition 'nerimux/pty:pty-close)))
          (unwind-protect
               (progn
                 (setf (fdefinition 'nerimux/pty:pty-close)
                       (lambda (fd pid) (declare (ignore fd pid)) (incf closed)))
                 (nerimux::%destroy-session sess))
            (setf (fdefinition 'nerimux/pty:pty-close) orig)))
        (expect (= 2 closed)))))

  ;; rename-session removes+re-adds its registry entry but must NOT fire
  ;; session-closed (only actual destruction does).
  (it "rename-session-does-not-fire-session-closed"
    (with-empty-registry
      (with-isolated-hooks
        (let ((s (make-fake-session :nwindows 1))
              (fired nil))
          (nerimux::server-add-session s)
          (nerimux/hooks:add-hook "session-closed"
                                  (lambda (&rest _) (declare (ignore _)) (setf fired t)))
          (nerimux::%cmd-rename-session s '("renamed"))
          (expect fired :to-be-falsy)))))

  ;; unlink-window on a window present in only one session is refused without -k.
  (it "unlink-window-only-session-needs-k-flag"
    (with-empty-registry
      (let* ((alpha (make-fake-session :nwindows 2))
             (win   (first (nerimux/model:session-windows alpha))))
        (setf (nerimux/model:session-name alpha) "alpha")
        (nerimux::server-add-session alpha)
        (nerimux/model:session-select-window alpha win)
        (let ((nerimux/prompt:*overlay* nil))
          (nerimux::%cmd-unlink-window alpha nil))
        (expect (member win (nerimux/model:session-windows alpha)) :to-be-truthy)))))
