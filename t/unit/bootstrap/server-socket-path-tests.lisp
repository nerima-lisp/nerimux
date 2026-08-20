(in-package #:nerimux/test)

;;;; socket-path and stale-socket tests

(describe "server-suite"

  ;;; -- socket-path naming ------------------------------------------------------

  ;; socket-path embeds the session name in the filename and always ends with .sock.
  (it "socket-path-properties-table"
    (dolist (row '(("mysess" "nerimux-mysess.sock" "session name embedded in path")
                   ("anysess" ".sock" "path always ends with .sock")))
      (destructuring-bind (sess expected desc) row
        (declare (ignore desc))
        (let ((path (nerimux::socket-path sess)))
          (expect (search expected path))))))

  ;; socket-path returns distinct paths for distinct session names.
  (it "socket-path-distinct-for-different-names"
    (let ((p1 (nerimux::socket-path "alpha"))
          (p2 (nerimux::socket-path "beta")))
      (expect (string/= p1 p2))))

  ;; socket-path embeds $TMPDIR in the result when it is set, overriding /tmp.
  (it "socket-path-uses-tmpdir-env-var"
    (with-temporary-posix-environment-variable ("TMUX_TMPDIR" nil)
      (with-temporary-posix-environment-variable ("TMPDIR" "/var/folders/test")
        (let ((path (nerimux::socket-path "envtest")))
          (expect (search "/var/folders/test" path))))))

  ;; socket-path uses /tmp as the socket directory when $TMPDIR is unset.
  (it "socket-path-falls-back-to-tmp-when-no-tmpdir"
    (with-temporary-posix-environment-variable ("TMUX_TMPDIR" nil)
      (with-temporary-posix-environment-variable ("TMPDIR" nil)
        (let ((path (nerimux::socket-path "tmptestfb")))
          (expect (search "/tmp" path))))))

  ;; socket-path prefers $TMUX_TMPDIR over $TMPDIR (tmux precedence).
  (it "socket-path-tmux-tmpdir-beats-tmpdir"
    (with-temporary-posix-environment-variable ("TMUX_TMPDIR" "/tmp/tmux-tmpdir-test")
      (let ((path (nerimux::socket-path "envtest2")))
        (expect (search "/tmp/tmux-tmpdir-test" path)))))

  ;; Sockets live in a per-UID directory.
  (it "socket-path-uses-per-uid-directory"
    (with-temporary-posix-environment-variable ("TMUX_TMPDIR" nil)
      (let ((path (nerimux::socket-path "uidtest")))
        (expect (search (format nil "nerimux-~D/" (sb-posix:getuid)) path)))))

  ;; The global -S flag returns its path verbatim; -L replaces the socket name.
  (it "socket-path-honors-global-flag-overrides"
    (let ((nerimux::*socket-path-override* "/tmp/custom-nerimux.sock")
          (nerimux::*socket-name-override* nil))
      (expect (string= "/tmp/custom-nerimux.sock" (nerimux::socket-path "whatever"))))
    (let ((nerimux::*socket-path-override* nil)
          (nerimux::*socket-name-override* "mylabel"))
      (let ((path (nerimux::socket-path "ignored-name")))
        (expect (search "nerimux-mylabel.sock" path))
        (expect (null (search "ignored-name" path))))))

  ;;; -- stale-socket ------------------------------------------------------------

  ;; %stale-socket-p returns T for an existing file that refuses connections.
  (it "stale-socket-p-detects-dead-socket-file"
    (expect (null (nerimux::%stale-socket-p "/nonexistent/nerimux-stale-probe.sock")))
    (let ((path (format nil "~A/nerimux-stale-test-~D.sock"
                        (string-right-trim "/" (or (sb-ext:posix-getenv "TMPDIR") "/tmp"))
                        (random 1000000))))
      (unwind-protect
           (progn
             (with-open-file (s path :direction :output :if-does-not-exist :create)
               (declare (ignore s)))
             (expect (eq t (and (nerimux::%stale-socket-p path) t))))
        (ignore-errors (delete-file path)))))

  ;; %stale-socket-p returns NIL when a live listener accepts on the path.
  (it "stale-socket-p-live-listener-is-not-stale"
    (let ((path (nerimux/net::%make-probe-socket-path)))
      (if (nerimux/net:unix-socket-available-p)
          (let ((listener (nerimux/net:make-listener path)))
            (unwind-protect
                 (expect (null (nerimux::%stale-socket-p path)))
              (nerimux/net:close-socket listener)
              (ignore-errors (delete-file path))))
          (expect t :to-be-truthy))))

  ;;; -- ensure-server-running -----------------------------------------------

  ;; %ensure-server-running signals an error when the launch-and-poll attempt
  ;; never produces a socket (a crashed or never-started background server),
  ;; rather than returning silently as if it had succeeded — a real user
  ;; would otherwise see `new-session -d` "succeed" with no server running.
  (it "ensure-server-running-signals-when-socket-never-appears"
    (with-stubbed-fdefinition
        ((nerimux::%launch-server-and-poll-when-live
          (lambda (&rest args) (declare (ignore args)) nil)))
      (let ((nerimux::*socket-path-override*
              "/nonexistent-dir-xyz/nerimux-never-appears.sock")
            (nerimux::*socket-name-override* nil))
        (signals error
          (nerimux::%ensure-server-running "test-session")
          "must signal when the socket never appears after launch-and-poll"))))

  ;;; -- option-reader port installation ----------------------------------------

  ;; run-server must install the three option-reader ports the terminal layer
  ;; consults.  They were installed only on the deleted standalone startup path,
  ;; so on the surviving entry point `history-limit', `alternate-screen' and
  ;; `scroll-on-clear' were inert -- and inert SILENTLY, because every unset
  ;; fallback succeeds: the history limit quietly used a fixed constant, and
  ;; (or (null fn) ...) made alternate-screen unconditionally allowed.  Nothing
  ;; errored, so nothing caught it.
  ;;
  ;; Asserting functionp alone would not be enough -- a callback wired to the
  ;; wrong option would still be a function.  Each is called and checked against
  ;; the live option value it is supposed to read.
  (it "run-server-installs-the-option-reader-ports"
    (let ((nerimux/terminal:*history-limit-function* nil)
          (nerimux/terminal:*alternate-screen-enabled-function* nil)
          (nerimux/terminal:*scroll-on-clear-function* nil))
      (nerimux::%install-composition-root-hooks)
      (expect (functionp nerimux/terminal:*history-limit-function*))
      (expect (functionp nerimux/terminal:*alternate-screen-enabled-function*))
      (expect (functionp nerimux/terminal:*scroll-on-clear-function*))
      (expect (eql (nerimux/options:get-option "history-limit")
                   (funcall nerimux/terminal:*history-limit-function*)))
      (expect (eql (nerimux/options:get-option "alternate-screen")
                   (funcall nerimux/terminal:*alternate-screen-enabled-function*)))
      (expect (eql (nerimux/options:get-option "scroll-on-clear")
                   (funcall nerimux/terminal:*scroll-on-clear-function*)))))

  ;; The port must track the option, not capture its value at install time.
  (it "installed-history-limit-port-follows-the-live-option"
    (let ((nerimux/terminal:*history-limit-function* nil)
          (original (nerimux/options:get-option "history-limit")))
      (nerimux::%install-composition-root-hooks)
      (unwind-protect
           (progn
             (nerimux/options:set-option "history-limit" 4321)
             (expect (eql 4321 (funcall nerimux/terminal:*history-limit-function*))))
        (nerimux/options:set-option "history-limit" original))))

  ;; The config layer resolves `set-environment -t TARGET' through this hook
  ;; rather than calling NERIMUX::SERVER-FIND-SESSION, which would be the
  ;; APPLICATION layer reaching up into BOOTSTRAP.  The hook defaults to NIL and
  ;; every unresolved lookup answers NIL, so an uninstalled hook would look
  ;; exactly like an unknown target name -- silent, which is the failure mode the
  ;; three option ports above already demonstrated.  Hence this assertion lives
  ;; here, against the composition root, and not only in the config tests: the
  ;; config test helper binds the hook itself and therefore cannot prove that
  ;; run-server does.
  ;;
  ;; Checking FUNCTIONP alone would pass for a hook wired to the wrong function,
  ;; so the installed hook is called against a registry holding a known session.
  (it "run-server-installs-the-session-lookup-hook"
    (let ((nerimux/config:*session-lookup* nil))
      (nerimux::%install-composition-root-hooks)
      (expect (functionp nerimux/config:*session-lookup*))
      (let* ((session (make-fake-session :nwindows 1 :npanes 1))
             (nerimux::*server-sessions* (list (cons "hook-probe" session))))
        (expect (eq session (funcall nerimux/config:*session-lookup* "hook-probe")))
        (expect (null (funcall nerimux/config:*session-lookup* "no-such-session")))))))
