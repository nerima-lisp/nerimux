(in-package #:nerimux/test)

(describe "vcs worktree status"
  (it "marks an absent worktree without querying the adapter"
    (let* ((path
             (namestring
              (merge-pathnames
               (format nil "nerimux-missing-worktree-~D/" (random 1000000))
               (host-kit:temporary-directory))))
           (repository
             (nerimux/model:make-repository
              :specification "workspace-owner/project"
              :local-path path))
           (worktree
             (nerimux/model:make-worktree
              :repository repository
              :path path
              :branch "feature/ui"
              :status :stale
              :dirty-p t
              :conflict-p t
              :ahead 3
              :behind 2)))
      (nerimux/model:repository-add-worktree repository worktree)
      (expect (null (probe-file path)))
      (nerimux/vcs:worktree-status worktree)
      (expect (nerimux/model:worktree-missing-p worktree))
      (expect (null (nerimux/model:worktree-status worktree)))
      (expect (not (nerimux/model:worktree-dirty-p worktree)))
      (expect (not (nerimux/model:worktree-conflict-p worktree)))
      (expect (zerop (nerimux/model:worktree-ahead worktree)))
      (expect (zerop (nerimux/model:worktree-behind worktree)))
      (expect (not (nerimux/model:repository-dirty-p repository)))
      (expect (not (nerimux/model:repository-conflict-p repository))))))

(describe "async vcs refresh"
  (it "returns before slow repository status workers complete"
    (let* ((repositories
             (loop for index from 1 to 3
                   collect
                   (nerimux/model:make-repository
                    :specification (format nil "workspace-owner/project-~D" index)
                    :local-path (format nil "/tmp/project-~D" index))))
           (completed nil)
           (start (get-internal-real-time))
           (threads
             (nerimux/vcs:refresh-repositories-async
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
                   (nerimux/model:make-repository
                    :specification (format nil "workspace-owner/project-~D" index)
                    :local-path (format nil "/tmp/project-~D" index))))
           (organization
             (nerimux/model:make-organization
              :host "workspace-owner"
              :name "workspace"
              :repositories repositories))
           (completed nil)
           (start (get-internal-real-time))
           (threads
             (nerimux/vcs:refresh-workspace-status-async
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
    (let ((original (fdefinition 'nerimux/vcs::%vcs-call))
          (condition-seen nil)
          (deadline (+ (get-internal-real-time)
                       (* 2 internal-time-units-per-second))))
      (unwind-protect
           (progn
             (setf (fdefinition 'nerimux/vcs::%vcs-call)
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (error "synthetic ghq failure")))
             (nerimux/vcs:scan-repositories-async
              :on-error (lambda (condition)
                          (setf condition-seen condition)))
             (loop until condition-seen
                   while (< (get-internal-real-time) deadline)
                   do (sleep 0.01))
             (expect condition-seen))
        (setf (fdefinition 'nerimux/vcs::%vcs-call) original)))))

;;; %preserve-pane-associations runs on EVERY catalog refresh, via
;;; set-workspace-organizations.  A refresh replaces the whole organization tree
;;; with freshly-scanned structs, so a pane already attached to a worktree would
;;; lose its binding unless the association is re-established by matching the old
;;; worktree's id/path against the new tree.
;;;
;;; The first of these cases used to live in t/unit/domain/ports/vcs-port-tests.lisp,
;;; misfiled under the VCS *port* — an abstraction that was never installed and
;;; had no production callers, and which was deleted.  The case moved here because
;;; it never tested the port: it tests live nerimux/vcs infrastructure.  The
;;; no-match case is new; that branch was never covered.

(describe "workspace catalog pane preservation"

  ;; A refresh that produces an equivalent worktree (same path, new head) must
  ;; re-bind the pane to the NEW struct — matching by id/path, not by identity.
  (it "re-binds a pane to the refreshed worktree with the same path"
    (let* ((previous (nerimux/vcs:workspace-organizations))
           (pane (nerimux/model:make-pane :id 31 :title "editor"))
           (old-organization (nerimux/model:make-organization
                              :host "vcs-host" :name "workspace-owner"))
           (old-repository (nerimux/model:make-repository
                            :specification "workspace-owner/project"
                            :local-path "work/project"))
           (old-worktree (nerimux/model:make-worktree
                          :path "work/project/wt" :branch "feature/ui"
                          :head "old-head"))
           (new-organization (nerimux/model:make-organization
                              :host "vcs-host" :name "workspace-owner"))
           (new-repository (nerimux/model:make-repository
                            :specification "workspace-owner/project"
                            :local-path "work/project"))
           (new-worktree (nerimux/model:make-worktree
                          :path "work/project/wt" :branch "feature/ui"
                          :head "new-head")))
      (unwind-protect
           (progn
             (nerimux/model:organization-add-repository old-organization old-repository)
             (nerimux/model:repository-add-worktree old-repository old-worktree)
             (nerimux/model:worktree-add-pane old-worktree pane)
             (nerimux/model:organization-add-repository new-organization new-repository)
             (nerimux/model:repository-add-worktree new-repository new-worktree)
             (nerimux/vcs:set-workspace-organizations (list old-organization))
             (nerimux/vcs:set-workspace-organizations (list new-organization))
             (expect (eq new-worktree (nerimux/model:pane-worktree pane)))
             (expect (member pane (nerimux/model:worktree-panes new-worktree)
                             :test #'eq)))
        (nerimux/vcs:set-workspace-organizations previous))))

  ;; The other branch: when the worktree a pane was attached to is gone from the
  ;; refreshed catalog, the pane's back-pointer must be CLEARED rather than left
  ;; dangling at a struct no longer reachable from the catalog.
  (it "clears the pane's worktree when the worktree vanishes from the catalog"
    (let* ((previous (nerimux/vcs:workspace-organizations))
           (pane (nerimux/model:make-pane :id 32 :title "shell"))
           (old-organization (nerimux/model:make-organization
                              :host "vcs-host" :name "workspace-owner"))
           (old-repository (nerimux/model:make-repository
                            :specification "workspace-owner/project"
                            :local-path "work/project"))
           (old-worktree (nerimux/model:make-worktree
                          :path "work/project/removed" :branch "feature/gone"
                          :head "old-head"))
           (new-organization (nerimux/model:make-organization
                              :host "vcs-host" :name "workspace-owner"))
           (new-repository (nerimux/model:make-repository
                            :specification "workspace-owner/project"
                            :local-path "work/project"))
           (surviving-worktree (nerimux/model:make-worktree
                                :path "work/project/other" :branch "main"
                                :head "new-head")))
      (unwind-protect
           (progn
             (nerimux/model:organization-add-repository old-organization old-repository)
             (nerimux/model:repository-add-worktree old-repository old-worktree)
             (nerimux/model:worktree-add-pane old-worktree pane)
             (nerimux/model:organization-add-repository new-organization new-repository)
             (nerimux/model:repository-add-worktree new-repository surviving-worktree)
             (nerimux/vcs:set-workspace-organizations (list old-organization))
             (expect (eq old-worktree (nerimux/model:pane-worktree pane)))
             (nerimux/vcs:set-workspace-organizations (list new-organization))
             (expect (null (nerimux/model:pane-worktree pane)))
             (expect (not (member pane (nerimux/model:worktree-panes surviving-worktree)
                                  :test #'eq))))
        (nerimux/vcs:set-workspace-organizations previous)))))

;; Regression guard for the review finding that PRUNE-WORKTREES's :DRY-RUN
;; keyword had no default, so (prune-worktrees repository) with no keyword
;; silently performed a LIVE destructive prune despite the docstring calling
;; dry-run "the caller's default". This mocks %VCS-CALL directly (as the
;; "async vcs scan errors" suite above does) rather than requiring vcs-kit,
;; and inspects the exact arguments the VCS-WORKTREE call receives.
(describe "prune-worktrees default dry-run"
  (it "defaults to a dry run when :dry-run is omitted entirely"
    (let ((original (fdefinition 'nerimux/vcs::%vcs-call))
          (captured-arguments nil))
      (unwind-protect
           (let ((repository
                   (nerimux/model:make-repository
                    :specification "workspace-owner/project"
                    :local-path "/tmp/nerimux-prune-default-dry-run-test")))
             (setf (fdefinition 'nerimux/vcs::%vcs-call)
                   (lambda (name &rest arguments)
                     (cond
                       ((string= name "VCS-WORKTREE")
                        (setf captured-arguments arguments)
                        "")
                       ((string= name "VCS-LIST-WORKTREES") nil)
                       (t :fake-backend-repository))))
             ;; No :dry-run keyword at all -- this is the exact call shape the
             ;; review flagged as unsafe.
             (nerimux/vcs:prune-worktrees repository)
             (expect (member "--dry-run" captured-arguments :test #'equal)))
        (setf (fdefinition 'nerimux/vcs::%vcs-call) original)))))
