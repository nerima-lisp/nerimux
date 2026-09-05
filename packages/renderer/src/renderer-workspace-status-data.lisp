(in-package #:nerimux/renderer)

(defun %workspace-status-row-expanded-p (key expanded-node-ids default-p)
  "T when KEY's row should show its children: an explicit T/NIL override in
   EXPANDED-NODE-IDS when one was ever stored for KEY (a TAB toggle on that
   specific row), else DEFAULT-P (the level-implied default; see
   %WORKSPACE-STATUS-SECTION-DEFAULT-EXPANDED-P /
   %WORKSPACE-STATUS-FILE-DIFF-DEFAULT-EXPANDED-P).

   Storing the override as an explicit stored value -- checked with
   NTH-VALUE 1 for presence, not by bare key presence meaning \"expanded\"
   the way the repolist tree's COLLAPSED-NODE-IDS/EXPANDED-NODE-IDS tables
   both work (renderer-workspace-tree.lisp) -- is what makes FR-005's
   visibility level a LENS rather than a destructive write: changing LEVEL
   never touches this table, so a row a user explicitly toggled keeps
   showing (or staying hidden) no matter which level is active afterwards,
   and pressing 4 then 2 reproduces exactly the rows the table already
   encoded before either key was pressed."
  (if (and expanded-node-ids (nth-value 1 (gethash key expanded-node-ids)))
      (gethash key expanded-node-ids)
      default-p))

(defun %workspace-status-section-default-expanded-p (level)
  "Level 1 shows section headings only; level >= 2 shows their contents."
  (>= level 2))

(defun %workspace-status-file-diff-default-expanded-p (level)
  "Level >= 3 (\"also file diffs\"/\"everything\") shows every file's inline
   diff by default. Levels 3 and 4 are behaviourally identical in this view
   -- there is no third nesting level below a file's own diff lines for a
   higher level to additionally unfold -- level 4 exists for FR-005's own
   4-level symmetry with the repolist tree, which may have one."
  (>= level 3))

(defun %workspace-status-head-parts (worktree)
  "List of (TEXT . STYLE-OR-NIL) parts for the Head row, plain-first-then-
   styled the way %WORKTREE-AHEAD-BEHIND-PARTS (renderer-workspace-tree.lisp)
   already builds the tree's own info cluster -- one source list drives both
   this row's plain LABEL (WORKSPACE-STATUS-ENTRIES) and its coloured render
   spans (%WORKSPACE-STATUS-HEAD-SPANS) below, so the two can't drift apart."
  (let ((branch (worktree-branch worktree))
        (head (worktree-head worktree))
        (ahead (worktree-ahead worktree))
        (behind (worktree-behind worktree)))
    (remove nil
            (list (cons "Head:     " nil)
                  (cons (or branch "(detached)")
                        (%workspace-status-style-accent-bold))
                  (and head
                       (plusp (length head))
                       (cons (format nil " (~A)" head)
                             (%workspace-status-style-faint)))
                  (and (plusp ahead)
                       (cons (format nil " +~D" ahead)
                             (%workspace-status-style-ok)))
                  (and (plusp behind)
                       (cons (format nil " -~D" behind)
                             (%workspace-status-style-orange)))))))

(defun %workspace-status-head-label (worktree)
  (format nil "~{~A~}" (mapcar #'car (%workspace-status-head-parts worktree))))

(defun %workspace-status-head-spans (worktree)
  (mapcar
   (lambda (part)
     (if (cdr part)
         (cl-tui-kit/core:make-text-span (car part) :style (cdr part))
         (cl-tui-kit/core:make-text-span (car part))))
   (%workspace-status-head-parts worktree)))

(defun %workspace-status-head-entries (worktree)
  "The Head section: one KIND :HEAD row, omitted only when WORKTREE has
   neither a branch nor a resolved HEAD at all (an uninitialised worktree) --
   the same \"omitted when empty\" rule every other section in this view
   follows, applied to a section that never has a count of its own."
  (when 
      (or
       (and (worktree-branch worktree)
            (plusp (length (worktree-branch worktree))))
       (and (worktree-head worktree) (plusp (length (worktree-head worktree)))))
    (list (list 0 (%workspace-status-head-label worktree) worktree :head))))

(defun %workspace-status-file-diff-child-entries (worktree-id path
                                                              code
                                                              level
                                                              expanded-node-ids
                                                              file-diffs
                                                              diff-default-p)
  "The inline-diff child rows for one status-view :FILE row, gated
   by the status view's own level-aware %WORKSPACE-STATUS-ROW-EXPANDED-P
   rather than %WORKSPACE-WORKTREE-FILE-DIFF-ENTRIES's plain presence check
   (renderer-workspace-tree.lisp) -- that function's gate has no notion of
   VISIBILITY-LEVEL, and it is not this agent's file to add one to. The
   untracked-file placeholder and the cache-entry lookup are the same shape
   that function uses; the actual line formatting is still
   %WORKSPACE-FILE-DIFF-LINE-ENTRIES, which is reused unchanged."
  (when 
      (%workspace-status-row-expanded-p (list :file-diff worktree-id path)
                                        expanded-node-ids
                                        diff-default-p)
    (if (string= code "??")
        (list
         (list level
               "(untracked file)"
               (list :diff-line worktree-id path :untracked)
               :diff-line))
        (%workspace-file-diff-line-entries worktree-id
                                           path
                                           level
                                           (and file-diffs
                                                (gethash (list worktree-id path)
                                                         file-diffs))))))

(defun %workspace-status-file-entries (files worktree-id
                                             level
                                             expanded-node-ids
                                             file-diffs
                                             diff-default-p)
  "One LEVEL entry per (CODE . PATH) cons in FILES -- one of WORKTREE's four
   partitioned change lists (Unit MODEL: staged/unstaged/untracked/unmerged-
   files) -- each followed by its own inline-diff child rows."
  (loop for (code . path) in files
        append (cons
                (list level
                      (format nil "~A ~A" code path)
                      (list :file worktree-id path code)
                      :file)
                (%workspace-status-file-diff-child-entries worktree-id
                                                           path
                                                           code
                                                           (1+ level)
                                                           expanded-node-ids
                                                           file-diffs
                                                           diff-default-p))))

(defun %workspace-status-file-code-style (code)
  "The colour for a :FILE row's status CODE, chosen from the change TYPE the
   code letter names (A add / D delete / R,C rename,copy / M and everything
   else \"modified\"), not from which of the four partitioned lists the row
   came from: STAGED-FILES and UNSTAGED-FILES can both legitimately hold the
   SAME single-character CODE for the same path (a file modified in both the
   index and the worktree shows in both sections, Unit MODEL's own
   documented magit behaviour), so the code alone cannot tell staged and
   unstaged apart -- only which SECTION the row is grouped under can, and
   that is already visible from its position in the frame."
  (cond
    ((string= code "??") (%workspace-status-style-muted))
    ((>= (length code) 2) (%workspace-status-style-alert)) ; unmerged/conflict
    ((zerop (length code)) (%workspace-status-style-plain))
    (t (case (char code 0)
         (#\A (%workspace-status-style-ok))
         (#\D (%workspace-status-style-alert))
         ((#\R #\C) (%workspace-status-style-accent))
         (t (%workspace-status-style-warn))))))

(defun %workspace-status-stash-entries (worktree level)
  "LEVEL entries for WORKTREE's stash group -- mirrors %WORKSPACE-WORKTREE-
   COMMIT-CHILD-ENTRIES's :PENDING/:FAILED placeholder convention exactly
   (renderer-workspace-tree.lisp). Stash messages are already control-
   character-stripped at the source (LIST-WORKTREE-STASHES,
   vcs-git-write.lisp, via %SANITIZE-RETAINED-TEXT) -- not re-stripped here,
   which would just be the same trust boundary re-applied a second time."
  (case (worktree-stashes-state worktree)
    (:pending
     (list
      (list level
            "stashes: refreshing..."
            (list :stash (worktree-id worktree) :pending nil)
            :stash)))
    (:failed
     (list
      (list level
            "stashes: UNKNOWN"
            (list :stash (worktree-id worktree) :failed nil)
            :stash)))
    (:ready
     (loop for (reference . message) in (worktree-stashes worktree)
           collect (list level
                         (format nil "~A ~A" reference message)
                         (list :stash (worktree-id worktree) reference message)
                         :stash)))
    (t nil)))

(defun %workspace-status-sibling-worktree-entries (worktree level)
  "One LEVEL entry per sibling of WORKTREE under its own repository -- every
   REPOSITORY-WORKTREES entry except WORKTREE itself, sorted by path for a
   stable, deterministic row order the way %WORKSPACE-WORKTREE-PANE-CHILD-
   ENTRIES sorts by PANE-ID for the same reason (renderer-workspace-
   tree.lisp): REPOSITORY-WORKTREES is push order (REPOSITORY-ADD-WORKTREE),
   which would otherwise read newest-first."
  (let ((repository (worktree-repository worktree)))
    (loop for sibling in (sort
                          (copy-list
                           (and repository (repository-worktrees repository)))
                          #'string<
                          :key
                          #'worktree-path)
          unless (eq sibling worktree)
            collect (list level
                          (%worktree-tree-label sibling)
                          sibling
                          :worktree))))

(defun %workspace-status-section-entries (key heading
                                              count
                                              child-entries
                                              expanded-node-ids
                                              section-default-p)
  "One level-0 (0 LABEL KEY :SECTION) header entry carrying a live
   \"HEADING (COUNT)\", plus CHILD-ENTRIES beneath it when the section is
   expanded -- NIL (the section omitted entirely) when COUNT is zero. Same
   contract as %WORKSPACE-SECTION-ENTRIES (renderer-workspace-tree.lisp) for
   the repolist tree, keyed instead by this view's own per-section
   expansion entry -- see %WORKSPACE-STATUS-ROW-EXPANDED-P."
  (when (plusp count)
    (cons (list 0 (format nil "~A (~D)" heading count) key :section)
          (when 
              (%workspace-status-row-expanded-p (list :status-section key)
                                                expanded-node-ids
                                                section-default-p)
            child-entries))))

(defun workspace-status-entries (worktree &key
                                          expanded-node-ids
                                          file-diffs
                                          (visibility-level 2))
  "The magit-style status buffer's rows for WORKTREE, flattened into (LEVEL
   LABEL OBJECT KIND) tuples in this fixed section order, each section
   omitted entirely when it has nothing to show: Head, Unmerged, Untracked,
   Unstaged, Staged, Stashes, Recent commits, Panes, Worktrees (contract §3)."
  (let* ((level (or visibility-level 2))
         (section-default-p
          (%workspace-status-section-default-expanded-p level))
         (diff-default-p (%workspace-status-file-diff-default-expanded-p level))
         (worktree-id (worktree-id worktree))
         (unmerged-children
          (%workspace-status-file-entries (worktree-unmerged-files worktree)
                                          worktree-id
                                          1
                                          expanded-node-ids
                                          file-diffs
                                          diff-default-p))
         (untracked-children
          (%workspace-status-file-entries (worktree-untracked-files worktree)
                                          worktree-id
                                          1
                                          expanded-node-ids
                                          file-diffs
                                          diff-default-p))
         (unstaged-children
          (%workspace-status-file-entries (worktree-unstaged-files worktree)
                                          worktree-id
                                          1
                                          expanded-node-ids
                                          file-diffs
                                          diff-default-p))
         (staged-children
          (%workspace-status-file-entries (worktree-staged-files worktree)
                                          worktree-id
                                          1
                                          expanded-node-ids
                                          file-diffs
                                          diff-default-p))
         (stash-children (%workspace-status-stash-entries worktree 1))
         (commit-children (%workspace-worktree-commit-child-entries worktree 1))
         (pane-children (%workspace-worktree-pane-child-entries worktree 1))
         (worktree-children
          (%workspace-status-sibling-worktree-entries worktree 1)))
    (append (%workspace-status-head-entries worktree)
            (%workspace-status-section-entries :unmerged
                                               "Unmerged changes"
                                               (length
                                                (worktree-unmerged-files
                                                 worktree))
                                               unmerged-children
                                               expanded-node-ids
                                               section-default-p)
            (%workspace-status-section-entries :untracked
                                               "Untracked files"
                                               (length
                                                (worktree-untracked-files
                                                 worktree))
                                               untracked-children
                                               expanded-node-ids
                                               section-default-p)
            (%workspace-status-section-entries :unstaged
                                               "Unstaged changes"
                                               (length
                                                (worktree-unstaged-files
                                                 worktree))
                                               unstaged-children
                                               expanded-node-ids
                                               section-default-p)
            (%workspace-status-section-entries :staged
                                               "Staged changes"
                                               (length
                                                (worktree-staged-files worktree))
                                               staged-children
                                               expanded-node-ids
                                               section-default-p)
            (%workspace-status-section-entries :stashes
                                               "Stashes"
                                               (length stash-children)
                                               stash-children
                                               expanded-node-ids
                                               section-default-p)
            (%workspace-status-section-entries :commits
                                               "Recent commits"
                                               (length commit-children)
                                               commit-children
                                               expanded-node-ids
                                               section-default-p)
            (%workspace-status-section-entries :panes
                                               "Panes"
                                               (length pane-children)
                                               pane-children
                                               expanded-node-ids
                                               section-default-p)
            (%workspace-status-section-entries :worktrees
                                               "Worktrees"
                                               (length worktree-children)
                                               worktree-children
                                               expanded-node-ids
                                               section-default-p))))

(defun workspace-status-objects (worktree &key
                                          expanded-node-ids
                                          file-diffs
                                          visibility-level)
  "The objects WORKSPACE-STATUS-ENTRIES shows, in display order. Key
   dispatch selects by index into this list, so it must be exactly the same
   list RENDER-WORKSPACE-STATUS-TO-TUI-STRING draws from -- the same
   contract WORKSPACE-TREE-OBJECTS holds for the repolist tree
   (package-presentation.lisp)."
  (mapcar #'third
          (workspace-status-entries worktree
                                    :expanded-node-ids
                                    expanded-node-ids
                                    :file-diffs
                                    file-diffs
                                    :visibility-level
                                    visibility-level)))
