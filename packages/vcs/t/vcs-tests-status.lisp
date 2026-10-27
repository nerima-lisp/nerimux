(in-package #:nerimux/test/vcs)
(defun %vcs-test-numstat-count-values (&rest arguments)
  (let ((result
          (apply
           (symbol-function
            (find-symbol "%WORKTREE-STATUS-DIFF-LINE-COUNTS" :nerimux/vcs))
           arguments)))
    (unless (eq :ready (nerimux/vcs::%numstat-result-state result))
      (error "Expected ready numstat result, got ~S" result))
    (values (nerimux/vcs::%numstat-result-additions result)
            (nerimux/vcs::%numstat-result-deletions result))))

(describe "vcs worktree status split (magit alignment, Unit MODEL)"
          (it
           "%changed-file-column-set-p recognizes only real porcelain columns"
           (dolist
               (case '(("M" . t) ("A" . t)
                                 ("R" . t)
                                 ("U" . t)
                                 ("." . nil)
                                 (" " . nil)
                                 ("?" . nil)
                                 ("" . t)))
             (expect
              (eql (cdr case)
                   (nerimux/vcs::%changed-file-column-set-p (car case))))))
          (it
           "splits porcelain v2's dot columns: an unstaged file is not also staged"
           (let ((entries
                  (list
                   (vcs-kit::%make-vcs-status-entry :kind
                                                    :ordinary
                                                    :index-status
                                                    "."
                                                    :worktree-status
                                                    "M"
                                                    :path
                                                    "unstaged.lisp")
                   (vcs-kit::%make-vcs-status-entry :kind
                                                    :ordinary
                                                    :index-status
                                                    "A"
                                                    :worktree-status
                                                    "."
                                                    :path
                                                    "staged.lisp"))))
             (expect
              (equal (list (cons "A" "staged.lisp"))
                     (nerimux/vcs::%worktree-status-staged-files entries)))
             (expect
              (equal (list (cons "M" "unstaged.lisp"))
                     (nerimux/vcs::%worktree-status-unstaged-files entries)))))
          (it
           "%worktree-status-untracked-files keeps only :untracked entries, code always \"??\""
           (expect
            (equal (list (cons "??" "new.txt"))
                   (nerimux/vcs::%worktree-status-untracked-files
                    (list
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :untracked
                                                      :path
                                                      "new.txt")
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :ordinary
                                                      :index-status
                                                      "M"
                                                      :worktree-status
                                                      " "
                                                      :path
                                                      "staged.lisp"))))))
          (it
           "%worktree-status-unmerged-files keeps only conflict entries, code the real XY pair"
           (expect
            (equal (list (cons "UU" "conflict.lisp"))
                   (nerimux/vcs::%worktree-status-unmerged-files
                    (list
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :unmerged
                                                      :index-status
                                                      "U"
                                                      :worktree-status
                                                      "U"
                                                      :path
                                                      "conflict.lisp")
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :ordinary
                                                      :index-status
                                                      "M"
                                                      :worktree-status
                                                      " "
                                                      :path
                                                      "staged.lisp"))))))
          (it
           "%worktree-status-staged-files keeps only entries with the X column set"
           (expect
            (equal (list (cons "M" "staged.lisp"))
                   (nerimux/vcs::%worktree-status-staged-files
                    (list
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :ordinary
                                                      :index-status
                                                      "M"
                                                      :worktree-status
                                                      " "
                                                      :path
                                                      "staged.lisp")
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :ordinary
                                                      :index-status
                                                      " "
                                                      :worktree-status
                                                      "M"
                                                      :path
                                                      "unstaged.lisp")
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :untracked
                                                      :path
                                                      "new.txt")
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :unmerged
                                                      :index-status
                                                      "U"
                                                      :worktree-status
                                                      "U"
                                                      :path
                                                      "conflict.lisp"))))))
          (it
           "%worktree-status-unstaged-files keeps only entries with the Y column set"
           (expect
            (equal (list (cons "M" "unstaged.lisp"))
                   (nerimux/vcs::%worktree-status-unstaged-files
                    (list
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :ordinary
                                                      :index-status
                                                      "M"
                                                      :worktree-status
                                                      " "
                                                      :path
                                                      "staged.lisp")
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :ordinary
                                                      :index-status
                                                      " "
                                                      :worktree-status
                                                      "M"
                                                      :path
                                                      "unstaged.lisp")
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :untracked
                                                      :path
                                                      "new.txt")
                     (vcs-kit::%make-vcs-status-entry :kind
                                                      :unmerged
                                                      :index-status
                                                      "U"
                                                      :worktree-status
                                                      "U"
                                                      :path
                                                      "conflict.lisp"))))))
          (it
           "a file with both X and Y set appears in BOTH staged and unstaged -- magit's own behaviour"
           (let ((entries
                  (list
                   (vcs-kit::%make-vcs-status-entry :kind
                                                    :ordinary
                                                    :index-status
                                                    "M"
                                                    :worktree-status
                                                    "M"
                                                    :path
                                                    "both.lisp"))))
             (expect
              (equal (list (cons "M" "both.lisp"))
                     (nerimux/vcs::%worktree-status-staged-files entries)))
             (expect
              (equal (list (cons "M" "both.lisp"))
                     (nerimux/vcs::%worktree-status-unstaged-files entries)))))
          (it "every split function returns empty on an empty entries list"
              (expect
               (null (nerimux/vcs::%worktree-status-untracked-files nil)))
              (expect (null (nerimux/vcs::%worktree-status-unmerged-files nil)))
              (expect (null (nerimux/vcs::%worktree-status-staged-files nil)))
              (expect (null (nerimux/vcs::%worktree-status-unstaged-files nil))))
          (it
           "%apply-worktree-status writes all four split lists and line counts from a stubbed status snapshot"
           (let* ((path (namestring (host-kit:temporary-directory)))
                  (repository
                   (nerimux/workspace-model:make-repository
                    :specification "workspace-owner/project"
                    :local-path path))
                  (worktree
                   (nerimux/workspace-model:make-worktree
                    :repository repository :path path)))
             (nerimux/workspace-model:repository-add-worktree repository
                                                              worktree)
             (with-stubbed-fdefinition
                 ((nerimux/vcs::%git-status-snapshot
                    (lambda (&rest arguments)
                      (declare (ignore arguments))
                      (vcs-kit::%make-vcs-status-snapshot
                       :branch-head "wt-head" :ahead 0 :behind 0
                       :entries
                       (list
                        (vcs-kit::%make-vcs-status-entry
                         :kind :untracked :path "new.txt")
                        (vcs-kit::%make-vcs-status-entry
                         :kind :unmerged :index-status "U" :worktree-status "U"
                         :path "conflict.lisp")
                        (vcs-kit::%make-vcs-status-entry
                         :kind :ordinary :index-status "M" :worktree-status " "
                         :path "staged.lisp")
                        (vcs-kit::%make-vcs-status-entry
                         :kind :ordinary :index-status " " :worktree-status "M"
                         :path "unstaged.lisp")))))
                  (nerimux/vcs::%git-numstat-entries
                    (lambda (&rest arguments)
                      (declare (ignore arguments))
                      (list (vcs-kit::%make-numstat-entry
                             :additions 11 :deletions 4 :path "unstaged.lisp")))))
               (nerimux/vcs::%apply-worktree-status
                repository (nerimux/vcs::%read-worktree-status-at path nil path))
               (expect
                (equal (list (cons "??" "new.txt"))
                       (nerimux/workspace-model:worktree-untracked-files
                        worktree)))
               (expect
                (equal (list (cons "UU" "conflict.lisp"))
                       (nerimux/workspace-model:worktree-unmerged-files worktree)))
               (expect
                (equal (list (cons "M" "staged.lisp"))
                       (nerimux/workspace-model:worktree-staged-files worktree)))
               (expect
                (equal (list (cons "M" "unstaged.lisp"))
                       (nerimux/workspace-model:worktree-unstaged-files worktree)))
               (expect (= 11
                          (nerimux/workspace-model:worktree-additions worktree)))
               (expect (= 4
                          (nerimux/workspace-model:worktree-deletions worktree))))))
          (it
           "retains existing numstat counts on failure and applies the stash failure reason"
           (let* ((path (namestring (host-kit:temporary-directory)))
                  (repository
                   (nerimux/workspace-model:make-repository
                    :specification "workspace-owner/status-read-errors"
                    :local-path path))
                  (worktree
                   (nerimux/workspace-model:make-worktree
                    :repository repository :path path
                    :additions 13 :deletions 5))
                  (snapshot
                   (vcs-kit::%make-vcs-status-snapshot
                    :branch-head "head" :ahead 0 :behind 0 :entries nil))
                  (numstat-reason "git diff exited 128: numstat denied")
                  (stash-reason "git stash list exited 128: stash denied"))
             (nerimux/workspace-model:repository-add-worktree repository worktree)
             (nerimux/vcs::%apply-worktree-status
              repository
              (nerimux/vcs::%make-worktree-status-update
               :path path :snapshot snapshot :head "head" :ahead 0 :behind 0
               :numstat-state :failed :numstat-error-message numstat-reason
               :additions nil :deletions nil
               :stashes
               (nerimux/vcs::%make-stash-reading :failed nil stash-reason)))
             (expect
              (eq :failed
                  (nerimux/workspace-model:worktree-numstat-state worktree)))
             (expect
              (equal numstat-reason
                     (nerimux/workspace-model:worktree-numstat-error-message
                      worktree)))
             (expect (= 13 (nerimux/workspace-model:worktree-additions worktree)))
             (expect (= 5 (nerimux/workspace-model:worktree-deletions worktree)))
             (expect
              (eq :failed
                  (nerimux/workspace-model:worktree-stashes-state worktree)))
             (expect
              (equal stash-reason
                     (nerimux/workspace-model:worktree-stashes-error-message
                      worktree)))))
          ;; Git's -<behind> field is signed in the porcelain stream, while
          ;; nerimux's worktree-behind value is a nonnegative count.
          (it
 "%read-worktree-status-at applies a negative behind snapshot as a positive worktree-behind count"
 (let* ((path (namestring (host-kit:temporary-directory)))
        (repository
          (nerimux/workspace-model:make-repository
           :specification "workspace-owner/project"
           :local-path path))
        (worktree
          (nerimux/workspace-model:make-worktree
           :repository repository :path path)))
   (nerimux/workspace-model:repository-add-worktree repository worktree)
   (with-stubbed-fdefinition
       ((nerimux/vcs::%git-status-snapshot
         (lambda (&rest arguments)
           (declare (ignore arguments))
           (vcs-kit::%make-vcs-status-snapshot
            :branch-head "wt-head" :ahead 1 :behind -1 :entries nil))))
     (nerimux/vcs::%apply-worktree-status
      repository
      (nerimux/vcs::%read-worktree-status-at
       path nil path :stashes (cons :ready nil)))
     (expect (= 1 (nerimux/workspace-model:worktree-ahead worktree)))
     (expect (= 1 (nerimux/workspace-model:worktree-behind worktree))))))
)

