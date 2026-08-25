(in-package #:nerimux/test)

(describe "vcs value helpers"
  (it "normalizes values and splits repository specifications"
    (expect (string= "" (nerimux/vcs::%string-value nil)))
    (expect (string= "value" (nerimux/vcs::%string-value "value")))
    (expect (string= (namestring #P"/tmp/project")
                     (nerimux/vcs::%string-value #P"/tmp/project")))
    (expect (string= "42" (nerimux/vcs::%string-value 42)))
    (expect (equal '("org" "project")
                   (nerimux/vcs::%specification-parts "org//project/")))
    (expect (equal '("project")
                   (nerimux/vcs::%specification-parts "/project/")))
    (expect (null (nerimux/vcs::%specification-parts nil))))

  (it "derives organization and repository names by specification shape"
    (multiple-value-bind (organization name)
        (nerimux/vcs::%organization-and-name "host/org/project")
      (expect (string= "host" organization))
      (expect (string= "org" name)))
    (multiple-value-bind (organization name)
        (nerimux/vcs::%organization-and-name "org/project")
      (expect (string= "local" organization))
      (expect (string= "org" name)))
    (multiple-value-bind (organization name)
        (nerimux/vcs::%organization-and-name "project")
      (expect (string= "local" organization))
      (expect (string= "default" name)))
    (multiple-value-bind (organization name)
        (nerimux/vcs::%organization-and-name nil)
      (expect (string= "local" organization))
      (expect (string= "default" name)))))

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

(describe "async vcs batch edge cases"
  (it "completes immediately for an empty repository set"
    (let ((completed :not-called)
          (threads :not-called))
      (setf threads
            (nerimux/vcs:refresh-repositories-async
             nil
             :on-complete (lambda (repositories)
                            (setf completed repositories))))
      (expect (null threads))
      (expect (equal '() completed))))

  (it "reports a repository refresh error before completing the batch"
    (let* ((repository
             (nerimux/model:make-repository
              :specification "workspace-owner/project"
              :local-path "/tmp/project"))
           (error-repository nil)
           (condition-seen nil)
           (completed nil)
           (deadline (+ (get-internal-real-time)
                        (* 2 internal-time-units-per-second))))
      (nerimux/vcs:refresh-repositories-async
       (list repository)
       :refresh-function (lambda (current)
                           (declare (ignore current))
                           (error "synthetic repository refresh failure"))
       :on-error (lambda (current condition)
                   (setf error-repository current
                         condition-seen condition))
       :on-complete (lambda (repositories)
                      (declare (ignore repositories))
                      (setf completed t)))
      (loop until completed
            while (< (get-internal-real-time) deadline)
            do (sleep 0.01))
      (expect (eq repository error-repository))
      (expect condition-seen)
      (expect completed))))

(describe "async vcs scan errors"
  (it "reports a scan failure without leaking an unhandled worker error"
    (let ((condition-seen nil)
          (deadline (+ (get-internal-real-time)
                       (* 2 internal-time-units-per-second))))
      (with-stubbed-fdefinition
          ((vcs-kit:ghq-list-repositories
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "synthetic ghq failure"))))
        (nerimux/vcs:scan-repositories-async
         :on-error (lambda (condition)
                     (setf condition-seen condition)))
        (loop until condition-seen
              while (< (get-internal-real-time) deadline)
              do (sleep 0.01))
        (expect condition-seen)))))

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
;; dry-run "the caller's default". The test replaces the direct cl-vcs-kit
;; functions and inspects the exact arguments VCS-WORKTREE receives.
(describe "prune-worktrees default dry-run"
  (it "defaults to a dry run when :dry-run is omitted entirely"
    (let ((captured-arguments nil)
          (repository
            (nerimux/model:make-repository
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
        ;; No :dry-run keyword at all -- this is the exact call shape the
        ;; review flagged as unsafe.
        (nerimux/vcs:prune-worktrees repository)
        (expect (member "--dry-run" captured-arguments :test #'equal))))))
