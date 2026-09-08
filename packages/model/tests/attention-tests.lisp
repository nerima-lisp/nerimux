(in-package #:nerimux/test/model)

(describe "worktree attention"
          (it "reports every active attention reason in stable order"
              (let ((worktree
                     (nerimux/workspace-model:make-worktree :id
                                                            "attention"
                                                            :path
                                                            "/tmp/attention"
                                                            :branch
                                                            "feature/attention"
                                                            :dirty-p
                                                            t
                                                            :conflict-p
                                                            t
                                                            :ahead
                                                            2
                                                            :behind
                                                            1
                                                            :missing-p
                                                            t)))
                (expect
                 (equal '(:conflict :dirty :ahead :behind :missing)
                        (nerimux/pane:worktree-attention-reasons worktree)))
                (expect (nerimux/workspace-model:worktree-attention-p worktree))))
          (it "projects attention from worktrees to their organization"
              (let* ((organization
                      (nerimux/workspace-model:make-organization :id "org"))
                     (repository
                      (nerimux/workspace-model:make-repository :id
                                                               "repo"
                                                               :organization
                                                               organization))
                     (clean
                      (nerimux/workspace-model:make-worktree :id
                                                             "clean"
                                                             :repository
                                                             repository))
                     (attention
                      (nerimux/workspace-model:make-worktree :id
                                                             "attention"
                                                             :repository
                                                             repository
                                                             :dirty-p
                                                             t)))
                (nerimux/workspace-model:organization-add-repository
                 organization
                 repository)
                (nerimux/workspace-model:repository-add-worktree repository
                                                                 clean)
                (nerimux/workspace-model:repository-add-worktree repository
                                                                 attention)
                (let ((worktrees
                       (nerimux/pane:organization-attention-worktrees
                        organization)))
                  (expect (= 1 (length worktrees)))
                  (expect (eq attention (first worktrees)))
                  (expect
                   (= 1
                      (nerimux/workspace-model:organization-attention-count
                       organization))))))
          (it "tracks pane output, lifecycle failures, and focus clearing"
              (let ((pane (nerimux/pane:make-pane :id 7 :title "editor")))
                (nerimux/pane:pane-mark-output pane #(72 105 10))
                (expect (nerimux/pane:pane-unread-output-p pane))
                (expect (search "Hi" (nerimux/pane:pane-last-output pane)))
                (expect
                 (member :unread-output
                         (nerimux/pane:pane-attention-reasons pane)))
                (nerimux/pane:pane-mark-bell pane)
                (expect
                 (member :bell (nerimux/pane:pane-attention-reasons pane)))
                (nerimux/pane:pane-mark-process-exit pane :status 2)
                (expect (nerimux/pane:pane-process-exited-p pane))
                (expect (nerimux/pane:pane-non-zero-exit-p pane))
                (nerimux/pane:pane-mark-focused pane)
                (expect (null (nerimux/pane:pane-unread-output-p pane)))
                (expect
                 (member :bell (nerimux/pane:pane-attention-reasons pane)))
                (expect
                 (member :process-exited
                         (nerimux/pane:pane-attention-reasons pane)))
                (expect (integerp (nerimux/pane:pane-last-focused-time pane)))
                (nerimux/pane:pane-mark-startup-failure pane)
                (expect
                 (member :startup-failed
                         (nerimux/pane:pane-attention-reasons pane)))))
          (it
           "includes :pane in worktree attention reasons when an attached pane needs attention"
           (let ((worktree
                  (nerimux/workspace-model:make-worktree :id "has-pane"))
                 (pane (nerimux/pane:make-pane :id 1 :title "editor")))
             (nerimux/pane:worktree-add-pane worktree pane)
             (nerimux/pane:pane-mark-bell pane)
             (expect
              (member :pane (nerimux/pane:worktree-attention-reasons worktree)))
             (expect (nerimux/workspace-model:worktree-attention-p worktree))))
          (it
           "projects pane-driven worktree attention up to the organization count"
           (let* ((organization
                   (nerimux/workspace-model:make-organization :id "org"))
                  (repository
                   (nerimux/workspace-model:make-repository :id
                                                            "repo"
                                                            :organization
                                                            organization))
                  (worktree
                   (nerimux/workspace-model:make-worktree :id
                                                          "has-pane"
                                                          :repository
                                                          repository))
                  (pane (nerimux/pane:make-pane :id 1 :title "editor")))
             (nerimux/pane:worktree-add-pane worktree pane)
             (nerimux/pane:pane-mark-bell pane)
             (nerimux/workspace-model:organization-add-repository organization
                                                                  repository)
             (nerimux/workspace-model:repository-add-worktree repository
                                                              worktree)
             (expect
              (= 1
                 (nerimux/workspace-model:organization-attention-count
                  organization)))))
          (it "does not report :pane when the attached pane needs no attention"
              (let ((worktree
                     (nerimux/workspace-model:make-worktree :id "quiet-pane"))
                    (pane (nerimux/pane:make-pane :id 1 :title "editor")))
                (nerimux/pane:worktree-add-pane worktree pane)
                (expect
                 (null
                  (member :pane
                          (nerimux/pane:worktree-attention-reasons worktree))))
                (expect
                 (null (nerimux/workspace-model:worktree-attention-p worktree))))))

(describe "agent waiting state"
          (it "marks an agent worktree waiting on process exit"
              (let* ((worktree
                       (nerimux/workspace-model:make-worktree :id "waiting-exit"))
                     (pane
                       (nerimux/pane:make-pane :id 1 :agent-kind :codex)))
                (nerimux/pane:worktree-add-pane worktree pane)
                (nerimux/pane:pane-mark-process-exit pane :status 1)
                (expect (nerimux/workspace-model:worktree-waiting-p worktree))
                (expect
                 (string= "process exited"
                          (nerimux/workspace-model:worktree-waiting-message
                           worktree)))
                (expect
                 (integerp
                  (nerimux/workspace-model:worktree-waiting-time worktree)))))
          (it "marks an agent worktree waiting on an OSC notification"
              (let* ((worktree
                       (nerimux/workspace-model:make-worktree :id "waiting-osc"))
                     (pane
                       (nerimux/pane:make-pane :id 2 :agent-kind :claude)))
                (nerimux/pane:worktree-add-pane worktree pane)
                (nerimux/pane:pane-record-notification
                 pane
                 #(27 93 57 57 59 105 61 49 59 84 59 97 112 112 114 111 118 97 108 59)
                 (format nil "approval needed~%ignored")
                 100)
                (expect (nerimux/workspace-model:worktree-waiting-p worktree))
                (expect
                 (string= "approval needed"
                          (nerimux/workspace-model:worktree-waiting-message
                           worktree)))))
          (it "does not mark ordinary terminal panes waiting"
              (let* ((worktree
                       (nerimux/workspace-model:make-worktree :id "terminal"))
                     (pane (nerimux/pane:make-pane :id 3)))
                (nerimux/pane:worktree-add-pane worktree pane)
                (nerimux/pane:pane-mark-bell pane)
                (nerimux/pane:pane-record-notification pane #(27 93 57 57) "message" 100)
                (expect
                 (null
                  (nerimux/workspace-model:worktree-waiting-p worktree)))))
          (it "clears waiting when the agent pane is focused"
              (let* ((worktree
                       (nerimux/workspace-model:make-worktree :id "waiting-focus"))
                     (pane
                       (nerimux/pane:make-pane :id 4 :agent-kind :codex)))
                (nerimux/pane:worktree-add-pane worktree pane)
                (nerimux/pane:pane-mark-bell pane)
                (nerimux/pane:pane-mark-focused pane)
                (expect
                 (null
                  (nerimux/workspace-model:worktree-waiting-p worktree))))))