(describe "refresh-workspace-organizations-async per-repository error channel (BUG-2)"
  (it "invokes on-repository-error for a failing repository, still calls on-complete, and never calls on-error"
    (let ((previous (nerimux/vcs:workspace-organizations)))
      (unwind-protect
           (let* ((organization (nerimux/workspace-model:make-organization
                                 :id "org-bug2" :host "bug2-host" :name "team"))
                  (repository (nerimux/workspace-model:make-repository
                               :id "repo-bug2" :organization organization
                               :specification "bug2-host/team/repo"))
                  (synthetic-condition
                    (make-condition 'simple-error
                                    :format-control "synthetic per-repository failure"))
                  (repository-error-calls nil)
                  (complete-calls nil)
                  (error-calls nil))
             (nerimux/workspace-model:organization-add-repository organization repository)
             (with-stubbed-fdefinition
                 ((nerimux/vcs:scan-repositories-async
                    (lambda (&key query on-start on-complete on-error on-progress callback-dispatch)
                      (declare (ignore query on-start on-error on-progress callback-dispatch))
                      (funcall on-complete (list organization))
                      nil))
                  (nerimux/vcs::%refresh-repositories-with-worktree-queue
                    (lambda (repositories &key on-start on-repository on-complete on-error
                               status-reader status-applier callback-dispatch)
                      (declare (ignore on-start on-repository status-reader status-applier
                                       callback-dispatch))
                      (funcall on-error repository synthetic-condition)
                      (funcall on-complete repositories)
                      nil)))
               (nerimux/vcs:refresh-workspace-organizations-async
                :on-repository-error
                (lambda (failed-repository condition)
                  (push (list failed-repository condition) repository-error-calls))
                :on-complete
                (lambda (organizations) (push organizations complete-calls))
                :on-error
                (lambda (condition) (push condition error-calls)))
               (expect (= 1 (length repository-error-calls)))
               (expect (eq repository (first (first repository-error-calls))))
               (expect (eq synthetic-condition (second (first repository-error-calls))))
               (expect (= 1 (length complete-calls)))
               (expect (equal (list organization) (first complete-calls)))
               (expect (null error-calls))))
        (nerimux/vcs:set-workspace-organizations previous)))))

