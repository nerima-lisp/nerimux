(in-package #:nerimux/test/vcs)

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
                  (nerimux/vcs:refresh-repositories-async
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

  (it "signals %git-read-error carrying the exit code for a failing command"
    (let ((directory (namestring (host-kit:temporary-directory)))
          (signaled nil))
      (handler-case
          (nerimux/vcs::%run-git-read directory "status" "--porcelain=v2")
        (nerimux/vcs::%git-read-error (condition)
          (setf signaled (nerimux/vcs::%git-read-error-exit-code condition))))
      (expect (eql 128 signaled))))

  (it "honours the size cap, truncating to *git-read-output-limit* bytes"
    (let* ((directory (%run-git-read-test-repo))
           (nerimux/vcs::*git-read-output-limit* 4))
      (expect (= 4 (length (nerimux/vcs::%run-git-read
                           directory "rev-parse" "--git-dir")))))))

(describe "%read-worktree-status-at against a real repository (posix_spawn end-to-end)"
  (it "reports dirty-p, one changed file, and numstat additions/deletions"
    (let* ((directory (%run-git-read-test-repo))
           (update (nerimux/vcs::%read-worktree-status-at directory nil directory)))
      (expect (nerimux/vcs::%worktree-status-update-dirty-p update))
      (expect (= 1 (length (nerimux/vcs::%worktree-status-update-changed-files update))))
      (expect (= 1 (nerimux/vcs::%worktree-status-update-additions update)))
      (expect (= 0 (nerimux/vcs::%worktree-status-update-deletions update))))))
