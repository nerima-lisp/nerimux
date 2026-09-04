(in-package #:nerimux/test/vcs)

(describe "vcs worktree changed-files"
  (it "%changed-file-code uses the real XY chars for ordinary/unmerged entries"
    (expect (string= "M "
                     (nerimux/vcs::%changed-file-code
                      (vcs-kit::%make-vcs-status-entry
                       :kind :ordinary :index-status "M" :worktree-status " "))))
    (expect (string= "UU"
                     (nerimux/vcs::%changed-file-code
                      (vcs-kit::%make-vcs-status-entry
                       :kind :unmerged :index-status "U" :worktree-status "U")))))

  (it "%changed-file-code maps untracked and ignored entries explicitly"
    (expect (string= "??"
                     (nerimux/vcs::%changed-file-code
                      (vcs-kit::%make-vcs-status-entry :kind :untracked))))
    (expect (string= "!!"
                     (nerimux/vcs::%changed-file-code
                      (vcs-kit::%make-vcs-status-entry :kind :ignored)))))

  (it "%worktree-status-changed-files pairs each entry's code with its path"
    (let ((entries
            (list (vcs-kit::%make-vcs-status-entry
                   :kind :ordinary :index-status " " :worktree-status "M"
                   :path "src/foo.lisp")
                  (vcs-kit::%make-vcs-status-entry
                   :kind :untracked :path "new.txt"))))
      (expect (equal (list (cons " M" "src/foo.lisp") (cons "??" "new.txt"))
                     (nerimux/vcs::%worktree-status-changed-files entries)))))

  (it "%changed-file-path renders a rename-or-copy entry as \"old -> new\" (F6)"
    (expect (equal "old.lisp -> new.lisp"
                   (nerimux/vcs::%changed-file-path
                    (vcs-kit::%make-vcs-status-entry
                     :kind :rename-or-copy :index-status "R" :worktree-status " "
                     :path "new.lisp" :original-path "old.lisp"))))
    (expect (equal "src/foo.lisp"
                   (nerimux/vcs::%changed-file-path
                    (vcs-kit::%make-vcs-status-entry
                     :kind :ordinary :index-status " " :worktree-status "M"
                     :path "src/foo.lisp")))))

  (it "%worktree-status-changed-files pairs a rename entry's code with \"old -> new\" (F6)"
    (let ((entries
            (list (vcs-kit::%make-vcs-status-entry
                   :kind :rename-or-copy :index-status "R" :worktree-status " "
                   :path "new.lisp" :original-path "old.lisp"))))
      (expect (equal (list (cons "R " "old.lisp -> new.lisp"))
                     (nerimux/vcs::%worktree-status-changed-files entries)))))

  (it "%changed-file-path strips control characters from a git-status path (F5)"
    (expect (equal "a[31mb"
                   (nerimux/vcs::%changed-file-path
                    (vcs-kit::%make-vcs-status-entry
                     :kind :ordinary :index-status " " :worktree-status "M"
                     :path (format nil "a~C[31mb" (code-char 27))))))
    (expect (equal "old file.lisp -> new file.lisp"
                   (nerimux/vcs::%changed-file-path
                    (vcs-kit::%make-vcs-status-entry
                     :kind :rename-or-copy :index-status "R" :worktree-status " "
                     :path (format nil "new~Cfile.lisp" (code-char 9))
                     :original-path (format nil "old~Cfile.lisp" (code-char 9)))))))

  (it "%apply-worktree-status writes changed-files from a stubbed status snapshot"
    (let* ((path (namestring (host-kit:temporary-directory)))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/project" :local-path path))
           (worktree
             (nerimux/workspace-model:make-worktree :repository repository :path path)))
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (with-stubbed-fdefinition
          ((vcs-kit:make-vcs-repository
             (lambda (directory &rest arguments)
               (declare (ignore arguments))
               directory))
           (vcs-kit:vcs-status-structured
             (lambda (&rest arguments)
               (declare (ignore arguments))
               (vcs-kit::%make-vcs-status-snapshot
                :branch-head "wt-head" :ahead 0 :behind 0
                :entries
                (list (vcs-kit::%make-vcs-status-entry
                       :kind :ordinary :index-status " " :worktree-status "M"
                       :path "src/foo.lisp"))))))
        (nerimux/vcs::%apply-worktree-status
         repository (nerimux/vcs::%read-worktree-status-at path nil path))
        (expect (equal (list (cons " M" "src/foo.lisp"))
                       (nerimux/workspace-model:worktree-changed-files worktree)))))))
