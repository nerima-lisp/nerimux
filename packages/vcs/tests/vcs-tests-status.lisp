(in-package #:nerimux/test/vcs)

(describe "vcs worktree status split (magit alignment, Unit MODEL)"
          (it
           "%changed-file-column-set-p recognizes only real porcelain columns"
           (dolist 
               (case '(("M" . t) ("A" . t)
                                 ("R" . t)
                                 ("U" . t)
                                 (" " . nil)
                                 ("?" . nil)
                                 ("" . t)))
             (expect
              (eql (cdr case)
                   (nerimux/vcs::%changed-file-column-set-p (car case))))))
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
           "%apply-worktree-status writes all four split lists from a stubbed status snapshot"
           (let* ((path (namestring (host-kit:temporary-directory)))
                  (repository
                   (nerimux/workspace-model:make-repository :specification
                                                            "workspace-owner/project"
                                                            :local-path
                                                            path))
                  (worktree
                   (nerimux/workspace-model:make-worktree :repository
                                                          repository
                                                          :path
                                                          path)))
             (nerimux/workspace-model:repository-add-worktree repository
                                                              worktree)
             (with-stubbed-fdefinition
              ((vcs-kit:make-vcs-repository
                (lambda (directory &rest arguments)
                  (declare (ignore arguments))
                  directory))
               (vcs-kit:vcs-status-structured
                (lambda (&rest arguments)
                  (declare (ignore arguments))
                  (vcs-kit::%make-vcs-status-snapshot :branch-head
                                                      "wt-head"
                                                      :ahead
                                                      0
                                                      :behind
                                                      0
                                                      :entries
                                                      (list
                                                       (vcs-kit::%make-vcs-status-entry
                                                        :kind
                                                        :untracked
                                                        :path
                                                        "new.txt")
                                                       (vcs-kit::%make-vcs-status-entry
                                                        :kind
                                                        :unmerged
                                                        :index-status
                                                        "U"
                                                        :worktree-status
                                                        "U"
                                                        :path
                                                        "conflict.lisp")
                                                       (vcs-kit::%make-vcs-status-entry
                                                        :kind
                                                        :ordinary
                                                        :index-status
                                                        "M"
                                                        :worktree-status
                                                        " "
                                                        :path
                                                        "staged.lisp")
                                                       (vcs-kit::%make-vcs-status-entry
                                                        :kind
                                                        :ordinary
                                                        :index-status
                                                        " "
                                                        :worktree-status
                                                        "M"
                                                        :path
                                                        "unstaged.lisp"))))))
              (nerimux/vcs::%apply-worktree-status repository
                                                   (nerimux/vcs::%read-worktree-status-at
                                                    path
                                                    nil
                                                    path))
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
                      (nerimux/workspace-model:worktree-unstaged-files worktree)))))))

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
                    (lambda (&key query on-complete on-error on-progress callback-dispatch)
                      (declare (ignore query on-error on-progress callback-dispatch))
                      (funcall on-complete (list organization))
                      nil))
                  (nerimux/vcs:refresh-repositories-async
                    (lambda (repositories &key on-repository on-complete on-error
                               status-reader status-applier callback-dispatch)
                      (declare (ignore on-repository status-reader status-applier
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
