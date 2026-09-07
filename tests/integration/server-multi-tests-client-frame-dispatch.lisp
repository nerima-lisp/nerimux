(in-package #:nerimux/test)

(describe "client frame dispatch contract suite"
          (it "renders every modal and base view through one frame boundary"
              (with-fake-session (s)
                                 (let ((conn
                                        (%make-test-conn :rows 40 :cols 110)))
                                   (dolist (modal '(:help :process-log :picker))
                                     (setf (nerimux::client-conn-modal conn) modal)
                                     (when (eq modal :process-log)
                                       (setf (nerimux::client-conn-process-log
                                              conn) '(("git status" 0 ""))))
                                     (expect
                                      (nerimux::%render-client-frame s conn)
                                      :to-be-truthy))
                                   (nerimux::%open-client-transient conn #\P)
                                   (expect
                                    (nerimux::%render-client-frame s conn)
                                    :to-be-truthy)
                                   (setf (nerimux::client-conn-view conn) :status)
                                   (expect
                                    (nerimux::%render-client-frame s conn)
                                    :to-be-truthy)
                                   (setf (nerimux::client-conn-modal conn) nil)
                                   (dolist (view '(:repolist :status :pane))
                                     (setf (nerimux::client-conn-view conn) view)
                                     (expect
                                      (nerimux::%render-client-frame s conn)
                                      :to-be-truthy))))))

          (describe "ui command dispatch contract"
            (it "ui-command-dispatches-argument-fallbacks-and-picker-actions"
              (with-fake-session (s)
                (let ((conn (%make-test-conn))
                      (calls nil))
                  (with-stubbed-fdefinition
                      ((nerimux::%client-attach-target
                         (lambda (client args)
                           (declare (ignore client))
                           (push (list :attach args) calls)))
                       (nerimux::%client-refresh-workspace
                         (lambda (client)
                           (declare (ignore client))
                           (push :refresh calls)))
                       (nerimux::%select-client-tree-worktree
                         (lambda (client selector)
                           (declare (ignore client))
                           (push (list :select selector) calls)))
                       (nerimux::%open-client-picker
                         (lambda (client)
                           (declare (ignore client))
                           (push :open calls)))
                       (nerimux::%close-client-picker
                         (lambda (client)
                           (declare (ignore client))
                           (push :close calls)))
                       (nerimux::%transition-client-ui-mode
                       (lambda (client mode)
                           (declare (ignore client))
                           (push (list :mode mode) calls)))
                       (nerimux::%client-rebind-prefix
                         (lambda (client prefix)
                           (declare (ignore client))
                           (push (list :prefix prefix) calls)))
                       (nerimux::%select-client-tree-relative
                         (lambda (client delta)
                           (declare (ignore client))
                           (push (list :tree delta) calls)))
                       (nerimux::%move-client-picker-index
                         (lambda (client delta)
                           (declare (ignore client))
                           (push (list :picker delta) calls)))
                       (nerimux::%mark-dirty
                         (lambda ()
                           (push :dirty calls))))
                    (dolist (command '((:attach-target nil ("team/repo"))
                                       (:workspace-refresh nil nil)
                                       (:workspace-prefix nil ("C-x"))
                                       (:tree-select nil ("team/repo"))
                                       (:tree-next nil ("2"))
                                       (:picker-open nil nil)
                                       (:picker-close nil nil)
                                       (:mode nil ("input"))
                                       (:picker-next nil ("2"))))
                      (destructuring-bind (name target args) command
                        (expect (nerimux::%handle-client-ui-command
                                 s conn name target args))))
                    (expect (equal '((:picker 2) :dirty (:mode :input) :close :open
                                     (:tree 2) (:select "team/repo") (:prefix "C-x")
                                     :refresh (:attach ("team/repo")))
                                   calls)))))))
