(in-package #:nerimux/test)

(describe "runtime lifecycle"

  (it "uses a safe state filename"
    (let ((nerimux::*runtime-server-name* "origin/main worktree"))
      (expect (string= "origin_main_worktree"
                       (nerimux::%runtime-safe-server-name
                        nerimux::*runtime-server-name*)))))

  (it "resolves the log path under the NERIMUX_RUNTIME_STATE override"
    (with-temporary-posix-environment-variable
        ("NERIMUX_RUNTIME_STATE" "/tmp/nerimux-log-test-dir")
      (let ((nerimux::*runtime-server-name* "myserver"))
        (expect
         (string= "/tmp/nerimux-log-test-dir/nerimux/myserver.log"
                  (namestring (nerimux::%runtime-log-path "myserver")))))))

  (it "resolves the log path under XDG_STATE_HOME"
    (with-temporary-posix-environment-variable ("NERIMUX_RUNTIME_STATE" nil)
      (with-temporary-posix-environment-variable
          ("XDG_STATE_HOME" "/tmp/nerimux-log-xdg-test")
        (let ((nerimux::*runtime-server-name* "myserver"))
          (expect
           (string= "/tmp/nerimux-log-xdg-test/nerimux/myserver.log"
                    (namestring (nerimux::%runtime-log-path "myserver")))))))))
