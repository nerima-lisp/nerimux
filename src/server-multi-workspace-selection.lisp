(in-package #:nerimux)

(defun %picker-item-worktree (item)
  (or (nerimux/picker:picker-item-worktree item)
      (let ((repository (nerimux/picker:picker-item-repository item)))
        (or
         (and repository
              (or (nerimux/workspace-model:repository-main-worktree repository)
                  (first
                   (nerimux/workspace-model:repository-worktrees repository))))
         (let ((organization (nerimux/picker:picker-item-organization item)))
           (when organization
             (loop for repository in (nerimux/workspace-model:organization-repositories
                                      organization)
                   for worktree = (or
                                   (nerimux/workspace-model:repository-main-worktree
                                    repository)
                                   (first
                                    (nerimux/workspace-model:repository-worktrees
                                     repository)))
                   when worktree
                     return worktree)))))))

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
  "The tree rows a client can currently select, in display order.

   Delegates to the renderer rather than walking the model itself. It used to
   flatten organization -> repository -> worktree unconditionally, which was
   correct only while the tree was always fully expanded: once R6.3 made rows
   collapse and added the window and pane levels, this enumeration and the drawn
   frame described different lists, and j/k walked the cursor onto rows the
   frame was not showing.

   FILTER, when given, must be the same in-tree-filter query string the frame
   was rendered with (CLIENT-CONN-TREE-FILTER) -- callers that move the
   cursor or resolve a selection have to walk the SAME filtered row set the
   client is actually looking at, or j/k and Enter would land on a row the
   filter had hidden from the drawn frame. FILE-DIFFS (Wave C) is the same
   cache the frame's own render pass reads, so an expanded :FILE row's
   :DIFF-LINE child rows are selectable rows here too, not just pixels on
   screen."
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
              (if (and (string/= directory "")
                       (char= (char directory (1- (length directory))) #\/))
                  directory
                  (concatenate 'string directory "/"))))
         (or (string= directory path)
             (and (>= (length path) (length prefix))
                  (string= prefix path :end2 (length prefix)))))))

(defun %workspace-find-worktree-for-attach (token organizations)
  "Resolve an EXPLICIT attach selector TOKEN to a worktree.
   The prefix fallback deliberately asks \"is TOKEN a directory prefix of the
   worktree's path\" -- TOKEN names a place to search UNDER, so an ancestor
   token matching the first worktree found is the intended behavior here
   (pinned by server-dispatch-helper-tests).  Do not reuse this for cwd-based
   auto-selection: a cwd is the LONGER string, and this direction silently
   matched an arbitrary worktree from any ancestor directory --
   %WORKSPACE-FIND-WORKTREE-FOR-CWD below is that path's correct inverse."
  (or (%workspace-find-worktree token organizations)
      (find-if
       (lambda (worktree)
         (%workspace-directory-prefix-p token
                                        (nerimux/workspace-model:worktree-path
                                         worktree)))
       (%workspace-worktrees organizations))))

(defun %workspace-find-worktree-for-cwd (cwd organizations)
  "The worktree CWD sits inside, preferring the most specific (deepest) match.

   %workspace-find-worktree-for-attach is for an explicit selector: TOKEN names a
   directory to search under, so the worktree's path is the longer string and
   TOKEN the prefix. A cwd runs the other way -- it is the longer string, and the
   worktree's path must be its prefix. Reusing the attach direction here let any
   ancestor of every worktree (the ghq root, $HOME) match every worktree path as
   a 'prefix' of TOKEN and silently pre-select whichever worktree the scan
   reached first. Two worktrees can also nest (one's path a prefix of another's),
   so this keeps the longest-matching -- most specific -- worktree rather than
   the first one found."
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

(defun %workspace-find-repository-for-attach (token organizations)
  "The repository TOKEN names, by specification, local path, or id (R7.6).

   `nerimux attach github.com/org/repo` is a repository selector, and until this
   existed the attach path matched only against worktrees — so a repository
   spec resolved to nothing and reported \"attach target not found\" for
   something the workspace was holding."
  (when (and (stringp token) (plusp (length token)))
    (loop for organization in organizations
          thereis (find-if
                   (lambda (repository)
                     (some
                      (lambda (field)
                        (and (stringp field) (string= field token)))
                      (list
                       (nerimux/workspace-model:repository-specification
                        repository)
                       (nerimux/workspace-model:repository-local-path
                        repository)
                       (nerimux/workspace-model:repository-id repository))))
                   (nerimux/workspace-model:organization-repositories
                    organization)))))