(describe "vcs worktree upstream and stashes"
  (it "worktree-upstream reads the snapshot's tracking branch, NIL when untracked"
    (let ((tracked (nerimux/workspace-model:make-worktree
                    :path "/tmp/nerimux-upstream-tracked"
                    :status (vcs-kit::%make-vcs-status-snapshot
                             :branch-head "main" :branch-upstream "origin/main")))
          (untracked (nerimux/workspace-model:make-worktree
                      :path "/tmp/nerimux-upstream-untracked"
                      :status (vcs-kit::%make-vcs-status-snapshot
                               :branch-head "main")))
          (unread (nerimux/workspace-model:make-worktree
                   :path "/tmp/nerimux-upstream-unread")))
      (expect (string= "origin/main" (nerimux/vcs:worktree-upstream tracked)))
      (expect (null (nerimux/vcs:worktree-upstream untracked)))
      (expect (null (nerimux/vcs:worktree-upstream unread)))))

  (it "the status pass carries the stash list onto the worktree (F19)"
    (let* ((path (namestring (host-kit:temporary-directory)))
           (repository (nerimux/workspace-model:make-repository
                        :specification "workspace-owner/project" :local-path path))
           (worktree (nerimux/workspace-model:make-worktree
                      :repository repository :path path)))
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (with-stubbed-fdefinition
          ((nerimux/vcs::%git-status-snapshot
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (vcs-kit::%make-vcs-status-snapshot
                :branch-head "wt-head" :ahead 0 :behind 0 :entries nil)))
           (nerimux/vcs::%git-numstat-entries
             (lambda (&rest arguments)
               (declare (ignore arguments))
               nil))
           (nerimux/vcs::%git-stash-entries
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (list (vcs-kit::%make-vcs-stash-entry
                      :reference "stash@{0}" :message "WIP on main")))))
        (nerimux/vcs::%apply-worktree-status
         repository (nerimux/vcs::%read-worktree-status-at path nil path))
        (expect (eq :ready
                    (nerimux/workspace-model:worktree-stashes-state worktree)))
        (expect (equal (list (cons "stash@{0}" "WIP on main"))
                       (nerimux/workspace-model:worktree-stashes worktree)))))))

(describe "vcs shared stash read across a repository's worktrees (perf)"
  (it "%read-repository-status reads the stash list once and applies it to every worktree"
    (let* ((path-a (namestring
                    (merge-pathnames
                     (format nil "nerimux-shared-stash-status-a-~D-~D/"
                             (get-universal-time) (random 1000000))
                     (host-kit:temporary-directory))))
           (path-b (namestring
                    (merge-pathnames
                     (format nil "nerimux-shared-stash-status-b-~D-~D/"
                             (get-universal-time) (random 1000000))
                     (host-kit:temporary-directory))))
           (repository (nerimux/workspace-model:make-repository
                        :specification "workspace-owner/project" :local-path path-a))
           (worktree-a (nerimux/workspace-model:make-worktree
                        :repository repository :path path-a))
           (worktree-b (nerimux/workspace-model:make-worktree
                        :repository repository :path path-b))
           (list-stashes-calls 0))
      (ensure-directories-exist path-a)
      (ensure-directories-exist path-b)
      (nerimux/workspace-model:repository-add-worktree repository worktree-a)
      (nerimux/workspace-model:repository-add-worktree repository worktree-b)
      (with-stubbed-fdefinition
          ((nerimux/vcs::%git-status-snapshot
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (vcs-kit::%make-vcs-status-snapshot
                :branch-head "wt-head" :ahead 0 :behind 0 :entries nil)))
           (nerimux/vcs::%git-numstat-entries
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "git-diff-numstat must not run when nothing changed")))
           (nerimux/vcs::%git-stash-entries
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (incf list-stashes-calls)
               (list (vcs-kit::%make-vcs-stash-entry
                      :reference "stash@{0}" :message "WIP on main")))))
        (let ((updates (nerimux/vcs::%read-repository-status repository)))
          (expect (= 1 list-stashes-calls))
          (nerimux/vcs::%apply-repository-status repository updates)
          (expect (eq :ready
                      (nerimux/workspace-model:worktree-stashes-state worktree-a)))
          (expect (eq :ready
                      (nerimux/workspace-model:worktree-stashes-state worktree-b)))
          (expect (equal (list (cons "stash@{0}" "WIP on main"))
                         (nerimux/workspace-model:worktree-stashes worktree-a)))
          (expect (equal (list (cons "stash@{0}" "WIP on main"))
                         (nerimux/workspace-model:worktree-stashes worktree-b)))))))

  (it "%read-repository-refresh reads the stash list once and applies it to every worktree"
    (let* ((path-a (namestring
                    (merge-pathnames
                     (format nil "nerimux-shared-stash-refresh-a-~D-~D/"
                             (get-universal-time) (random 1000000))
                     (host-kit:temporary-directory))))
           (path-b (namestring
                    (merge-pathnames
                     (format nil "nerimux-shared-stash-refresh-b-~D-~D/"
                             (get-universal-time) (random 1000000))
                     (host-kit:temporary-directory))))
           (repository (nerimux/workspace-model:make-repository
                        :specification "workspace-owner/project" :local-path path-a))
           (worktree-a (nerimux/workspace-model:make-worktree
                        :repository repository :path path-a))
           (worktree-b (nerimux/workspace-model:make-worktree
                        :repository repository :path path-b))
           (list-stashes-calls 0)
           (raw-worktrees
             (list (vcs-kit::%make-vcs-worktree
                    :path path-a :branch "main" :head "head-a")
                   (vcs-kit::%make-vcs-worktree
                    :path path-b :branch "main" :head "head-b"))))
      (ensure-directories-exist path-a)
      (ensure-directories-exist path-b)
      (nerimux/workspace-model:repository-add-worktree repository worktree-a)
      (nerimux/workspace-model:repository-add-worktree repository worktree-b)
      (with-stubbed-fdefinition
          ((nerimux/vcs::%read-repository-worktrees
             (lambda (received)
               (unless (eq received repository) (error "Unexpected repository"))
               (values raw-worktrees nil)))
           (nerimux/vcs::%git-status-snapshot
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (vcs-kit::%make-vcs-status-snapshot
                :branch-head "wt-head" :ahead 0 :behind 0 :entries nil)))
           (nerimux/vcs::%git-numstat-entries
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error "git-diff-numstat must not run when nothing changed")))
           (nerimux/vcs::%git-stash-entries
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (incf list-stashes-calls)
               (list (vcs-kit::%make-vcs-stash-entry
                      :reference "stash@{0}" :message "WIP on main")))))
        (let* ((refresh (nerimux/vcs::%read-repository-refresh repository))
               (updates (nerimux/vcs::%repository-refresh-status-updates refresh)))
          (expect (= 1 list-stashes-calls))
          (expect (= 2 (length updates)))
          (dolist (update updates)
            (nerimux/vcs::%apply-worktree-status repository update))
          (expect (eq :ready
                      (nerimux/workspace-model:worktree-stashes-state worktree-a)))
          (expect (eq :ready
                      (nerimux/workspace-model:worktree-stashes-state worktree-b)))
          (expect (equal (list (cons "stash@{0}" "WIP on main"))
                         (nerimux/workspace-model:worktree-stashes worktree-a)))
          (expect (equal (list (cons "stash@{0}" "WIP on main"))
                         (nerimux/workspace-model:worktree-stashes worktree-b))))))))

