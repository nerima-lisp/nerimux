(in-package #:nerimux/test)

(describe "server-multi-selection-suite"

  (it "resolves picker worktrees through repository and organization fallbacks"
    (let* ((empty-organization
             (nerimux/workspace-model:make-organization))
           (repository
             (nerimux/workspace-model:make-repository))
           (worktree
             (nerimux/workspace-model:make-worktree :path "/tmp/nerimux-wt"))
           (organization
             (nerimux/workspace-model:make-organization)))
      (nerimux/workspace-model:organization-add-repository
       organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (setf (nerimux/workspace-model:repository-main-worktree repository) nil)
      (expect (eq worktree
                  (nerimux::%picker-item-worktree
                   (nerimux/picker::%make-picker-item
                    :repository repository))))
      (expect (null (nerimux::%picker-item-worktree
                     (nerimux/picker::%make-picker-item
                      :organization empty-organization))))
      (expect (eq worktree
                  (nerimux::%picker-item-worktree
                   (nerimux/picker::%make-picker-item
                    :organization organization))))))

  (it "does not search panes when picker worktree is absent"
    (let ((session (make-session :id 1 :name "0")))
      (expect (null (nerimux::%client-worktree-pane session nil)))))

  (it "returns no pane when picker worktree is not attached"
    (let* ((session (make-session :id 1 :name "0"))
           (worktree (nerimux/workspace-model:make-worktree)))
      (expect (null (nerimux::%client-worktree-pane session worktree)))))

  (it "main-thread-callback-queue-preserves-order"
    (with-main-thread-callback-queue (events)
      (nerimux::%enqueue-main-thread-callback
       (lambda () (setf events (nconc events (list :first)))))
      (nerimux::%enqueue-main-thread-callback
       (lambda () (setf events (nconc events (list :second)))))
      (nerimux::%drain-main-thread-callbacks)
      (expect (equal '(:first :second) events))))

  (it "main-thread-callback-queue-continues-after-callback-error"
    (with-main-thread-callback-queue (events)
      (nerimux::%enqueue-main-thread-callback
       (lambda () (error "expected callback failure")))
      (nerimux::%enqueue-main-thread-callback
       (lambda () (push :after-error events)))
      (nerimux::%drain-main-thread-callbacks)
      (expect (equal '(:after-error) events)))))
