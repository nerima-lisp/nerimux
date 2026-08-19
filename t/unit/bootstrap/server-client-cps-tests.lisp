(in-package #:nerimux/test)

;;;; apply-client-size, dispatch-byte, process-client-keys, and runtime registry tests

(describe "server-suite"

  ;;; -- %process-bytes-cps unit tests ------------------------------------------

  ;; %process-bytes-cps returns NIL for empty bytes and when index equals the byte count.
  (it "process-bytes-cps-nil-at-boundary"
    (with-fake-session (s)
      (expect (null (nerimux::%process-bytes-cps
                     s (make-array 0 :element-type '(unsigned-byte 8))
                     (nerimux::make-input-state) 0)))
      (expect (null (nerimux::%process-bytes-cps
                     s (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(1 2 3))
                     (nerimux::make-input-state) 3)))))

  ;; %process-bytes-cps on a prefix+d byte sequence returns :detach.
  (it "process-bytes-cps-detach-keystroke-returns-detach"
    (with-fake-session (s)
      (with-isolated-config
        (let ((state (nerimux::make-input-state))
              (bytes (make-array 2 :element-type '(unsigned-byte 8)
                                   :initial-contents (list 2 (char-code #\d)))))
          (expect (eq :detach (nerimux::%process-bytes-cps s bytes state 0)))))))

  ;;; -- %sync-active-window unit tests -----------------------------------------

  ;; %sync-active-window sets new-session's active window to match existing-session.
  (it "sync-active-window-mirrors-existing-selection"
    (let* ((w1 (make-fake-window 1 "w1"))
           (w2 (make-fake-window 2 "w2"))
           (existing (make-session :id 1 :name "existing"
                                   :windows (list w1 w2)))
           (new-sess (make-session :id 2 :name "new"
                                   :windows (list w1 w2))))
      (session-select-window existing w2)
      (nerimux::%sync-active-window new-sess existing)
      (expect (eq w2 (session-active-window new-sess)))))

  ;; %sync-active-window is a no-op when existing-session has no active window.
  (it "sync-active-window-nil-existing-window-is-safe"
    (let* ((new-sess (make-session :id 2 :name "new" :windows nil))
           (existing (make-session :id 1 :name "existing" :windows nil)))
      (finishes (nerimux::%sync-active-window new-sess existing))
      (expect (null (session-active-window new-sess)))))

  ;;; -- run-server session-registry initialization ------------------------------

  ;; The session-registry setup that run-server performs: reset to NIL then add the initial session.
  (it "run-server-session-registry-initialization"
    (unless (pty-available-p) (skip "no PTY available (sandboxed environment)"))
    (with-empty-registry
      (let ((nerimux::*session-groups* nil)
            (nerimux::*group-id-counter* 0)
            (nerimux/model::*session-id-counter* 0))
        (setf nerimux::*server-sessions* nil)
        (let ((session (create-initial-session 24 80)))
          (nerimux::server-add-session session)
          (expect (= 1 (length nerimux::*server-sessions*)))
          (expect (nerimux::server-find-session (session-name session)) :to-be-truthy)
          (dolist (pane (all-panes session))
            (ignore-errors (pty-close (pane-fd pane) (pane-pid pane))))))))

  ;; server-remove-session removes the session from *server-sessions*, leaving it empty.
  (it "run-server-registry-teardown-on-remove"
    (with-empty-registry
      (let ((sess (make-session :id 1 :name "teardown-test" :windows nil)))
        (nerimux::server-add-session sess)
        (expect (= 1 (length nerimux::*server-sessions*)))
        (nerimux::server-remove-session "teardown-test")
        (expect (null nerimux::*server-sessions*))
        (expect (null (nerimux::server-find-session "teardown-test"))))))

  ;;; -- define-message-dispatch-fn macro ---------------------------------------

  ;; define-message-dispatch-fn must produce a DEFUN whose symbol is fbound.
  (it "define-message-dispatch-fn-generated-function-is-fbound"
    (expect (fboundp 'nerimux::%handle-client-message)))

  ;; The generated function must match the expected dispatch table for NIL, detach, and unknown types.
  (it "define-message-dispatch-fn-returns-same-as-cond-table"
    (dolist (row `((nil :disconnect "NIL -> :disconnect")
                   (,+msg-detach+ :detach "+msg-detach+ -> :detach")
                   (,+msg-frame+ :disconnect "unrecognised type -> :disconnect")))
      (destructuring-bind (msg-type expected desc) row
        (declare (ignore desc))
        (with-fake-session (s)
          (let ((state (nerimux::make-input-state)))
            (expect (eq expected (nerimux::%handle-client-message msg-type #() s state))))))))

  ;;; -- handle-client-message +msg-key+ quit path ------------------------------

  ;; +msg-key+ keystroke returning :quit from process-client-keys must clear *running*.
  (it "handle-client-message-key-quit-clears-running"
    (with-fake-session (s)
      (let ((nerimux::*running* t)
            (state (nerimux::make-input-state)))
        (nerimux::%handle-client-message nil #() s state)
        (expect nerimux::*running* :to-be-truthy))))

  ;;; -- apply-client-size relayout path ----------------------------------------

  ;; apply-client-size calls window-relayout on the session's active window.
  (it "apply-client-size-resizes-active-window"
    (with-fake-session (s)
      (with-server-size-state ()
        (let ((win (session-active-window s)))
          (multiple-value-bind (_t payload) (decode-frame (msg-resize 36 120))
            (declare (ignore _t))
            (nerimux::apply-client-size s payload))
          (expect (= 36 nerimux::*term-rows*))
          (expect (= 120 nerimux::*term-cols*))
          (expect (= 120 (window-width win)))))))

  ;; apply-client-size is safe when the session has no active window.
  (it "apply-client-size-resizes-active-window-with-no-window"
    (let ((s (make-session :id 1 :name "empty" :windows nil)))
      (with-server-size-state ()
        (multiple-value-bind (_type payload) (decode-frame (msg-resize 20 60))
          (declare (ignore _type))
          (finishes (nerimux::apply-client-size s payload))
          (expect (= 20 nerimux::*term-rows*))
          (expect (= 60 nerimux::*term-cols*))))))

  ;;; -- process-client-keys printable byte returns nil -------------------------

  ;; A single printable byte forwarded through process-client-keys returns NIL and leaves *running* T.
  (it "process-client-keys-printable-byte-returns-nil"
    (with-fake-session (s)
      (with-isolated-config
        (let ((state (nerimux::make-input-state))
              (payload (make-array 1 :element-type '(unsigned-byte 8)
                                     :initial-contents (list (char-code #\a)))))
          (expect (null (nerimux::process-client-keys s payload state)))
          (expect nerimux::*running* :to-be-truthy))))))