(describe "vcs status diff eligibility (M2)"
  (it "%read-worktree-status-at selects only eligible raw paths"
    (flet ((read-status (entries &optional numstat-result)
             (let ((numstat-calls 0)
                   (numstat-paths nil)
                   (path (namestring (host-kit:temporary-directory))))
               (with-stubbed-fdefinition
                   ((nerimux/vcs::%git-status-snapshot
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (vcs-kit::%make-vcs-status-snapshot
                        :branch-head "wt-head" :ahead 0 :behind 0 :entries entries)))
                    (nerimux/vcs::%git-numstat-entries
                     (lambda (directory &optional paths)
                       (declare (ignore directory))
                       (incf numstat-calls)
                       (setf numstat-paths paths)
                       numstat-result)))
                 (values
                  (nerimux/vcs::%read-worktree-status-at
                   path nil path :stashes (cons :ready nil))
                  numstat-calls
                  numstat-paths)))))
      (multiple-value-bind (update calls paths)
          (read-status nil)
        (expect (= 0 calls))
        (expect (null paths))
        (expect (= 0 (nerimux/vcs::%worktree-status-update-additions update)))
        (expect (= 0 (nerimux/vcs::%worktree-status-update-deletions update))))
      (dolist (entry
               (list
                (vcs-kit::%make-vcs-status-entry
                 :kind :ordinary :index-status "M" :worktree-status "." :path "staged.lisp")
                (vcs-kit::%make-vcs-status-entry :kind :untracked :path "new.txt")))
        (multiple-value-bind (update calls paths)
            (read-status (list entry))
          (expect (= 0 calls))
          (expect (null paths))
          (expect (= 0 (nerimux/vcs::%worktree-status-update-additions update)))
          (expect (= 0 (nerimux/vcs::%worktree-status-update-deletions update)))))
      (multiple-value-bind (update calls paths)
          (read-status
           (list (vcs-kit::%make-vcs-status-entry
                  :kind :ordinary :index-status "M" :worktree-status "."
                  :path "staged.lisp")
                 (vcs-kit::%make-vcs-status-entry :kind :untracked :path "new.txt")
                 (vcs-kit::%make-vcs-status-entry
                  :kind :ordinary :index-status "." :worktree-status "M"
                  :path "unstaged.lisp"))
           (list (vcs-kit::%make-numstat-entry
                  :additions 5 :deletions 2 :path "unstaged.lisp")))
        (expect (= 1 calls))
        (expect (equal (list "unstaged.lisp") paths))
        (expect (= 5 (nerimux/vcs::%worktree-status-update-additions update)))
        (expect (= 2 (nerimux/vcs::%worktree-status-update-deletions update))))
      (multiple-value-bind (update calls paths)
          (read-status
           (list (vcs-kit::%make-vcs-status-entry
                  :kind :unmerged :index-status "U" :worktree-status "U"
                  :path "conflict.lisp")))
        (expect (= 1 calls))
        (expect (equal (list "conflict.lisp") paths))
        (expect (= 0 (nerimux/vcs::%worktree-status-update-additions update)))
        (expect (= 0 (nerimux/vcs::%worktree-status-update-deletions update))))
      (multiple-value-bind (update calls paths)
          (read-status
           (list (vcs-kit::%make-vcs-status-entry
                  :kind :rename-or-copy :index-status "R" :worktree-status "M"
                  :path "new-name.lisp" :original-path "old-name.lisp"))
           (list (vcs-kit::%make-numstat-entry
                  :additions 3 :deletions 1 :path "new-name.lisp")))
        (expect (= 1 calls))
        (expect (equal (list "new-name.lisp" "old-name.lisp") paths))
        (expect (= 3 (nerimux/vcs::%worktree-status-update-additions update)))
        (expect (= 1 (nerimux/vcs::%worktree-status-update-deletions update)))))))
(describe "vcs status skips the diff pass when nothing changed (perf)"
  (it "%read-worktree-status-at calls git-diff-numstat only for a worktree with entries"
    (let ((numstat-calls 0))
      (let ((path (namestring (host-kit:temporary-directory))))
        (with-stubbed-fdefinition
            ((nerimux/vcs::%git-status-snapshot
              (lambda (&rest arguments)
                (declare (ignore arguments))
                (vcs-kit::%make-vcs-status-snapshot
                 :branch-head "wt-head" :ahead 0 :behind 0 :entries nil)))
             (nerimux/vcs::%git-numstat-entries
              (lambda (&rest arguments)
                (declare (ignore arguments))
                (incf numstat-calls)
                nil))
             (nerimux/vcs::%git-stash-entries
              (lambda (&rest arguments) (declare (ignore arguments)) nil)))
          (nerimux/vcs::%read-worktree-status-at path nil path)
          (expect (= 0 numstat-calls))))
      (let ((path (namestring (host-kit:temporary-directory))))
        (with-stubbed-fdefinition
            ((nerimux/vcs::%git-status-snapshot
              (lambda (&rest arguments)
                (declare (ignore arguments))
                (vcs-kit::%make-vcs-status-snapshot
                 :branch-head "wt-head" :ahead 0 :behind 0
                 :entries
                 (list (vcs-kit::%make-vcs-status-entry
                        :kind :ordinary :index-status " " :worktree-status "M"
                        :path "foo.lisp")))))
             (nerimux/vcs::%git-numstat-entries
              (lambda (&rest arguments)
                (declare (ignore arguments))
                (incf numstat-calls)
                (list (vcs-kit::%make-numstat-entry
                       :additions 1 :deletions 1 :path "foo.lisp"))))
             (nerimux/vcs::%git-stash-entries
              (lambda (&rest arguments) (declare (ignore arguments)) nil)))
          (nerimux/vcs::%read-worktree-status-at path nil path)
          (expect (= 1 numstat-calls)))))))

