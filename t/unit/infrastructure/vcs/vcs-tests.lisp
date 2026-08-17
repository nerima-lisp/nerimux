(in-package #:cl-tmux/test)

(describe "vcs worktree status"
  (it "marks an absent worktree without querying the adapter"
    (let* ((path
             (namestring
              (merge-pathnames
               (format nil "cl-tmux-missing-worktree-~D/" (random 1000000))
               (host-kit:temporary-directory))))
           (repository
             (cl-tmux/model:make-repository
              :specification "workspace-owner/project"
              :local-path path))
           (worktree
             (cl-tmux/model:make-worktree
              :repository repository
              :path path
              :branch "feature/ui"
              :status :stale
              :dirty-p t
              :conflict-p t
              :ahead 3
              :behind 2)))
      (cl-tmux/model:repository-add-worktree repository worktree)
      (expect (null (probe-file path)))
      (cl-tmux/vcs:worktree-status worktree)
      (expect (cl-tmux/model:worktree-missing-p worktree))
      (expect (null (cl-tmux/model:worktree-status worktree)))
      (expect (not (cl-tmux/model:worktree-dirty-p worktree)))
      (expect (not (cl-tmux/model:worktree-conflict-p worktree)))
      (expect (zerop (cl-tmux/model:worktree-ahead worktree)))
      (expect (zerop (cl-tmux/model:worktree-behind worktree)))
      (expect (not (cl-tmux/model:repository-dirty-p repository)))
      (expect (not (cl-tmux/model:repository-conflict-p repository))))))

(describe "async vcs refresh"
  (it "returns before slow repository status workers complete"
    (let* ((repositories
             (loop for index from 1 to 3
                   collect
                   (cl-tmux/model:make-repository
                    :specification (format nil "workspace-owner/project-~D" index)
                    :local-path (format nil "/tmp/project-~D" index))))
           (completed nil)
           (start (get-internal-real-time))
           (threads
             (cl-tmux/vcs:refresh-repositories-async
              repositories
              :refresh-function (lambda (repository)
                                  (declare (ignore repository))
                                  (sleep 0.2))
              :on-complete (lambda (refreshed)
                             (declare (ignore refreshed))
                             (setf completed t))))
           (dispatch-ms
             (* 1000.0
                (/ (- (get-internal-real-time) start)
                   internal-time-units-per-second)))
           (deadline (+ (get-internal-real-time)
                        (* 2 internal-time-units-per-second))))
      (loop until completed
            while (< (get-internal-real-time) deadline)
            do (sleep 0.01))
      (expect (= 3 (length threads)))
      (expect (< dispatch-ms 100.0))
      (expect completed)))

  (it "keeps the workspace status entry point non-blocking"
    (let* ((repositories
             (loop for index from 1 to 3
                   collect
                   (cl-tmux/model:make-repository
                    :specification (format nil "workspace-owner/project-~D" index)
                    :local-path (format nil "/tmp/project-~D" index))))
           (organization
             (cl-tmux/model:make-organization
              :host "workspace-owner"
              :name "workspace"
              :repositories repositories))
           (completed nil)
           (start (get-internal-real-time))
           (threads
             (cl-tmux/vcs:refresh-workspace-status-async
              :organizations (list organization)
              :refresh-function (lambda (repository)
                                  (declare (ignore repository))
                                  (sleep 0.2))
              :on-complete (lambda (refreshed)
                             (declare (ignore refreshed))
                             (setf completed t))))
           (dispatch-ms
             (* 1000.0
                (/ (- (get-internal-real-time) start)
                   internal-time-units-per-second)))
           (deadline (+ (get-internal-real-time)
                        (* 2 internal-time-units-per-second))))
      (expect (= 3 (length threads)))
      (expect (not completed))
      (expect (< dispatch-ms 100.0))
      (loop until completed
            while (< (get-internal-real-time) deadline)
            do (sleep 0.01))
      (expect completed))))

(describe "async vcs scan errors"
  (it "reports a scan failure without leaking an unhandled worker error"
    (let ((original (fdefinition 'cl-tmux/vcs::%vcs-call))
          (condition-seen nil)
          (deadline (+ (get-internal-real-time)
                       (* 2 internal-time-units-per-second))))
      (unwind-protect
           (progn
             (setf (fdefinition 'cl-tmux/vcs::%vcs-call)
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (error "synthetic ghq failure")))
             (cl-tmux/vcs:scan-repositories-async
              :on-error (lambda (condition)
                          (setf condition-seen condition)))
             (loop until condition-seen
                   while (< (get-internal-real-time) deadline)
                   do (sleep 0.01))
             (expect condition-seen))
        (setf (fdefinition 'cl-tmux/vcs::%vcs-call) original)))))
