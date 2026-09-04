(in-package #:nerimux/test/vcs)

(describe "prune-worktrees default dry-run"
  (it "defaults to a dry run when :dry-run is omitted entirely"
    (let ((captured-arguments nil)
          (repository
            (nerimux/workspace-model:make-repository
             :specification "workspace-owner/project"
             :local-path "/tmp/nerimux-prune-default-dry-run-test")))
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (&rest arguments)
               (declare (ignore arguments))
               :fake-backend-repository))
           (vcs-kit:vcs-worktree
             (lambda (backend-repository &rest arguments)
               (declare (ignore backend-repository))
               (setf captured-arguments arguments)
               ""))
           (vcs-kit:vcs-list-worktrees
             (lambda (&rest arguments)
               (declare (ignore arguments))
               nil)))
        (nerimux/vcs:prune-worktrees repository)
        (expect (member "--dry-run" captured-arguments :test #'equal))))))
