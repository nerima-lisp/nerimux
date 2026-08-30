(in-package #:nerimux/test)

;;;; Session and buffer fixtures.


(defmacro with-empty-session ((var) &body body)
  "Bind VAR to a windowless session suitable for empty-state guard tests.
   The session has id 1, name \"0\", and an empty window list."
  `(let ((,var (make-session :id 1 :name "0" :windows nil)))
     ,@body))

(defmacro with-minimal-loop-session ((pane-var win-var sess-var &rest keys) &body body)
  "Combine with-minimal-session + with-loop-state for dispatch tests."
  `(with-minimal-session (,pane-var ,win-var ,sess-var ,@keys)
     (with-loop-state
       ,@body)))

;;; WITH-SESSION (real PTY-backed session, via create-initial-session) moved
;;; to tests/pty/helpers.lisp: R9.2's case-by-case audit found every one of its
;;; callers spawned a real PTY, so all of them moved into the nerimux/pty-test
;;; system, and this macro had no remaining caller here.

(defmacro with-fake-session ((var &rest make-args) &body body)
  "Bind VAR to a fresh fake session built from MAKE-ARGS and run BODY inside
   WITH-LOOP-STATE isolation.  Composes MAKE-FAKE-SESSION with WITH-LOOP-STATE
   to eliminate the repeated (let ((s (make-fake-session ...))) (with-loop-state ...))
   pattern in dispatch-tests and events-tests.
   MAKE-ARGS are passed verbatim to MAKE-FAKE-SESSION (e.g. :nwindows 2 :npanes 3)."
  `(let ((,var (make-fake-session ,@make-args)))
     (with-loop-state
       ,@body)))

(defmacro with-fake-two-pane-session ((var) &body body)
  "Bind VAR to the common one-window, two-pane fake session used by the
   select-pane command tests and similar command dispatch checks."
  `(with-fake-session (,var :nwindows 1 :npanes 2)
     ,@body))

(defmacro with-minimal-session ((pane-var win-var sess-var
                                 &key (width 20) (height 5)) &body body)
  "Bind PANE-VAR, WIN-VAR, SESS-VAR to a fresh single-pane session of WIDTH x HEIGHT.
   The pane has :fd -1 and :pid -1 (no real PTY).  The window and session are
   selected so session-active-window / window-active-pane work immediately.
   Eliminates the repetitive let*/window-select-pane/session-select-window scaffold
   that appears throughout events-tests.lisp."
  (let ((w-sym (gensym "W")) (h-sym (gensym "H")))
    `(let* ((,w-sym ,width)
            (,h-sym ,height)
            (,pane-var (make-pane :id 1 :fd -1 :pid -1
                                  :x 0 :y 0 :width ,w-sym :height ,h-sym
                                  :screen (make-screen ,w-sym ,h-sym)))
            (,win-var  (make-window :id 1 :name "w"
                                    :width ,w-sym :height ,h-sym
                                    :panes (list ,pane-var)
                                    :tree  (make-layout-leaf ,pane-var)))
            (,sess-var (make-session :id 1 :name "s"
                                     :windows (list ,win-var))))
       (window-select-pane ,win-var ,pane-var)
       (session-select-window ,sess-var ,win-var)
       (locally ,@body))))

(defun active-screen (session)
  (pane-screen (window-active-pane (session-active-window session))))

(defun make-single-pane-session (&key (session-name "s") (window-name "w")
                                       (width 80) (height 24)
                                       (session-id 1) (window-id 1) (pane-id 1))
  "Build and return a minimal (session window pane) triple.
   The pane is no-PTY (fd = -1, pid = -1) sized WIDTH x HEIGHT.
   The window wraps the pane in a leaf tree, with the pane as active.
   The session holds the window as its sole entry and active window.
   Returns (values session window pane).
   Callers that only need the session can ignore the extra values."
  (let* ((pane (make-pane :id pane-id :x 0 :y 0 :width width :height height
                           :fd -1 :pid -1 :screen (make-screen width height)))
         (win  (make-window :id window-id :name window-name
                            :width width :height height
                            :panes (list pane)
                            :tree  (make-layout-leaf pane)
                            :active pane))
         (sess (make-session :id session-id :name session-name
                             :windows (list win) :active win)))
    (setf (pane-window pane) win)
    (window-select-pane win pane)
    (session-select-window sess win)
    (values sess win pane)))