(defun %run-git-read-test-directory ()
  (namestring
   (merge-pathnames
    (format nil "nerimux-run-git-read-~D-~D/" (get-universal-time) (random 1000000))
    (host-kit:temporary-directory))))

(defun %run-git-read-test-repo ()
  "A fresh git repository with one commit and one tracked file modified
since -- %READ-WORKTREE-STATUS-AT's end-to-end fixture."
  (let ((directory (%run-git-read-test-directory)))
    (ensure-directories-exist directory)
    (uiop:run-program (list "git" "init" "--initial-branch=main" directory)
                       :output :string :error-output :string)
    (with-open-file (stream (merge-pathnames "tracked.txt" directory)
                            :direction :output :if-does-not-exist :create)
      (write-line "original" stream))
    (uiop:run-program (list "git" "-C" directory "add" "tracked.txt")
                       :output :string :error-output :string)
    (uiop:run-program (list "git" "-C" directory "-c" "user.name=Test"
                           "-c" "user.email=test@example.invalid"
                           "-c" "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null"
                           "commit" "-m" "fixture")
                       :output :string :error-output :string)
    (with-open-file (stream (merge-pathnames "tracked.txt" directory)
                            :direction :output :if-exists :supersede)
      (write-line "original" stream)
      (write-line "changed" stream))
    directory))

(describe "%run-git-read (posix_spawn runner)"
  (it "returns stdout for a command that succeeds"
    (let ((directory (%run-git-read-test-repo)))
      (expect (plusp (length (nerimux/vcs::%run-git-read
                              directory "rev-parse" "--git-dir"))))))

  (it "signals %git-read-error with stderr and a display reason for a failing command"
    (let ((directory (namestring (host-kit:temporary-directory)))
          (exit-code nil)
          (stderr nil)
          (message nil))
      (handler-case
          (nerimux/vcs::%run-git-read directory "status" "--porcelain=v2")
        (nerimux/vcs::%git-read-error (condition)
          (setf exit-code (nerimux/vcs::%git-read-error-exit-code condition)
                stderr (nerimux/vcs::%git-read-error-stderr condition)
                message (nerimux/vcs::%git-read-error-message condition))))
      (expect (eql 128 exit-code))
      (expect (search "fatal:" stderr))
      (expect (search "git status exited 128:" message))
      (expect (search "fatal:" message))
      (expect (<= (length stderr) nerimux/vcs::+status-error-message-max-length+))
      (expect (<= (length message) nerimux/vcs::+status-error-message-max-length+))
      (expect (every (lambda (character)
                       (not (nerimux/text:control-character-p character)))
                     stderr))
      (expect (every (lambda (character)
                       (not (nerimux/text:control-character-p character)))
                     message))))
  (it "keeps status read failure state and a sanitized bounded reason in its update"
    (let* ((directory (namestring (host-kit:temporary-directory)))
           (stderr
             (format nil "fatal: unsafe~%second~C~A"
                     #\Nul (make-string 500 :initial-element #\x)))
           (failure
             (make-condition
              (find-symbol "%GIT-READ-ERROR" :nerimux/vcs)
              :directory directory
              :subcommand "status"
              :arguments nil
              :exit-code 128
              :stderr stderr))
           (update nil))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%git-status-snapshot
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (error failure))))
        (setf update
              (nerimux/vcs::%read-worktree-status-at directory nil directory)))
      (let ((reason
              (nerimux/vcs::%worktree-status-update-status-error-message update)))
        (expect (eq :read-error
                    (nerimux/vcs::%worktree-status-update-status-state update)))
        (expect (search "git status exited 128: fatal: unsafe second" reason))
        (expect (<= (length reason) nerimux/vcs::+status-error-message-max-length+))
        (expect (every (lambda (character)
                         (not (nerimux/text:control-character-p character)))
                       reason)))))

  (it "signals a git-read error when stdout exceeds its byte cap"
    (let* ((directory (%run-git-read-test-repo))
           (nerimux/vcs::*git-read-output-limit* 4)
           (signaled-limit nil))
      (handler-case
          (nerimux/vcs::%run-git-read directory "rev-parse" "--git-dir")
        (nerimux/vcs::%git-read-error (condition)
          (setf signaled-limit
                (nerimux/vcs::%git-read-error-output-limit condition))))
      (expect (eql 4 signaled-limit)))))

(describe "%read-worktree-status-at against a real repository (posix_spawn end-to-end)"
  (it "reports dirty-p, one changed file, and numstat additions/deletions"
    (let* ((directory (%run-git-read-test-repo))
           (update (nerimux/vcs::%read-worktree-status-at directory nil directory)))
      (expect (nerimux/vcs::%worktree-status-update-dirty-p update))
      (expect (= 1 (length (nerimux/vcs::%worktree-status-update-changed-files update))))
      (expect (= 1 (nerimux/vcs::%worktree-status-update-additions update)))
      (expect (= 0 (nerimux/vcs::%worktree-status-update-deletions update))))))
(describe "vcs numstat literal pathspec"
  (it "numstat regression passes raw changed paths after the separator with top-level literal pathspec magic"
    (let ((command-arguments nil)
          (paths (list "- leading [glob]* (x):.txt" "space name.txt")))
      (with-stubbed-fdefinition
          ((nerimux/vcs::%run-git-read
            (lambda (directory subcommand &rest arguments)
              (declare (ignore directory))
              (setf command-arguments (cons subcommand arguments))
              nil))
           (vcs-kit:parse-numstat
            (lambda (output)
              (declare (ignore output))
              nil)))
        (nerimux/vcs::%git-numstat-entries "/fixture" paths))
      (expect
       (equal
        (list "diff" "--numstat" "-z" "--"
              ":(top,literal)- leading [glob]* (x):.txt"
              ":(top,literal)space name.txt")
        command-arguments)))))
