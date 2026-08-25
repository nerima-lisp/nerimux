(in-package #:nerimux/test)

;;;; R5: pane split and window management, driven one byte per
;;;; %handle-multi-key-message call through the real C-q prefix dispatch
;;;; (server-multi-dispatch.lisp), matching client.lisp's one-byte-per-key
;;;; framing (§6).
;;;;
;;;; %fork-pane is stubbed everywhere here: it spawns a real shell, and R9.2's
;;;; own convention (t/pty/pane-tests-geometry-pty.lisp) is that any test
;;;; needing a real PTY belongs in the separate nerimux/pty-test system, not
;;;; here. The stub returns a screen-only pane with a fake positive fd (9999,
;;;; the fd-9999/pid--1 "live without a real PTY" convention already used in
;;;; t/unit/bootstrap/runtime-tests-b.lisp) so pane-live-p reads true and the
;;;; R5.7 startup-failure branch is not accidentally exercised by every split.
;;;;
;;;; start-reader-thread is ALSO stubbed to a no-op here. runtime-tests-b.lisp
;;;; only ever calls reader-eof-state directly against its fd-9999 pane, which
;;;; never touches select(2); this suite drives splits through the real
;;;; %workspace-prefix-split, which spawns a genuine reader thread that calls
;;;; select-fds on the pane's fd. process-kit's select(2) wrapper rejects any
;;;; fd >= 1022 (FD-SET-OVERFLOW) — fd 9999 was never meant to be watched, only
;;;; to read as "live" — so leaving the real reader thread running here would
;;;; crash the process the first time it polled.
;;;;
;;;; *resize-pty* and *close-pty* are bound to no-ops for the same reason:
;;;; window-relayout and pane close call those ports while this suite uses
;;;; synthetic panes. Outside a running server they are nil because
;;;; install-pty-port only runs at server startup.

(defmacro %with-r5-fixture ((session-var conn-var worktree-var window-var) &body body)
  "Stub %fork-pane and start-reader-thread, bind PTY resize and close ports to
   no-ops,
   build one organization/repository/worktree, open the worktree's first pane
   via the real overview-Enter production path
   (%focus-selected-client-worktree), and bind SESSION-VAR/CONN-VAR/
   WORKTREE-VAR/WINDOW-VAR for BODY."
  `(with-loop-state
     (let ((nerimux/ports:*resize-pty* (lambda (fd rows cols)
                                         (declare (ignore fd rows cols))
                                         nil))
           (nerimux/ports:*close-pty* (lambda (fd pid)
                                        (declare (ignore fd pid))
                                        nil)))
       (with-stubbed-fdefinition
           ((nerimux/model::%fork-pane
             (lambda (session id x y cols rows &key start-dir)
               (declare (ignore session))
               (let ((pane (make-no-pty-pane id x y cols rows)))
                 (setf (nerimux/model:pane-fd pane) 9999
                       (nerimux/model:pane-start-path pane) (or start-dir ""))
                 pane)))
            (nerimux::start-reader-thread
             (lambda (pane) (declare (ignore pane)) nil)))
       (let* ((organization
                (nerimux/model:make-organization
                 :id "org" :host "github.com" :name "team"))
              (repository
                (nerimux/model:make-repository
                 :id "repo" :organization organization
                 :specification "github.com/team/repo"))
              (,worktree-var
                (nerimux/model:make-worktree
                 :id "wt" :repository repository
                 :path "/tmp/nerimux-r5-wt" :branch "feat/phase3"))
              (,session-var (nerimux/model:make-session :id 1 :name "0" :windows nil))
              (,conn-var (%make-test-conn :rows 200 :cols 200))
              (nerimux::*clients* (list ,conn-var)))
         (nerimux/model:organization-add-repository organization repository)
         (nerimux/model:repository-add-worktree repository ,worktree-var)
         (setf (nerimux::client-conn-view ,conn-var) :overview)
         (nerimux::%set-client-selected-tree-object ,conn-var ,worktree-var)
         (nerimux::%handle-multi-key-message ,session-var ,conn-var #(13)) ; Enter
         (let ((,window-var (nerimux/model:session-active-window ,session-var)))
           ,@body))))))

(describe "workspace-panes-acceptance-suite"

  ;; R5.1: a split that does not fit prints a message and changes nothing.
  ;; +pane-min-height+ is 1 and the :v floor needs 2*1+1=3 rows; a 2-row pane
  ;; falls one short.
  (it "r5-1-split-that-does-not-fit-notifies-and-changes-nothing"
    (with-loop-state
      (multiple-value-bind (session window pane)
          (make-single-pane-session :width 3 :height 2)
        (let* ((worktree
                 (nerimux/model:make-worktree :id "wt" :path "/tmp/wt" :branch "feat/tiny"))
               (conn (%make-test-conn))
               ;; %client-notify no-ops unless CONN is in *clients* (%client-live-p).
               (nerimux::*clients* (list conn)))
          (nerimux/model:worktree-add-pane worktree pane)
          (nerimux::%set-client-focus conn pane)
          (nerimux::%handle-multi-key-message session conn #(17)) ; C-q
          (nerimux::%handle-multi-key-message session conn #(45)) ; -
          (expect (= 1 (length (nerimux/model:window-panes window))))
          (expect (= 1 (length (nerimux/model:worktree-panes worktree))))
          (expect (string= "pane too small to split"
                           (first (nerimux::client-conn-message-log conn))))))))

  ;; The R5 acceptance sequence from docs/notes/workspace-requirements.md
  ;; itself: split -> focus move -> 4th pane -> a 5th split opens a new
  ;; window -> window move -> close -> close the last pane, and window /
  ;; worktree pane bookkeeping must stay consistent throughout.
  (it "r5-acceptance-split-focus-cap-new-window-move-close-to-empty"
    (%with-r5-fixture (session conn worktree window-1)
      (expect (= 1 (length (nerimux/model:window-panes window-1))))
      (expect (= 1 (length (nerimux/model:worktree-panes worktree))))

      ;; split -> 2 panes (R5.1 fits; R5.3: new pane starts at the worktree path)
      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(45)) ; -
      (expect (= 2 (length (nerimux/model:window-panes window-1))))
      (expect (= 2 (length (nerimux/model:worktree-panes worktree))))
      (expect (string= "/tmp/nerimux-r5-wt"
                       (nerimux/model:pane-start-path
                        (nerimux/model:window-active-pane window-1))))

      ;; focus move: window-split focuses the NEW pane, and the split above
      ;; is :v (top/bottom, "-"), so the new pane is the bottom one -- its
      ;; only geometric neighbor is :up (k). :down/:left/:right have no
      ;; candidate and pane-neighbor would correctly leave focus unchanged.
      (let ((before (nerimux::client-conn-focus conn)))
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(107)) ; k
        (expect (not (eq before (nerimux::client-conn-focus conn)))))

      ;; two more splits -> 4 panes, the window cap (+max-panes-per-window+)
      (dotimes (_ 2)
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(45)))
      (expect (= 4 (length (nerimux/model:window-panes window-1))))

      ;; R5.2: a 5th split request opens a new window in the SAME worktree
      ;; instead of subdividing window-1 past the cap.
      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(45))
      (expect (= 4 (length (nerimux/model:window-panes window-1)))
              )
      (expect (= 2 (length (nerimux::%worktree-windows worktree)))
              )
      (let ((window-2 (nerimux/model:session-active-window session)))
        (expect (not (eq window-1 window-2)))
        (expect (= 1 (length (nerimux/model:window-panes window-2))))
        (expect (= 5 (length (nerimux/model:worktree-panes worktree))))
        ;; R5.8: branch name + sequence number.
        (expect (string= "feat/phase3 (2)" (nerimux/model:window-name window-2)))

        ;; window move: cycle back to window-1 (R5.8's naming is per-worktree,
        ;; cycling is too -- %worktree-windows is the ring C-q n/p walks).
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(112)) ; p
        (expect (eq window-1 (nerimux/model:session-active-window session)))

        ;; close panes in window-1 down to its last one (3 closes: 4 -> 1).
        (dotimes (_ 3)
          (nerimux::%handle-multi-key-message session conn #(17))
          (nerimux::%handle-multi-key-message session conn #(120))) ; x
        (expect (= 1 (length (nerimux/model:window-panes window-1))))
        (expect (member window-1 (nerimux/model:session-windows session)))

        ;; R5.4: closing window-1's last pane closes window-1 too and
        ;; refocuses to a window of the SAME worktree (window-2) rather than
        ;; overview, since one still has panes.
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(120))
        (expect (not (member window-1 (nerimux/model:session-windows session))))
        (expect (not (member window-1 (nerimux::%worktree-windows worktree))))
        (expect (eq window-2 (nerimux/model:session-active-window session))
                )
        (expect (eq (nerimux/model:window-active-pane window-2)
                    (nerimux::client-conn-focus conn)))

        ;; R5.4: closing window-2's last pane too empties the worktree
        ;; entirely, and focus falls all the way back to overview.
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(120))
        (expect (null (nerimux/model:worktree-panes worktree)))
        (expect (null (nerimux/model:session-windows session)))
        (expect (eq :overview (nerimux::client-conn-view conn))))))

  ;; R5.6: zoom is auto-unzoomed before a split, so the +max-panes-per-window+
  ;; check sees the window's REAL pane count instead of the single collapsed
  ;; leaf window-panes returns while zoomed. Without the unzoom-before-count
  ;; ordering, a zoomed 4-pane window would look like a 1-pane window and
  ;; wrongly accept a 5th pane into itself instead of opening a new window.
  (it "r5-6-zoom-auto-unzoom-so-the-4-pane-cap-is-checked-on-the-real-count"
    (%with-r5-fixture (session conn worktree window)
      (dotimes (_ 3)
        (nerimux::%handle-multi-key-message session conn #(17))
        (nerimux::%handle-multi-key-message session conn #(45)))
      (expect (= 4 (length (nerimux/model:window-panes window))))

      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(122)) ; z
      (expect (nerimux/model:window-zoom-p window))
      (expect (= 1 (length (nerimux/model:window-panes window)))
              )

      (nerimux::%handle-multi-key-message session conn #(17))
      (nerimux::%handle-multi-key-message session conn #(45)) ; -
      (expect (not (nerimux/model:window-zoom-p window)) )
      (expect (= 4 (length (nerimux/model:window-panes window)))
              )
      (expect (= 2 (length (nerimux::%worktree-windows worktree)))
              )))

  ;; R5.7: a pane that comes back from %open-client-worktree-pane without a
  ;; live PTY is recorded as a durable startup failure, not just a one-shot
  ;; notification -- it survives as the overview `!` mark even after the
  ;; message log scrolls.
  (it "r5-7-worktree-pane-startup-failure-is-recorded-as-durable-state"
    (with-loop-state
      (with-stubbed-fdefinition
          ((nerimux/model::%fork-pane
            (lambda (session id x y cols rows &key start-dir)
              (declare (ignore session start-dir))
              (make-no-pty-pane id x y cols rows)))) ; fd stays -1: not live
        (let* ((organization
                 (nerimux/model:make-organization
                  :id "org" :host "github.com" :name "team"))
               (repository
                 (nerimux/model:make-repository
                  :id "repo" :organization organization
                  :specification "github.com/team/repo"))
               (worktree
                 (nerimux/model:make-worktree
                  :id "wt" :repository repository
                  :path "/tmp/nerimux-r5-7-wt" :branch "feat/broken"))
               (session (nerimux/model:make-session :id 1 :name "0" :windows nil))
               (conn (%make-test-conn))
               ;; %client-notify no-ops unless CONN is in *clients* (%client-live-p).
               (nerimux::*clients* (list conn)))
          (nerimux/model:organization-add-repository organization repository)
          (nerimux/model:repository-add-worktree repository worktree)
          (setf (nerimux::client-conn-view conn) :overview)
          (nerimux::%set-client-selected-tree-object conn worktree)
          (nerimux::%handle-multi-key-message session conn #(13))
          (let ((pane (nerimux/model:window-active-pane
                       (nerimux/model:session-active-window session))))
            (expect (nerimux/model:pane-startup-failed-p pane))
            (expect (not (nerimux/model:pane-live-p pane)))
            (expect (member pane (nerimux/model:worktree-panes worktree)))
            (expect (eq pane (nerimux::client-conn-focus conn)))
            (expect (string= "worktree pane failed to start"
                             (first (nerimux::client-conn-message-log conn))))))))))
