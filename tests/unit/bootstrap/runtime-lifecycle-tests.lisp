(in-package #:nerimux/test)

(defmacro with-runtime-state-environment ((runtime-state xdg-state) &body body)
  `(with-temporary-posix-environment-variable
       ("NERIMUX_RUNTIME_STATE" ,runtime-state)
     (with-temporary-posix-environment-variable
         ("XDG_STATE_HOME" ,xdg-state)
       ,@body)))

(describe "runtime lifecycle"
          (it "uses a safe state filename"
              (let ((nerimux::*runtime-server-name* "origin/main worktree"))
                (expect
                 (string= "origin_main_worktree"
                          (nerimux::%runtime-safe-server-name
                           nerimux::*runtime-server-name*)))))
          (it "resolves the log path under the NERIMUX_RUNTIME_STATE override"
              (with-runtime-state-environment
                  ("/tmp/nerimux-log-test-dir" nil)
               (let ((nerimux::*runtime-server-name* "myserver"))
                 (expect
                  (string= "/tmp/nerimux-log-test-dir/nerimux/myserver.log"
                           (namestring (nerimux::%runtime-log-path "myserver")))))))
          (it "falls back when NERIMUX_RUNTIME_STATE is empty"
              (with-runtime-state-environment
                  ("" "/tmp/nerimux-log-empty-override")
                (expect
                 (string= "/tmp/nerimux-log-empty-override/nerimux/myserver.log"
                          (namestring
                           (nerimux::%runtime-log-path "myserver"))))))
          (it "resolves the log path under XDG_STATE_HOME"
              (with-runtime-state-environment
                  (nil "/tmp/nerimux-log-xdg-test")
                (let ((nerimux::*runtime-server-name* "myserver"))
                  (expect
                   (string= "/tmp/nerimux-log-xdg-test/nerimux/myserver.log"
                            (namestring (nerimux::%runtime-log-path "myserver")))))))
              (it
               "uses the home state directory when no environment override is set"
               (with-runtime-state-environment
                   (nil nil)
                 (expect
                  (search ".local/state/nerimux/myserver.log"
                          (namestring (nerimux::%runtime-log-path "myserver"))))))
          (it "uses the home state directory when XDG_STATE_HOME is empty"
                  (with-runtime-state-environment
                      (nil "")
                    (expect
                     (search ".local/state/nerimux/myserver.log"
                             (namestring
                             (nerimux::%runtime-log-path "myserver"))))))
          (it "uses default values for empty server names"
                  (expect
                   (string= "default" (nerimux::%runtime-safe-server-name nil)))
                  (expect
                   (string= "default" (nerimux::%runtime-safe-server-name ""))))
          (it "preserves safe punctuation and replaces unsafe characters"
              (expect
               (string= "a-b_c.d__"
                        (nerimux::%runtime-safe-server-name "a-b_c.d!?")))))