(describe "vcs numstat path selection line-count equivalence"
  (it "matches full numstat for renames, conflicts, binary, and special paths"
    (let* ((directory (%run-git-read-test-repo))
           (special-name "- spaced (x).txt")
           (captured-paths nil)
           (selected-additions nil)
           (selected-deletions nil)
           (original-numstat
             (fdefinition (find-symbol "%GIT-NUMSTAT-ENTRIES" :nerimux/vcs))))
      (flet ((write-file (name content)
               (with-open-file (stream (format nil "~A~A" directory name)
                                       :direction :output
                                       :if-exists :supersede
                                       :if-does-not-exist :create)
                 (write-string content stream))))
        (uiop:run-program
         (list "git" "-C" directory "config" "user.name" "Fixture")
         :output :string :error-output :string)
        (uiop:run-program
         (list "git" "-C" directory "config" "user.email" "fixture@example.invalid")
         :output :string :error-output :string)
        (uiop:run-program
         (list "git" "-C" directory "config" "commit.gpgsign" "false")
         :output :string :error-output :string)
        (write-file "rename-old.txt" (format nil "rename base~%"))
        (write-file "conflict.txt" (format nil "conflict base~%"))
        (write-file "binary.bin" (format nil "binary base~Ctail" (code-char 0)))
        (write-file special-name (format nil "special base~%"))
        (uiop:run-program
         (list "git" "-C" directory "add" "-A")
         :output :string :error-output :string)
        (uiop:run-program
         (list "git" "-C" directory "commit" "-m" "fixture")
         :output :string :error-output :string)
        (uiop:run-program
         (list "git" "-C" directory "branch" "side")
         :output :string :error-output :string)
        (write-file "conflict.txt" (format nil "main conflict~%"))
        (uiop:run-program
         (list "git" "-C" directory "add" "conflict.txt")
         :output :string :error-output :string)
        (uiop:run-program
         (list "git" "-C" directory "commit" "-m" "main change")
         :output :string :error-output :string)
        (uiop:run-program
         (list "git" "-C" directory "checkout" "side")
         :output :string :error-output :string)
        (write-file "conflict.txt" (format nil "side conflict~%"))
        (uiop:run-program
         (list "git" "-C" directory "add" "conflict.txt")
         :output :string :error-output :string)
        (uiop:run-program
         (list "git" "-C" directory "commit" "-m" "side change")
         :output :string :error-output :string)
        (uiop:run-program
         (list "git" "-C" directory "checkout" "main")
         :output :string :error-output :string)
        (uiop:run-program
         (list "git" "-C" directory "merge" "side")
         :output :string :error-output :string :ignore-error-status t)
        (uiop:run-program
         (list "git" "-C" directory "mv" "rename-old.txt" "rename-new.txt")
         :output :string :error-output :string)
        (write-file "rename-new.txt" (format nil "rename changed~%"))
        (write-file "binary.bin" (format nil "binary changed~Ctail" (code-char 0)))
        (write-file special-name (format nil "special changed~%")))
      (let* ((snapshot (nerimux/vcs::%git-status-snapshot directory))
             (entries (vcs-kit:vcs-status-snapshot-entries snapshot)))
        (with-stubbed-fdefinition
            ((nerimux/vcs::%git-numstat-entries
              (lambda (received-directory &optional paths)
                (setf captured-paths paths)
                (funcall original-numstat received-directory paths))))
          (multiple-value-setq (selected-additions selected-deletions)
            (%vcs-test-numstat-count-values directory entries)))
        (multiple-value-bind (full-additions full-deletions)
            (%vcs-test-numstat-count-values directory)
          (expect
           (some (lambda (entry)
                   (eq :unmerged (vcs-kit:vcs-status-entry-kind entry)))
                 entries))
          (expect
           (some (lambda (entry)
                   (eq :rename-or-copy (vcs-kit:vcs-status-entry-kind entry)))
                 entries))
          (expect (member "conflict.txt" captured-paths :test (function string=)))
          (expect (member "rename-new.txt" captured-paths :test (function string=)))
          (expect (member "rename-old.txt" captured-paths :test (function string=)))
          (expect (member "binary.bin" captured-paths :test (function string=)))
          (expect (member special-name captured-paths :test (function string=)))
          (expect (= 5 (length captured-paths)))
          (expect (= full-additions selected-additions))
          (expect (= full-deletions selected-deletions)))
        (let ((binary-entry
                (first (nerimux/vcs::%git-numstat-entries directory (list "binary.bin"))))
              (rename-entries
                (nerimux/vcs::%git-numstat-entries
                 directory (list "rename-new.txt" "rename-old.txt")))
              (special-entry
                (first (nerimux/vcs::%git-numstat-entries directory (list special-name))))
              (conflict-entries
                (nerimux/vcs::%git-numstat-entries directory (list "conflict.txt"))))
          (expect binary-entry)
          (expect (null (vcs-kit:numstat-entry-additions binary-entry)))
          (expect (null (vcs-kit:numstat-entry-deletions binary-entry)))
          (expect (= 1 (length rename-entries)))
          (expect (= 1
                     (vcs-kit:numstat-entry-additions (first rename-entries))))
          (expect (= 1
                     (vcs-kit:numstat-entry-deletions (first rename-entries))))
          (expect special-entry)
          (expect (= 1 (vcs-kit:numstat-entry-additions special-entry)))
          (expect (= 1 (vcs-kit:numstat-entry-deletions special-entry)))
          (expect conflict-entries))))))
