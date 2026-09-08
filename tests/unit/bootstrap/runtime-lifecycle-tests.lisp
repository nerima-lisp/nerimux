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

(describe "runtime persistence"

          (it "round-trips persisted layout, roles, completion, and expansion"
              (let* ((root (merge-pathnames
                            (format nil "nerimux-state-roundtrip-~D/"
                                    (random 1000000))
                            (host-kit:temporary-directory)))
                     (worktree-path (merge-pathnames "worktree/" root)))
                (ensure-directories-exist worktree-path)
                (unwind-protect
                     (with-runtime-state-environment ((namestring root) nil)
                       (let* ((first-pane (make-pane :id 1 :fd -1 :pid -1
                                                      :width 40 :height 24
                                                      :screen (make-screen 40 24)))
                              (second-pane (make-pane :id 2 :fd -1 :pid -1
                                                       :width 40 :height 24
                                                       :screen (make-screen 40 24)))
                              (worktree
                                (nerimux/workspace-model:make-worktree
                                 :id "roundtrip"
                                 :path (namestring worktree-path)
                                 :completed-p t))
                              (window
                                (make-window
                                 :id 1
                                 :name "roundtrip"
                                 :width 81
                                 :height 24
                                 :panes (list first-pane second-pane)
                                 :tree (make-layout-split
                                        :h
                                        (make-layout-leaf first-pane)
                                        (make-layout-leaf second-pane)
                                        3/5)
                                 :active first-pane))
                              (session
                                (make-session :id 1
                                              :name "0"
                                              :windows (list window)
                                              :active window)))
                         (setf (pane-window first-pane) window
                               (pane-window second-pane) window
                               (nerimux/pane:pane-role second-pane) :agent
                               (nerimux/pane:pane-agent-kind second-pane) :claude)
                         (nerimux/pane:worktree-add-pane worktree first-pane)
                         (nerimux/pane:worktree-add-pane worktree second-pane)
                         (window-refresh-panes window)
                         (let ((nerimux::*runtime-persistence-enabled-p* t)
                               (nerimux::*runtime-state-signature* nil)
                               (nerimux::*runtime-server-name* "roundtrip")
                               (nerimux::*workspace-expanded-node-ids*
                                 (make-hash-table :test #'equal)))
                           (setf (gethash (list :repository "repo")
                                          nerimux::*workspace-expanded-node-ids*)
                                 t)
                           (nerimux::%persist-runtime-state session :force t)
                           (with-stubbed-fdefinition
                               ((nerimux/pane:%fork-pane
                                  (lambda (ignored-session id x y cols rows
                                           &key start-dir default-command)
                                    (declare (ignore ignored-session x y
                                                     start-dir default-command))
                                    (make-pane :id id
                                               :fd -1
                                               :pid -1
                                               :width cols
                                               :height rows
                                               :screen (make-screen cols rows))))))
                             (let ((restored
                                     (nerimux::%runtime-session-from-state
                                      "roundtrip")))
                               (expect restored)
                               (expect (= 1 (length (session-windows restored))))
                               (let* ((restored-window
                                        (first (session-windows restored)))
                                      (restored-panes
                                        (window-panes restored-window))
                                      (restored-agent (second restored-panes))
                                      (restored-worktree
                                        (nerimux/pane:pane-worktree
                                         (first restored-panes))))
                                 (expect (= 2 (length restored-panes)))
                                 (expect (= 3/5
                                            (nerimux/layout:layout-split-ratio
                                             (window-tree restored-window))))
                                 (expect (nerimux/workspace-model:worktree-completed-p
                                          restored-worktree))
                                 (expect (eq :terminal
                                              (nerimux/pane:pane-role
                                               restored-agent)))
                                 (expect (null
                                          (nerimux/pane:pane-agent-kind
                                           restored-agent)))
                                 (expect (equal '("repo")
                                                (nerimux::%runtime-state-expanded-repository-ids))))))))
                  (ignore-errors
                    (uiop:delete-directory-tree root :validate t)))))

          (it "includes hidden panes when persisting a zoomed window"
              (let* ((first-pane (make-pane :id 1 :fd -1 :pid -1
                                             :width 40 :height 24
                                             :screen (make-screen 40 24)))
                     (second-pane (make-pane :id 2 :fd -1 :pid -1
                                              :width 40 :height 24
                                              :screen (make-screen 40 24)))
                     (worktree (nerimux/workspace-model:make-worktree
                                :id "zoomed"
                                :path "zoomed"))
                     (window (make-window
                              :id 1
                              :name "zoomed"
                              :width 81
                              :height 24
                              :panes (list first-pane second-pane)
                              :tree (make-layout-split
                                     :h
                                     (make-layout-leaf first-pane)
                                     (make-layout-leaf second-pane))
                              :active first-pane)))
                (setf (pane-window first-pane) window
                      (pane-window second-pane) window)
                (nerimux/pane:worktree-add-pane worktree first-pane)
                (nerimux/pane:worktree-add-pane worktree second-pane)
                (window-refresh-panes window)
                (nerimux/window:window-zoom-toggle window)
                (let ((record (nerimux::%runtime-state-window-record
                               window worktree)))
                  (expect (getf record :zoom))
                  (expect (= 2 (length (getf record :panes)))))))

          (it "quarantines malformed state without aborting startup"
              (let ((root (merge-pathnames
                           (format nil "nerimux-state-invalid-~D/"
                                   (random 1000000))
                           (host-kit:temporary-directory))))
                (unwind-protect
                     (with-runtime-state-environment ((namestring root) nil)
                       (let ((path (nerimux::%runtime-state-path "invalid")))
                         (ensure-directories-exist path)
                         (with-open-file (stream path
                                                 :direction :output
                                                 :if-exists :supersede)
                           (write-string "(:nerimux-state :version 99)" stream))
                         (expect (null (nerimux::%runtime-session-from-state
                                        "invalid")))
                         (expect (null (probe-file path)))
                         (expect (probe-file
                                  (pathname (format nil "~A.invalid1"
                                                     (namestring path)))))))
                  (ignore-errors
                    (uiop:delete-directory-tree root :validate t)))))

          (it "reports a missing worktree once and continues"
              (let* ((root (merge-pathnames
                            (format nil "nerimux-state-missing-~D/"
                                    (random 1000000))
                            (host-kit:temporary-directory)))
                     (missing (namestring (merge-pathnames "gone/" root))))
                (unwind-protect
                     (with-runtime-state-environment ((namestring root) nil)
                       (let ((path (nerimux::%runtime-state-path "missing")))
                         (ensure-directories-exist path)
                         (with-open-file (stream path
                                                 :direction :output
                                                 :if-exists :supersede)
                           (write (list :nerimux-state
                                        :version 1
                                        :worktrees
                                        (list (list :path missing
                                                     :completed nil
                                                     :windows nil))
                                        :expanded nil)
                                  :stream stream))
                         (let ((output
                                 (with-output-to-string (log)
                                   (let ((*error-output* log))
                                     (nerimux::%runtime-session-from-state
                                      "missing")))))
                           (expect (= 1 (count #\Newline output)))
                           (expect (search "skipping missing restored worktree"
                                           output)))))
                  (ignore-errors
                    (uiop:delete-directory-tree root :validate t)))))

          (it "writes one atomic state file below one megabyte for 100 worktrees"
              (let* ((root (merge-pathnames
                            (format nil "nerimux-state-size-~D/"
                                    (random 1000000))
                            (host-kit:temporary-directory))))
                (unwind-protect
                     (with-runtime-state-environment ((namestring root) nil)
                         (let ((windows nil))
                         (loop for index from 1 to 100
                               for pane = (make-pane
                                           :id 1 :fd -1 :pid -1
                                           :width 80 :height 24
                                           :screen (make-screen 80 24))
                               for path = (format nil "worktree-~D" index)
                               for worktree =
                                 (nerimux/workspace-model:make-worktree
                                  :id path :path path)
                               for window =
                                 (make-window
                                  :id index :name path :width 80 :height 24
                                  :panes (list pane)
                                  :tree (make-layout-leaf pane)
                                  :active pane)
                               do (setf (pane-window pane) window)
                                  (nerimux/pane:worktree-add-pane worktree pane)
                                  (push window windows))
                         (let ((session (make-session :id 1 :name "0"
                                                      :windows windows
                                                      :active (first windows)))
                               (nerimux::*runtime-persistence-enabled-p* t)
                               (nerimux::*runtime-state-signature* nil)
                               (nerimux::*runtime-server-name* "size"))
                           (nerimux::%persist-runtime-state session :force t)
                           (let ((path (nerimux::%runtime-state-path "size")))
                             (expect (probe-file path))
                             (expect (< (with-open-file (stream path)
                                          (file-length stream))
                                        (* 1024 1024)))
                             (expect (null (probe-file
                                            (pathname (format nil "~A.tmp"
                                                               (namestring path))))))))))
                  (ignore-errors
                    (uiop:delete-directory-tree root :validate t))))))
