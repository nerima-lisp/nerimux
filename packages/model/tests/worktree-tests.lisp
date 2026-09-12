(in-package #:nerimux/test/model)

(defun %make-prune-test-worktree (&rest options)
  (let* ((primary (nerimux/workspace-model:make-worktree :path "/work/main"))
         (repository (nerimux/workspace-model:make-repository
                      :main-worktree primary))
         (worktree (apply #'nerimux/workspace-model:make-worktree
                          :repository repository :path "/work/topic" options)))
    (setf (nerimux/workspace-model:worktree-repository primary) repository
          (nerimux/workspace-model:repository-worktrees repository)
          (list primary worktree))
    worktree))

(defun %prune-test-result (worktree)
  (multiple-value-list
   (nerimux/workspace-model:worktree-prune-classification worktree)))

(describe "worktree prune classification"
  (it "requires completion or an exited agent even with no live panes"
    (expect (equal '(:excluded :not-completed-or-agent-exited)
                   (%prune-test-result (%make-prune-test-worktree))))
    (expect (equal '(:candidate :clean)
                   (%prune-test-result (%make-prune-test-worktree :completed-p t)))))
  (it "excludes missing repository before all other conditions"
    (expect (equal '(:excluded :missing-repository)
                   (%prune-test-result
                    (nerimux/workspace-model:make-worktree
                     :locked-p t :missing-p t :completed-p t)))))
  (it "excludes primary by identity and by an independently reconstructed path"
    (let* ((worktree (%make-prune-test-worktree :completed-p t))
           (repository (nerimux/workspace-model:worktree-repository worktree)))
      (setf (nerimux/workspace-model:repository-main-worktree repository) worktree)
      (expect (equal '(:excluded :primary) (%prune-test-result worktree)))
      (setf (nerimux/workspace-model:repository-main-worktree repository)
            (nerimux/workspace-model:make-worktree
             :path (copy-seq (nerimux/workspace-model:worktree-path worktree))))
      (let ((primary-path
              (nerimux/workspace-model:worktree-path
               (nerimux/workspace-model:repository-main-worktree repository)))
            (path (nerimux/workspace-model:worktree-path worktree)))
        (expect (string= primary-path path))
        (expect (not (eq primary-path path))))
      (expect (equal '(:excluded :primary) (%prune-test-result worktree)))))
  (it "protects a locked nonbare completed worktree"
    (expect (equal '(:excluded :locked)
                   (%prune-test-result
                    (%make-prune-test-worktree :locked-p t :completed-p t)))))
  (it "protects any live pane including exited processes with an open fd"
    (dolist (agent-kind '(nil :codex))
      (let ((pane (nerimux/pane:make-pane
                   :fd 20 :agent-kind agent-kind :process-exited-p t)))
        (expect (nerimux/pane:pane-live-p pane))
        (expect (equal '(:excluded :live-pane)
                       (%prune-test-result
                        (%make-prune-test-worktree
                         :completed-p t
                         :panes (list (nerimux/pane:make-pane :fd -1) pane))))))))
  (it "protects a live historical agent outside the current pane list"
    (let* ((agent (nerimux/pane:make-pane :fd 21 :agent-kind :codex
                                        :process-exited-p t))
           (worktree (%make-prune-test-worktree :agent-pane agent)))
      (expect (null (nerimux/workspace-model:worktree-panes worktree)))
      (expect (eq :exited (nerimux/pane:worktree-agent-state worktree)))
      (expect (equal '(:excluded :live-pane) (%prune-test-result worktree)))))
  (it "accepts closed agent history but not a closed shell as agent completion"
    (let ((agent (nerimux/pane:make-pane :fd -1 :agent-kind :codex))
          (shell (nerimux/pane:make-pane :fd -1 :process-exited-p t)))
      (expect (equal '(:candidate :clean)
                     (%prune-test-result
                      (%make-prune-test-worktree :agent-pane agent))))
      (expect (equal '(:excluded :not-completed-or-agent-exited)
                     (%prune-test-result
                      (%make-prune-test-worktree :panes (list shell)))))))
  (it "separates missing metadata repair from dirty and conflicted candidates"
    (expect (equal '(:missing :metadata-repair-required)
                   (%prune-test-result
                    (%make-prune-test-worktree
                     :completed-p t :missing-p t :dirty-p nil :conflict-p nil))))
    (expect (equal '(:missing :metadata-repair-required)
                   (%prune-test-result
                    (%make-prune-test-worktree
                     :completed-p t :missing-p t :dirty-p t :conflict-p t))))
    (expect (equal '(:missing :metadata-repair-required)
                   (%prune-test-result (%make-prune-test-worktree :missing-p t))))
    (dolist (flags '((:dirty-p t) (:conflict-p t) (:dirty-p t :conflict-p t)))
      (expect (equal '(:candidate :confirmation-required)
                     (%prune-test-result
                      (apply #'%make-prune-test-worktree :completed-p t flags))))))
  (it "applies protection priority before missing metadata and candidate status"
    (let* ((pane (nerimux/pane:make-pane :fd 22))
           (worktree (%make-prune-test-worktree
                      :locked-p t :missing-p t :dirty-p t
                      :panes (list pane)))
           (repository (nerimux/workspace-model:worktree-repository worktree)))
      (setf (nerimux/workspace-model:repository-main-worktree repository) worktree)
      (expect (equal '(:excluded :primary) (%prune-test-result worktree)))
      (setf (nerimux/workspace-model:repository-main-worktree repository) nil)
      (expect (equal '(:excluded :locked) (%prune-test-result worktree)))
      (setf (nerimux/workspace-model:worktree-locked-p worktree) nil)
      (expect (equal '(:excluded :live-pane) (%prune-test-result worktree)))
      (setf (nerimux/pane:pane-fd pane) -1)
      (expect (equal '(:missing :metadata-repair-required)
                     (%prune-test-result worktree)))
      (setf (nerimux/workspace-model:worktree-completed-p worktree) t)
      (expect (equal '(:missing :metadata-repair-required)
                     (%prune-test-result worktree)))))
  (it "does not treat the Git prunable flag as eligibility or protection"
    (dolist (prunable '(nil t))
      (expect (equal '(:candidate :clean)
                     (%prune-test-result
                      (%make-prune-test-worktree
                       :completed-p t :prunable-p prunable))))
      (expect (equal '(:excluded :not-completed-or-agent-exited)
                     (%prune-test-result
                      (%make-prune-test-worktree :prunable-p prunable))))))
  (it "leaves worktree repository and pane snapshots unchanged across repeated calls"
    (let* ((agent (nerimux/pane:make-pane :fd -1 :agent-kind :codex))
           (worktree (%make-prune-test-worktree
                      :agent-pane agent :panes (list agent) :dirty-p t))
           (repository (nerimux/workspace-model:worktree-repository worktree))
           (panes (nerimux/workspace-model:worktree-panes worktree))
           (worktrees (nerimux/workspace-model:repository-worktrees repository))
           (primary (nerimux/workspace-model:repository-main-worktree repository)))
      (dotimes (iteration 2)
        (expect (equal '(:candidate :confirmation-required)
                       (%prune-test-result worktree))))
      (expect (eq repository (nerimux/workspace-model:worktree-repository worktree)))
      (expect (eq panes (nerimux/workspace-model:worktree-panes worktree)))
      (expect (equal (list agent) panes))
      (expect (eq agent (nerimux/workspace-model:worktree-agent-pane worktree)))
      (expect (= -1 (nerimux/pane:pane-fd agent)))
      (expect (not (nerimux/pane:pane-process-exited-p agent)))
      (expect (null (nerimux/pane:pane-worktree agent)))
      (expect (not (nerimux/workspace-model:worktree-completed-p worktree)))
      (expect (nerimux/workspace-model:worktree-dirty-p worktree))
      (expect (eq worktrees (nerimux/workspace-model:repository-worktrees repository)))
      (expect (equal (list primary worktree) worktrees))
      (expect (eq primary (nerimux/workspace-model:repository-main-worktree repository))))))

(describe "worktree agent lifecycle"
  (it "keeps shell exit separate from explicit completion and agent exit"
    (let* ((wt (nerimux/workspace-model:make-worktree))
           (shell (nerimux/pane:make-pane :fd 20)))
      (nerimux/pane:worktree-add-pane wt shell)
      (nerimux/pane:pane-mark-process-exit shell :status 0)
      (expect (eq :none (nerimux/pane:worktree-agent-state wt)))
      (expect (not (nerimux/workspace-model:worktree-completed-p wt)))
      (nerimux/workspace-model:worktree-complete wt)
      (expect (nerimux/workspace-model:worktree-completed-p wt))
      (expect (eq :none (nerimux/pane:worktree-agent-state wt)))))
  (it "rejects a second running agent and retains removed agent exit history"
    (let* ((wt (nerimux/workspace-model:make-worktree))
           (agent (nerimux/pane:make-pane :fd 20 :agent-kind :codex))
           (replacement (nerimux/pane:make-pane :fd 21 :agent-kind :claude)))
      (nerimux/pane:worktree-add-pane wt agent)
      (expect (eq :running (nerimux/pane:worktree-agent-state wt)))
      (expect (handler-case (progn (nerimux/pane:worktree-add-pane wt replacement) nil)
                (error () t)))
      (expect (null (nerimux/pane:pane-worktree replacement)))
      (setf (nerimux/pane:pane-fd agent) -1
            (nerimux/pane:pane-worktree agent) nil
            (nerimux/workspace-model:worktree-panes wt) nil)
      (expect (eq :exited (nerimux/pane:worktree-agent-state wt)))
      (expect (not (nerimux/workspace-model:worktree-completed-p wt)))
      (nerimux/pane:worktree-add-pane wt replacement)
      (nerimux/pane:pane-mark-process-exit agent :status 1)
      (expect (eq replacement (nerimux/workspace-model:worktree-agent-pane wt)))
      (expect (eq :running (nerimux/pane:worktree-agent-state wt)))))
  (it "only resumes with a successfully attached live pane"
    (let* ((wt (nerimux/workspace-model:make-worktree :completed-p t))
           (failed (nerimux/pane:make-pane :startup-failed-p t))
           (live (nerimux/pane:make-pane :fd 22)))
      (nerimux/pane:worktree-add-pane wt failed)
      (nerimux/pane:worktree-resume wt failed)
      (expect (nerimux/workspace-model:worktree-completed-p wt))
      (nerimux/pane:worktree-add-pane wt live)
      (nerimux/pane:worktree-resume wt live)
      (expect (not (nerimux/workspace-model:worktree-completed-p wt))))))

(describe "worktree-pane-link"
          (it "keeps the pane back-pointer and avoids duplicate attachments"
              (let* ((worktree
                      (nerimux/workspace-model:make-worktree :path
                                                             "/work/nerimux"))
                     (pane (nerimux/pane:make-pane :id 7)))
                (nerimux/pane:worktree-add-pane worktree pane)
                (nerimux/pane:worktree-add-pane worktree pane)
                (expect (eq worktree (nerimux/pane:pane-worktree pane)))
                (expect
                 (= 1
                    (length (nerimux/workspace-model:worktree-panes worktree))))
                (expect
                 (eq pane
                     (first (nerimux/workspace-model:worktree-panes worktree)))))))

(describe "worktree-values"
          (it "retains defaults when optional values are omitted"
              (let ((worktree (nerimux/workspace-model:make-worktree)))
                (expect
                 (equal "||" (nerimux/workspace-model:worktree-id worktree)))
                (expect
                 (equal "" (nerimux/workspace-model:worktree-path worktree)))
                (expect
                 (null (nerimux/workspace-model:worktree-panes worktree)))
                (expect (= 0 (nerimux/workspace-model:worktree-ahead worktree)))
                (expect
                 (= 0 (nerimux/workspace-model:worktree-behind worktree)))
                (expect
                 (not (nerimux/workspace-model:worktree-dirty-p worktree)))))
          (it "keeps raw constructor defaults explicit"
              (let ((worktree (nerimux/workspace-model::%make-worktree)))
                (expect
                 (equal "" (nerimux/workspace-model:worktree-id worktree)))
                (expect
                 (null (nerimux/workspace-model:worktree-repository worktree)))
                (expect
                 (equal "" (nerimux/workspace-model:worktree-path worktree)))
                (expect
                 (null (nerimux/workspace-model:worktree-branch worktree)))
                (expect (null (nerimux/workspace-model:worktree-head worktree)))
                (expect
                 (null (nerimux/workspace-model:worktree-status worktree)))
                (expect
                 (null (nerimux/workspace-model:worktree-panes worktree)))
                (expect
                 (null (nerimux/workspace-model:worktree-dirty-p worktree)))
                (expect
                 (null (nerimux/workspace-model:worktree-conflict-p worktree)))
                (expect (= 0 (nerimux/workspace-model:worktree-ahead worktree)))
                (expect
                 (= 0 (nerimux/workspace-model:worktree-behind worktree)))
                (expect
                 (null (nerimux/workspace-model:worktree-locked-p worktree)))
                (expect
                 (null (nerimux/workspace-model:worktree-prunable-p worktree)))
                (expect
                 (null (nerimux/workspace-model:worktree-missing-p worktree)))))
          (it "normalizes pathname values and copies pane collections"
              (let ((panes (list (nerimux/pane:make-pane :id 1))))
                (let ((worktree
                       (nerimux/workspace-model:make-worktree :path
                                                              #p"/work/nerimux"
                                                              :branch
                                                              "main"
                                                              :head
                                                              42
                                                              :panes
                                                              panes)))
                  (expect
                   (equal "/work/nerimux"
                          (nerimux/workspace-model:worktree-path worktree)))
                  (expect
                   (equal "/work/nerimux|main|42"
                          (nerimux/workspace-model:worktree-id worktree)))
                  (expect
                   (equal panes
                          (nerimux/workspace-model:worktree-panes worktree)))
                  (expect
                   (not
                    (eq panes (nerimux/workspace-model:worktree-panes worktree)))))))
          (it "uses empty components when generating a key from absent values"
              (expect
               (equal "||" (nerimux/workspace-model::worktree-key nil nil nil)))))
