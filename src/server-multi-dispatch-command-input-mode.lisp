(in-package #:nerimux)

(defun %client-start-worktree-create (session conn)
  "Create a worktree with an automatic branch name and open its shell."
  (let ((repository (%client-selected-repository conn)))
    (if repository
        (%client-create-worktree-now repository
                                     (%client-worktree-create-branch-name)
                                     conn
                                     session)
        (%client-notify conn "select a repository first")))
  t)

(define-worktree-command-entry %client-start-worktree-delete
                               "wt-delete --confirm"
                               "delete")

(define-worktree-command-entry %client-start-worktree-lock
                               "wt-lock --confirm"
                               "lock")

(define-worktree-command-entry %client-start-worktree-unlock
                               "wt-unlock --confirm"
                               "unlock")

(defun %focus-selected-client-worktree (session conn)
  "Enter on the selected tree row (R6.3).

   What Enter means depends on the level, and the two upper levels mean
   something the tree had no way to express before: organization and repository
   rows toggle open and closed, so a workspace of a thousand repositories opens
   showing organizations rather than everything at once. Enter on those used to
   start a worktree-create prompt — which made the create flow reachable but
   left expansion with no key at all."
  (unless (%client-tree-object conn)
    (%select-client-tree-worktree conn nil))
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/workspace-model:organization)
       (%toggle-workspace-node-collapsed
        :organization (nerimux/workspace-model:organization-id object))
       (%mark-dirty)
       t)
      ((keywordp object)
       (%client-toggle-selected-tree-row conn))
      ((typep object 'nerimux/workspace-model:repository)
       (let ((worktree (or (nerimux/workspace-model:repository-main-worktree object)
                            (first (nerimux/workspace-model:repository-worktrees
                                    object)))))
         (if worktree
             (progn
               (%set-client-selected-tree-object conn worktree)
               (%focus-selected-client-worktree session conn))
             (progn
               (%client-notify conn "repository has no worktrees")
               t))))
      ((typep object 'nerimux/pane:pane)
       (%set-client-focus conn object)
       (%set-client-view conn :pane)
       (%mark-dirty)
       t)
      ((and (consp object) (member (first object) '(:file :commit :diff-line :diff-more)))
       t)
      ((typep object 'nerimux/window:window)
       (let ((pane (nerimux/window:window-active-pane object)))
         (when pane
           (%set-client-focus conn pane)
           (%set-client-view conn :pane)))
       (%mark-dirty)
       t)
      (t
       (unless (client-conn-selected-worktree conn)
         (%select-client-tree-worktree conn nil))
       (let* ((worktree (client-conn-selected-worktree conn))
              (pane (or (%worktree-remembered-pane worktree)
                        (%client-worktree-pane session worktree))))
         (cond
           ((and pane (nerimux/pane:pane-live-p pane))
            (%set-client-focus conn pane)
            (%remember-worktree-pane worktree pane)
            (%mark-dirty)
            t)
           (worktree
            (or (%open-client-worktree-pane session conn worktree) t))
           (t
            (%client-notify conn "no worktree selected")
            t)))))))

(defun %client-toggle-selected-file-diff (worktree-id path code)
  "Tab on a :FILE row (Wave C): toggle that file's own inline-diff expansion
   in *WORKSPACE-EXPANDED-NODE-IDS*, keyed (:FILE-DIFF WORKTREE-ID PATH) --
   deliberately NOT the row's own %WORKSPACE-TREE-NODE-KEY, which embeds
   CODE and would drift out of sync with the expansion table the moment the
   file's status changes between an expand and the next status refresh.
   An untracked file (CODE \"??\") has nothing to diff against HEAD --
   %WORKSPACE-WORKTREE-FILE-DIFF-ENTRIES renders its placeholder row from
   CODE alone, so expanding it here never touches the cache or launches a
   fetch. Otherwise, expanding with no cache entry yet (or the last fetch
   failed) launches the fetch; expanding again while :PENDING is a no-op
   dedup, and expanding a :READY entry just reveals the cached rows."
  (let ((key (list :file-diff worktree-id path))
        (table (%workspace-expanded-nodes)))
    (if (gethash key table)
        (remhash key table)
        (progn
          (setf (gethash key table) t)
          (unless (string= code "??")
            (let* ((cache-key (list worktree-id path))
                   (entry (gethash cache-key (%workspace-file-diffs))))
              (when (member (first entry) '(nil :failed))
                (let ((worktree (%workspace-find-worktree worktree-id)))
                  (when worktree
                    (%set-workspace-file-diff cache-key (list :pending 0 nil))
                    (%client-start-worktree-file-diff-refresh worktree path)))))))))
  (%mark-dirty)
  t)

(defun %client-toggle-selected-tree-row (conn)
  "Toggle expansion for the selected section, repository, worktree, or file.
   Expansion state is stored in the corresponding workspace node table.  A
   worktree without cached commits starts an asynchronous commit refresh, and
   a file delegates to %CLIENT-TOGGLE-SELECTED-FILE-DIFF.  No selection is a
   no-op."
  (let ((object (%client-tree-object conn)))
    (cond
      ((keywordp object)
        (let ((key (list :section object))
              (table (%workspace-collapsed-nodes)))
          (if (gethash key table)
              (remhash key table)
              (setf (gethash key table) t)))
        (%mark-dirty)
        t)
      ((typep object 'nerimux/workspace-model:repository)
        (let ((key
               (list :repository (nerimux/workspace-model:repository-id object)))
              (table (%workspace-expanded-nodes)))
          (if (gethash key table)
              (remhash key table)
              (setf (gethash key table) t)))
        (%mark-dirty)
        t)
      ((typep object 'nerimux/workspace-model:worktree)
        (let ((key
               (list :worktree (nerimux/workspace-model:worktree-id object)))
              (table (%workspace-expanded-nodes)))
          (if (gethash key table)
              (remhash key table)
              (progn
                (setf (gethash key table) t)
                (when 
                    (member
                     (nerimux/workspace-model:worktree-commits-state object)
                     '(nil :failed))
                  (setf (nerimux/workspace-model:worktree-commits-state object) :pending)
                  (%client-start-worktree-commits-refresh object)))))
        (%mark-dirty)
        t)
      ((and (consp object) (eq (first object) :file))
       (destructuring-bind (worktree-id path code) (rest object)
         (%client-toggle-selected-file-diff worktree-id path code)))
      (t nil))))

(defun %client-tree-collapse-selected (conn)
  "Collapse the selected organization, section, or repository row."
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/workspace-model:organization)
        (setf (gethash
               (list :organization
                     (nerimux/workspace-model:organization-id object))
               (%workspace-collapsed-nodes)) t)
        (%mark-dirty)
        t)
      ((keywordp object)
        (setf (gethash (list :section object) (%workspace-collapsed-nodes)) t)
        (%mark-dirty)
        t)
      ((typep object 'nerimux/workspace-model:repository)
        (remhash
         (list :repository (nerimux/workspace-model:repository-id object))
         (%workspace-expanded-nodes))
        (%mark-dirty)
        t)
      (t nil))))

(defun %client-tree-expand-selected (conn)
  "Expand the selected organization, section, or repository row."
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/workspace-model:organization)
        (remhash
         (list :organization (nerimux/workspace-model:organization-id object))
         (%workspace-collapsed-nodes))
        (%mark-dirty)
        t)
      ((keywordp object)
        (remhash (list :section object) (%workspace-collapsed-nodes))
        (%mark-dirty)
        t)
      ((typep object 'nerimux/workspace-model:repository)
        (setf (gethash
               (list :repository (nerimux/workspace-model:repository-id object))
               (%workspace-expanded-nodes)) t)
        (%mark-dirty)
        t)
      (t nil))))

(defun %handle-client-input-key-payload (session conn payload)
  "Every byte, ESC included, is forwarded to the focused pane: VIEW :pane has
   no keyboard exit of its own (that returns with the C-q prefix, R4.4)."
  (let ((pane
         (or (client-conn-stdin-target conn)
             (%resolve-client-focus-pane session nil conn))))
    (cond
      ((null pane) (%client-notify conn "no focused pane"))
      ((pane-live-p pane)
       (handler-case (nerimux/pty:pty-write (pane-fd pane) payload)
         (peer-io-failure (condition)
           (%client-notify conn (format nil "input failed: ~A" condition)))))
      ((pane-screen pane) (pane-feed pane payload))
      (t (%client-notify conn "focused pane is unavailable")))
    (%mark-dirty)
    t))