(describe "vcs numstat regression"
  (it "numstat regression treats a glob name literally beside a matching sibling under inherited GIT_LITERAL_PATHSPECS=1"
    (let* ((directory (%run-git-read-test-repo))
           (target "glob[ab]*.txt")
           (sibling "globa-match.txt"))
      (flet ((write-file (name content)
               (uiop:run-program
                (list "/bin/sh" "-c"
                      "printf %s \"$2\" > \"$1\""
                      "sh" (format nil "~A~A" directory name) content)
                :output :string :error-output :string))
             (commit (message)
               (uiop:run-program
                (list "git" "-C" directory
                      "-c" "user.name=Fixture"
                      "-c" "user.email=fixture@example.invalid"
                      "-c" "commit.gpgsign=false"
                      "commit" "-m" message)
                :output :string :error-output :string)))
        (write-file target (format nil "target base~%"))
        (write-file sibling (format nil "sibling base~%"))
        (uiop:run-program (list "git" "-C" directory "add" "-A")
                          :output :string :error-output :string)
        (commit "glob paths")
        (write-file target (format nil "target first~%target second~%"))
        (write-file sibling (format nil "sibling changed~%"))
        (let ((entries (nerimux/vcs::%git-numstat-entries directory (list target))))
          (expect (= 1 (length entries)))
          (expect (and entries
                       (string= target (vcs-kit:numstat-entry-path (first entries)))))
          (expect (and entries (= 2 (vcs-kit:numstat-entry-additions (first entries)))))
          (expect (and entries (= 1 (vcs-kit:numstat-entry-deletions (first entries))))))
        (nerimux/test/ports:with-temporary-posix-environment-variable
            ("GIT_LITERAL_PATHSPECS" "1")
          (expect (string= "1" (sb-ext:posix-getenv "GIT_LITERAL_PATHSPECS")))
          (let ((entries (nerimux/vcs::%git-numstat-entries directory (list target))))
            (expect (= 1 (length entries)))
            (expect (and entries
                         (string= target (vcs-kit:numstat-entry-path (first entries)))))
            (expect (and entries (= 2 (vcs-kit:numstat-entry-additions (first entries)))))
            (expect (and entries (= 1 (vcs-kit:numstat-entry-deletions (first entries))))))))))
  (it "numstat regression falls back to full diff for an invalid UTF-8 tracked path"
    (let* ((directory (%run-git-read-test-repo))
           (captured-arguments nil)
           (selected-additions nil)
           (selected-deletions nil)
           (original-run-git-read
             (fdefinition (find-symbol "%RUN-GIT-READ" :nerimux/vcs))))
      (with-open-file (stream (format nil "~Atracked.txt" directory)
                              :direction :output
                              :if-exists :supersede)
        (write-line "original" stream))
      (labels ((run-fixture-command (label arguments &optional output)
                 (handler-case
                     (uiop:run-program arguments
                                       :directory directory
                                       :output output
                                       :error-output nil)
                   (error (condition)
                     (error "invalid UTF-8 fixture ~A failed: ~A"
                            label condition))))
               (commit ()
                 (run-fixture-command
                  "commit raw invalid-byte path"
                  (list "git" "-C" directory
                        "-c" "user.name=Fixture"
                        "-c" "user.email=fixture@example.invalid"
                        "-c" "commit.gpgsign=false"
                        "-c" "core.hooksPath=/dev/null"
                        "commit" "-q" "-m" "invalid path"))))
        (run-fixture-command
         "insert raw tracked path into Git index"
         (list "/bin/sh" "-c"
               "blob=$(printf 'before\\n' | git -C \"$1\" hash-object -w --stdin) && { printf '100644 %s 0\\t' \"$blob\"; printf '\\377bad.txt\\000'; } | git -C \"$1\" update-index -z --index-info"
               "sh" directory))
        (commit)
        (let* ((tracked-path-hex
                 (run-fixture-command
                  "Git path byte check"
                  (list "/bin/sh" "-c"
                        "git -C \"$1\" ls-files -z | od -An -v -tx1 | tr -d \"[:space:]\""
                        "sh" directory)
                  :string))
               (snapshot
                 (handler-case
                     (nerimux/vcs::%git-status-snapshot directory)
                   (error (condition)
                     (error "status snapshot call failed: ~A" condition))))
               (entries (vcs-kit:vcs-status-snapshot-entries snapshot)))
          (with-stubbed-fdefinition
              ((nerimux/vcs::%run-git-read
                (lambda (received-directory subcommand &rest arguments)
                  (setf captured-arguments (cons subcommand arguments))
                  (apply original-run-git-read
                         received-directory subcommand arguments))))
            (handler-case
                (multiple-value-setq (selected-additions selected-deletions)
                  (%vcs-test-numstat-count-values directory entries))
              (error (condition)
                (error "selected line-count calculation failed: ~A" condition))))
          (multiple-value-bind (full-additions full-deletions)
              (handler-case
                  (%vcs-test-numstat-count-values directory)
                (error (condition)
                  (error "full line-count calculation failed: ~A" condition)))
            (expect (search "ff6261642e74787400" tracked-path-hex))
            (expect (some (lambda (entry)
                            (find #\?
                                  (vcs-kit:vcs-status-entry-path entry)))
                          entries))
            (expect (equal (list "diff" "--numstat" "-z") captured-arguments))
            (expect (= 0 full-additions))
            (expect (= 1 full-deletions))
            (expect (= full-additions selected-additions))
            (expect (= full-deletions selected-deletions)))))))
  (it "numstat regression falls back to full diff when pathspec argv exceeds 128 KiB"
    (let* ((directory (%run-git-read-test-repo))
           (path-count 535)
           (path-prefix (make-string 230 :initial-element #\p))
           (captured-arguments nil)
           (selected-additions nil)
           (selected-deletions nil)
           (original-run-git-read
             (fdefinition (find-symbol "%RUN-GIT-READ" :nerimux/vcs))))
      (flet ((path-for (index)
               (format nil "~A~4,'0D" path-prefix index))
             (write-file (name content)
               (with-open-file (stream (format nil "~A~A" directory name)
                                       :direction :output
                                       :if-exists :supersede
                                       :if-does-not-exist :create)
                 (write-string content stream)))
             (commit ()
               (uiop:run-program
                (list "git" "-C" directory
                      "-c" "user.name=Fixture"
                      "-c" "user.email=fixture@example.invalid"
                      "-c" "commit.gpgsign=false"
                      "commit" "-m" "many paths")
                :output :string :error-output :string)))
        (dotimes (index path-count)
          (write-file (path-for index) (format nil "before~%")))
        (uiop:run-program (list "git" "-C" directory "add" "-A")
                          :output :string :error-output :string)
        (commit)
        (dotimes (index path-count)
          (write-file (path-for index) (format nil "after~%"))))
      (let* ((snapshot (nerimux/vcs::%git-status-snapshot directory))
             (entries (vcs-kit:vcs-status-snapshot-entries snapshot)))
        (with-stubbed-fdefinition
            ((nerimux/vcs::%run-git-read
              (lambda (received-directory subcommand &rest arguments)
                (setf captured-arguments (cons subcommand arguments))
                (apply original-run-git-read
                       received-directory subcommand arguments))))
          (multiple-value-setq (selected-additions selected-deletions)
            (%vcs-test-numstat-count-values directory entries)))
        (multiple-value-bind (full-additions full-deletions)
            (%vcs-test-numstat-count-values directory)
          (expect (= path-count (length entries)))
          (expect (equal (list "diff" "--numstat" "-z") captured-arguments))
          (expect (= path-count full-additions))
          (expect (= path-count full-deletions))
          (expect (= full-additions selected-additions))
          (expect (= full-deletions selected-deletions))))))
  (it
    "returns typed numstat failure instead of treating it as zero counts"
    (let* ((result nil)
           (log-output
             (with-output-to-string (stream)
               (let ((nerimux/vcs::*vcs-diagnostic-logger*
                       (log-kit:make-logger
                        :name "nerimux/vcs-test"
                        :handler (make-instance 'log-kit:text-handler :stream stream)
                        :level log-kit:+level-info+)))
                 (with-stubbed-fdefinition
                     ((nerimux/vcs::%git-numstat-entries
                        (lambda (&rest arguments)
                          (declare (ignore arguments))
                          (error "forced numstat failure"))))
                   (setf result
                         (nerimux/vcs::%worktree-status-diff-line-counts
                          "/fixture"
                          (list
                           (vcs-kit::%make-vcs-status-entry
                            :kind :ordinary
                            :index-status "."
                            :worktree-status "M"
                            :path "tracked.txt")))))))))
      (expect (search "Git numstat failed in /fixture" log-output))
      (expect (search "forced numstat failure" log-output))
      (expect (typep result (find-symbol "%NUMSTAT-RESULT" :nerimux/vcs)))
      (expect (eq :failed (nerimux/vcs::%numstat-result-state result)))
      (expect (null (nerimux/vcs::%numstat-result-additions result)))
      (expect (null (nerimux/vcs::%numstat-result-deletions result)))
      (expect
       (equal "forced numstat failure"
              (nerimux/vcs::%numstat-result-error-message result)))))
  (it
    "returns typed numstat failure when diagnostics signal"
    (let ((result nil)
          (logged-p nil))
      (sb-ext:without-package-locks
        (with-stubbed-fdefinition
            ((nerimux/vcs::%git-numstat-entries
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error "forced numstat failure")))
             (log-kit:emit-log
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (setf logged-p t)
                 (error "forced logger failure"))))
          (setf result
                (nerimux/vcs::%worktree-status-diff-line-counts
                 "/fixture"
                 (list
                  (vcs-kit::%make-vcs-status-entry
                   :kind :ordinary
                   :index-status "."
                   :worktree-status "M"
                   :path "tracked.txt"))))))
      (expect logged-p)
      (expect (typep result (find-symbol "%NUMSTAT-RESULT" :nerimux/vcs)))
      (expect (eq :failed (nerimux/vcs::%numstat-result-state result)))
      (expect (null (nerimux/vcs::%numstat-result-additions result)))
      (expect (null (nerimux/vcs::%numstat-result-deletions result)))
      (expect
       (equal "forced numstat failure"
              (nerimux/vcs::%numstat-result-error-message result))))))
