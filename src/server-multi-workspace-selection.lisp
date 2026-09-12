(in-package #:nerimux)

(defun %picker-item-worktree (item)
  "The worktree ITEM itself names, and nothing else.

   Picking an item opens a shell in the worktree this returns, so standing in
   a repository's or an organization's worktree for it put the user in a
   directory they never named -- inside a bare .git for a bare clone, or in
   whichever repository happened to come first in the organization."
  (nerimux/picker:picker-item-worktree item))

(defun %workspace-worktrees (&optional
                             (organizations
                              (nerimux/vcs:workspace-organizations)))
  "Return the catalog worktrees in stable organization/repository order."
  (loop for organization in organizations
        append (loop for repository in (nerimux/workspace-model:organization-repositories
                                        organization)
                     append (copy-list
                             (nerimux/workspace-model:repository-worktrees
                              repository)))))

(defun %workspace-tree-objects (&optional
                                (organizations
                                 (nerimux/vcs:workspace-organizations))
                                filter
                                (file-diffs (%workspace-file-diffs)))
  "Return the selectable tree rows in display order.

   FILTER and FILE-DIFFS must match the corresponding render pass so
   navigation and selection follow the visible rows."
  (nerimux/renderer:workspace-tree-objects organizations
                                           (%workspace-collapsed-nodes)
                                           :filter
                                           filter
                                           :expanded-node-ids
                                           (%workspace-expanded-nodes)
                                           :file-diffs
                                           file-diffs))

(defun %workspace-worktree-matches-token-p (worktree token)
  (or (eq worktree token)
      (and (stringp token)
           (or (string= token (nerimux/workspace-model:worktree-id worktree))
               (string= token (nerimux/workspace-model:worktree-path worktree))
               (and (nerimux/workspace-model:worktree-branch worktree)
                    (string= token
                             (princ-to-string
                              (nerimux/workspace-model:worktree-branch worktree))))))))

(defun %workspace-find-worktree (token &optional
                                       (organizations
                                        (nerimux/vcs:workspace-organizations)))
  (when token
    (find-if
     (lambda (worktree)
       (%workspace-worktree-matches-token-p worktree token))
     (%workspace-worktrees organizations))))

(defun %workspace-directory-prefix-p (directory path)
  (and (stringp directory)
       (string/= directory "")
       (stringp path)
       (let ((prefix
              (if (char= (char directory (1- (length directory))) #\/)
                  directory
                  (concatenate 'string directory "/"))))
         (or (string= directory path)
             (and (>= (length path) (length prefix))
                  (string= prefix path :end2 (length prefix)))))))

(defun %workspace-canonical-path (path)
  "PATH with symlinks resolved, or NIL when it names nothing on disk.

   /tmp is a symlink to /private/tmp on macOS, so the path a shell hands the
   user and the path git reports for the same worktree differ by prefix."
  (when (and (stringp path) (plusp (length path)))
    (let ((resolved (ignore-errors
                     (truename (sb-ext:parse-native-namestring path)))))
      (when resolved
        (let ((native (sb-ext:native-namestring resolved)))
          (if (and (> (length native) 1)
                   (char= (char native (1- (length native))) #\/))
              (subseq native 0 (1- (length native)))
              native))))))

(defun %workspace-find-worktree-for-attach (token organizations)
  "Resolve an explicit attach selector TOKEN to a worktree.

   A directory selector matches a worktree below that directory, and paths are
   compared again after symlink resolution so the unresolved form a shell or
   tab-completion produces resolves too."
  (or (%workspace-find-worktree token organizations)
      (find-if
       (lambda (worktree)
         (%workspace-directory-prefix-p token
                                        (nerimux/workspace-model:worktree-path
                                         worktree)))
       (%workspace-worktrees organizations))
      (let ((resolved (%workspace-canonical-path token)))
        (when resolved
          (find-if
           (lambda (worktree)
             (%workspace-directory-prefix-p
              resolved
              (%workspace-canonical-path
               (nerimux/workspace-model:worktree-path worktree))))
           (%workspace-worktrees organizations))))))

(defun %workspace-find-worktree-for-cwd (cwd organizations)
  "Resolve CWD to the deepest worktree containing it."
  (or (%workspace-find-worktree cwd organizations)
      (let ((best nil))
        (dolist (worktree (%workspace-worktrees organizations))
          (let ((path (nerimux/workspace-model:worktree-path worktree)))
            (when 
                (and (%workspace-directory-prefix-p path cwd)
                     (or (null best)
                         (> (length path)
                            (length
                             (nerimux/workspace-model:worktree-path best)))))
              (setf best worktree))))
        best)))

(defun %workspace-strip-dot-git (name)
  "NAME without a trailing \".git\" (case-insensitively, D4): the tree prints
   a bare clone as github.com/org/repo, so that is the only name the user has
   to type back at it, while the catalog holds github.com/org/repo.git, and a
   `.GIT' clone must resolve as an attach selector the same way a `.git' one
   does."
  (nerimux/text:strip-dot-git-suffix name))

(defun %workspace-find-repository-for-attach (token organizations)
  "The repository TOKEN names, by specification, local path, or id (R7.6).

   `nerimux attach github.com/org/repo` is a repository selector, and until this
   existed the attach path matched only against worktrees, so a repository
   spec resolved to nothing and reported \"attach target not found\" for
   something the workspace was holding."
  (when (and (stringp token) (plusp (length token)))
    (let ((wanted (%workspace-strip-dot-git token))
          (resolved (%workspace-canonical-path token)))
      (flet ((matches-p (field)
               (and (stringp field)
                    (or (string= (%workspace-strip-dot-git field) wanted)
                        (and resolved
                             (equal resolved
                                    (%workspace-canonical-path field)))))))
        (loop for organization in organizations
              thereis (find-if
                       (lambda (repository)
                         (some
                          #'matches-p
                          (list
                           (nerimux/workspace-model:repository-specification
                            repository)
                           (nerimux/workspace-model:repository-local-path
                            repository)
                           (nerimux/workspace-model:repository-id repository))))
                       (nerimux/workspace-model:organization-repositories
                        organization)))))))

(defun %workspace-default-tree-selection (organizations &optional filter)
  "The row to land on when no selector and no remembered selection named one:
   the first worktree in display order, or the first repository when the
   catalog holds no worktree at all."
  (let ((objects (%workspace-tree-objects organizations filter)))
    (or (find-if (lambda (object)
                   (typep object 'nerimux/workspace-model:worktree))
                 objects)
        (find-if (lambda (object)
                   (typep object 'nerimux/workspace-model:repository))
                 objects))))
