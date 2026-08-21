(in-package #:nerimux/test)

;;;; R8.2: C-q Q shows the R6.4 confirm view with the live-pane count before
;;;; stopping the server; R8.3: detaching the last client does not stop it.
;;;; Driven one byte per %handle-multi-key-message call (§6), through the
;;;; real C-q prefix dispatch.

(describe "confirm-view-quit-suite"

  ;; R8.2: C-q Q opens the confirm view, titled and carrying the live-pane
  ;; count (%session-live-panes), and while it is up every other key is fully
  ;; swallowed rather than reaching the tree/pane underneath -- a
  ;; confirmation that let some other key act on the wrong thing while the
  ;; user answers would be worse than not asking at all. n cancels: the view
  ;; closes and the server keeps running.
  (it "r8-2-c-q-shift-q-shows-confirm-with-live-pane-count-and-swallows-other-keys"
    (with-fake-session (s :nwindows 1 :npanes 2)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/model:session-windows s)))
             (panes (nerimux/model:window-panes win)))
        (setf (nerimux/model:pane-fd (first panes)) 9999) ; one live pane
        (nerimux::%handle-multi-key-message s conn #(17)) ; C-q
        (nerimux::%handle-multi-key-message s conn #(81)) ; Q
        (let ((view (nerimux::client-conn-confirm-view conn)))
          (expect view)
          (expect (string= "SERVER QUIT" (nerimux/renderer:confirm-view-operation view)))
          (expect (search "1 open"
                          (cdr (assoc "panes" (nerimux/renderer:confirm-view-fields view)
                                      :test #'string=)))
                  :to-be-truthy))
        ;; An ordinary move key must not leak to the tree/pane underneath
        ;; while the confirmation is up.
        (nerimux::%handle-multi-key-message s conn #(106)) ; j
        (expect (nerimux::client-conn-confirm-view conn)
                )
        ;; n cancels.
        (nerimux::%handle-multi-key-message s conn #(110)) ; n
        (expect (null (nerimux::client-conn-confirm-view conn)))
        (expect (string= "cancelled" (first (nerimux::client-conn-message-log conn))))
        (expect nerimux::*running* :to-be-truthy))))

  ;; R8.2: y answers the confirm and runs its action -- %server-kill-request
  ;; with FORCE-P T (the confirm view already showed the live-pane count, so
  ;; answering y IS the force decision) -- ending the event loop.
  (it "r8-2-confirming-y-force-kills-and-ends-the-loop"
    (with-fake-session (s :nwindows 1 :npanes 1)
      (let ((conn (%make-test-conn)))
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(81))
        (expect (nerimux::client-conn-confirm-view conn))
        (expect (eq :quit (nerimux::%handle-multi-key-message s conn #(121)))) ; y
        (expect (null (nerimux::client-conn-confirm-view conn)))
        (expect nerimux::*running* :to-be-falsy))))

  ;; R8.3: exit-empty / exit-unattached are both permanently off (1.2: no
  ;; config left to flip them back on) -- detaching the last client leaves
  ;; *running* true and does not touch the panes it leaves behind.
  (it "r8-3-detaching-the-last-client-leaves-running-true-and-panes-untouched"
    (with-fake-session (s :nwindows 1 :npanes 1)
      (let* ((conn (%make-test-conn))
             (pane (nerimux/model:window-active-pane
                    (nerimux/model:session-active-window s)))
             (nerimux::*clients* (list conn)))
        (setf (nerimux/model:pane-fd pane) 9999)
        (expect (eq :drop (nerimux::%handle-multi-client-message
                           nerimux::+msg-detach+ #() s conn)))
        (expect nerimux::*running* :to-be-truthy)
        (expect (nerimux/model:pane-live-p pane))))))