(describe "vcs numstat fallback diagnostic logging"
  (it "records one non-TUI log entry for each unfiltered fallback"
    (let* ((commands nil)
           (log-output
             (with-output-to-string (stream)
               (let ((nerimux/vcs::*vcs-diagnostic-logger*
                       (log-kit:make-logger
                        :name "nerimux/vcs-test"
                        :handler (make-instance 'log-kit:text-handler :stream stream)
                        :level log-kit:+level-info+)))
                 (with-stubbed-fdefinition
                     ((nerimux/vcs::%run-git-read
                       (lambda (directory subcommand &rest arguments)
                         (declare (ignore directory))
                         (push (cons subcommand arguments) commands)
                         "")))
                   (nerimux/vcs::%git-numstat-entries
                    "/fixture" (list "bad?path"))
                   (nerimux/vcs::%git-numstat-entries
                    "/fixture"
                    (make-list 535
                               :initial-element
                               (make-string 240 :initial-element #\p))))))))
      (let* ((replacement-message
               "using unfiltered diff for numstat because a decoded path may contain the UTF-8 replacement marker")
             (limit-message
               "using unfiltered diff for numstat because the pathspec argv exceeds its byte limit")
             (replacement-position (search replacement-message log-output))
             (limit-position (search limit-message log-output)))
        (expect (and replacement-position
                     (null (search replacement-message
                                   log-output
                                   :start2 (1+ replacement-position)))))
        (expect (and limit-position
                     (null (search limit-message
                                   log-output
                                   :start2 (1+ limit-position)))))
        (expect (equal '(("diff" "--numstat" "-z")
                         ("diff" "--numstat" "-z")) (reverse commands)))))))
(describe "vcs repository worktree state preservation"
  (it "preserves cached status and failure reasons while rebuilding worktrees"
    (let* ((path (namestring (host-kit:temporary-directory)))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/state-copy" :local-path path))
           (snapshot
             (vcs-kit::%make-vcs-status-snapshot
              :branch-head "cached-head" :ahead 1 :behind -1 :entries nil))
           (status-reason "git status exited 128: repository unavailable")
           (numstat-reason "git diff exited 128: numstat unavailable")
           (stashes-reason "git stash list exited 128: stash unavailable")
           (old-worktree
             (nerimux/workspace-model:make-worktree
              :repository repository :path path :branch "main" :head "old-head"
              :status snapshot :status-state :stale
              :status-error-message status-reason
              :additions 13 :deletions 5
              :numstat-state :failed :numstat-error-message numstat-reason
              :stashes nil :stashes-state :failed
              :stashes-error-message stashes-reason)))
      (nerimux/workspace-model:repository-add-worktree repository old-worktree)
      (nerimux/vcs::%apply-repository-worktrees
       repository
       (list
        (vcs-kit::%make-vcs-worktree
         :path path :branch "main" :head "fresh-head"))
       nil)
      (let ((worktree
              (car
               (nerimux/workspace-model:repository-worktrees repository))))
        (expect (eq :stale
                    (nerimux/workspace-model:worktree-status-state worktree)))
        (expect (eq snapshot
                    (nerimux/workspace-model:worktree-status worktree)))
        (expect (nerimux/workspace-model:worktree-read-error-p worktree))
        (expect (equal status-reason
                       (nerimux/workspace-model:worktree-status-error-message
                        worktree)))
        (expect (eq :failed
                    (nerimux/workspace-model:worktree-numstat-state worktree)))
        (expect (equal numstat-reason
                       (nerimux/workspace-model:worktree-numstat-error-message
                        worktree)))
        (expect (= 13 (nerimux/workspace-model:worktree-additions worktree)))
        (expect (= 5 (nerimux/workspace-model:worktree-deletions worktree)))
        (expect (eq :failed
                    (nerimux/workspace-model:worktree-stashes-state worktree)))
        (expect (equal stashes-reason
                       (nerimux/workspace-model:worktree-stashes-error-message
                        worktree)))
        (expect (equal "fresh-head"
                       (nerimux/workspace-model:worktree-head worktree)))))))

