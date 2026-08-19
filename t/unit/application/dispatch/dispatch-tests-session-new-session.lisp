(in-package #:nerimux/test)

;;;; Dispatch session tests - new-session duplicate, grouped sessions, and new-window -S.

(describe "dispatch-suite"

  ;;; -- new-session -s duplicate-name handling ----------------------------------

  ;; new-session -s NAME with an existing session NAME (no -A) is refused - the
  ;; existing session is not orphaned.
  (it "new-session-explicit-duplicate-name-refused"
    (with-fake-session (existing)
      (let ((caller (make-fake-session)))
        (setf (nerimux::session-name existing) "work")
        (with-registered-sessions (("work" existing))
          (let ((*overlay* nil))
            (expect (null (nerimux::%cmd-new-session-arg caller '("-s" "work"))))
            (expect (eq existing (nerimux::server-find-session "work")))
            (expect (= 1 (length nerimux::*server-sessions*))))))))

  ;; new-session -A -s NAME attaches to (returns) the existing session NAME.
  (it "new-session-A-attaches-to-existing"
    (with-fake-session (existing)
      (let ((caller (make-fake-session)))
        (setf (nerimux::session-name existing) "work")
        (with-registered-sessions (("work" existing))
          (expect (eq existing (nerimux::%cmd-new-session-arg caller '("-A" "-s" "work"))))
          (expect (= 1 (length nerimux::*server-sessions*)))))))

  ;; An auto-generated session name that would collide bumps to the next free
  ;; number instead of orphaning the existing session.
  (it "new-session-auto-name-avoids-collision"
    (with-fake-session (s2)
      (setf (nerimux::session-name s2) "2")
      (with-registered-sessions (("2" s2))
        (let ((*overlay* nil))
          (let ((new (nerimux::%cmd-new-session-arg s2 '("-d"))))
            (expect (not (null new)))
            (expect (not (string= "2" (nerimux::session-name new))))
            (expect (eq s2 (nerimux::server-find-session "2"))))))))

  ;; new-session -e VAR=val stores VAR in the new session's environment overlay
  ;; (inherited by windows created later in the session).
  (it "new-session-e-sets-session-environment"
    (with-fake-session (s2)
      (setf (nerimux::session-name s2) "7")
      (with-registered-sessions (("7" s2))
        (let ((*overlay* nil))
          (let ((new (nerimux::%cmd-new-session-arg
                      s2 '("-d" "-s" "envy" "-e" "NERIMUX_NS_E=bar"))))
            (expect (not (null new)))
            (multiple-value-bind (value source)
                (nerimux/model:session-environment-value new "NERIMUX_NS_E")
              (declare (ignore source))
              (expect (string= "bar" value))))))))

  ;; new-session -dP prints the new session info (default #{session_name}:) to an
  ;; overlay, and -F overrides the format.
  (it "new-session-P-prints-session-info"
    (with-fake-session (s2)
      (setf (nerimux::session-name s2) "6")
      (with-registered-sessions (("6" s2))
        (let ((*overlay* nil))
          (nerimux::%cmd-new-session-arg s2 '("-d" "-P" "-s" "printy"))
          (expect (and *overlay* (search "printy" *overlay*))))
        (let ((*overlay* nil))
          (nerimux::%cmd-new-session-arg
           s2 '("-d" "-P" "-F" "ID=#{session_name}" "-s" "fmty"))
          (expect (and *overlay* (search "ID=fmty" *overlay*)))))))

  ;; new-window -S -n NAME selects an existing window with that name instead of
  ;; creating a new one (tmux new-window -S).
  (it "new-window-S-selects-existing-named-window"
    (with-fake-session (s :nwindows 1)
      (let ((w (session-active-window s)))
        (setf (nerimux::window-name w) "ssh")
        (let ((before (length (nerimux::session-windows s))))
          (let ((result (nerimux::%cmd-new-window-arg s '("-S" "-n" "ssh"))))
            (expect (eq w result))
            (expect (= before (length (nerimux::session-windows s)))))))))

  ;;; -- new-session -t: grouped sessions ----------------------------------------

  ;; new-session -t TARGET creates a GROUPED session that SHARES the target's
  ;; window list (tmux grouped sessions).  Built fork-free via make-session -
  ;; no orphaned PTY/reader-thread, because the shared panes keep the threads
  ;; already attached to them by the target session.
  (it "new-session-t-shares-target-windows"
    (with-fake-session (target)
      (let ((caller (make-fake-session)))
        (setf (nerimux::session-name target) "base")
        (with-registered-sessions (("base" target))
          (let ((nerimux::*session-groups*  nil)
                (*overlay* nil))
            (let ((grouped (nerimux::%cmd-new-session-arg
                            caller '("-d" "-s" "clone" "-t" "base"))))
              (expect (not (null grouped)))
              (expect (not (eq grouped target)))
              (expect (eq (nerimux::session-windows grouped)
                          (nerimux::session-windows target)))
              (expect (eq (nerimux::session-active-window grouped)
                          (nerimux::session-active-window target)))
              (expect (eq grouped (nerimux::server-find-session "clone")))
              (expect (and (nerimux::session-group grouped)
                           (eql (nerimux::session-group grouped)
                                (nerimux::session-group target))))))))))

  ;; new-session -t with an unknown target is refused (returns nil) and registers
  ;; no session - the partial group must not leak a half-built session.
  (it "new-session-t-missing-target-refused"
    (with-fake-session (caller)
      (with-empty-registry
        (let ((nerimux::*session-groups*  nil)
              (*overlay* nil))
          (expect (null (nerimux::%cmd-new-session-arg
                         caller '("-d" "-s" "clone" "-t" "ghost"))))
          (expect (null nerimux::*server-sessions*)))))))
