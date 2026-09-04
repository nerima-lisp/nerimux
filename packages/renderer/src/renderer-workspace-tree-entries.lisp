(in-package #:nerimux/renderer)

(defun %workspace-worktree-node-expanded-p (worktree expanded-node-ids)
  (and expanded-node-ids
       (gethash (%workspace-tree-node-key worktree) expanded-node-ids)
       t))

(defun %workspace-worktree-pane-child-entries (worktree level)
  "One LEVEL entry per WORKTREE pane, ordered by PANE-ID for a stable,
   deterministic row order -- WORKTREE-PANES itself is insertion order
   (WORKTREE-ADD-PANE pushes), which would otherwise read newest-first."
  (loop for pane in (sort (copy-list (worktree-panes worktree))
                          #'<
                          :key
                          #'pane-id)
        collect (list level (%pane-tree-label pane) pane :pane)))

(defun %workspace-file-diff-line-entries (worktree-id path level cache-entry)
  "LEVEL entries for one expanded :FILE row's own inline diff,
   mirroring %WORKSPACE-WORKTREE-COMMIT-CHILD-ENTRIES's :PENDING/:FAILED
   placeholder convention one level down: CACHE-ENTRY is (STATE TOTAL LINES)
   from *WORKSPACE-FILE-DIFFS* (bootstrap), or NIL while nothing has been
   requested for this file yet -- NIL rows, not even a placeholder, exactly
   as the commit group's NIL/never-fetched case works. :READY emits one
   :DIFF-LINE row per cached LINE (OBJECT (:DIFF-LINE WORKTREE-ID PATH
   INDEX)), then a trailing :DIFF-MORE row when TOTAL exceeds the number of
   LINES actually cached (the fetch's own *WORKTREE-DIFF-LINE-LIMIT* cap)."
  (destructuring-bind (&optional state total lines) cache-entry
    (case state
      (:pending
       (list
        (list level
              "diff: refreshing..."
              (list :diff-line worktree-id path :pending)
              :diff-line)))
      (:failed
       (list
        (list level
              "diff: UNKNOWN"
              (list :diff-line worktree-id path :failed)
              :diff-line)))
      (:ready
       (append
        (loop for line in lines
              for index from 0
              collect (list level
                            line
                            (list :diff-line worktree-id path index)
                            :diff-line))
        (when (and total (> total (length lines)))
          (list
           (list level
                 (format nil "... ~D more lines" (- total (length lines)))
                 (list :diff-more worktree-id path)
                 :diff-line)))))
      (t nil))))

(defun %workspace-worktree-file-diff-entries (worktree-id path
                                                          code
                                                          level
                                                          expanded-node-ids
                                                          file-diffs)
  "The inline-diff child rows for one :FILE row, when that file's
   own (:FILE-DIFF WORKTREE-ID PATH) key is expanded in EXPANDED-NODE-IDS --
   deliberately NOT the :FILE row's own %WORKSPACE-TREE-NODE-KEY, which
   embeds CODE and would drift out of sync with the expansion table the
   moment the file's status changes. An untracked file (CODE \"??\") has
   nothing to diff against HEAD -- a single muted placeholder row, not a
   cache lookup that will never resolve for it."
  (when 
      (and expanded-node-ids
           (gethash (list :file-diff worktree-id path) expanded-node-ids))
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

(defun %workspace-worktree-file-child-entries (worktree level
                                                        &key
                                                        expanded-node-ids
                                                        file-diffs)
  "One LEVEL entry per WORKTREE-CHANGED-FILES entry (plain (CODE . PATH)
   conses), labelled \"XY path\" the way `git status --short` shows it,
   followed by that file's own inline-diff child rows (LEVEL+1)."
  (let ((worktree-id (worktree-id worktree)))
    (loop for (code . path) in (worktree-changed-files worktree)
          append (cons
                  (list level
                        (format nil "~A ~A" code path)
                        (list :file worktree-id path code)
                        :file)
                  (%workspace-worktree-file-diff-entries worktree-id
                                                         path
                                                         code
                                                         (1+ level)
                                                         expanded-node-ids
                                                         file-diffs)))))

(defun %workspace-worktree-commit-child-entries (worktree level)
  "LEVEL entries for WORKTREE's recent-commit group: one placeholder row
   while WORKTREE-COMMITS-STATE is :PENDING or :FAILED, one row per
   WORKTREE-RECENT-COMMITS entry once :READY, and no row at all (not even a
   placeholder) while COMMITS-STATE is still NIL -- the history has never
   been requested, so there is nothing yet to say about it."
  (case (worktree-commits-state worktree)
    (:pending
     (list
      (list level
            "commits: refreshing..."
            (list :commit (worktree-id worktree) :pending nil)
            :commit)))
    (:failed
     (list
      (list level
            "commits: UNKNOWN"
            (list :commit (worktree-id worktree) :failed nil)
            :commit)))
    (:ready
     (loop for (hash . subject) in (worktree-recent-commits worktree)
           collect (list level
                         (format nil "~A ~A" hash subject)
                         (list :commit (worktree-id worktree) hash subject)
                         :commit)))
    (t nil)))

(defun %workspace-worktree-detail-entries (worktree level
                                                    expanded-node-ids
                                                    &key
                                                    file-diffs)
  "Child rows for WORKTREE's inline expansion, one LEVEL deeper than
   WORKTREE's own row -- NIL when WORKTREE is not expanded
   (%WORKSPACE-WORKTREE-NODE-EXPANDED-P). FILE-DIFFS is forwarded
   to the file group alone -- the pane and commit groups have no diff data
   of their own."
  (when (%workspace-worktree-node-expanded-p worktree expanded-node-ids)
    (append (%workspace-worktree-pane-child-entries worktree level)
            (%workspace-worktree-file-child-entries worktree
                                                    level
                                                    :expanded-node-ids
                                                    expanded-node-ids
                                                    :file-diffs
                                                    file-diffs)
            (%workspace-worktree-commit-child-entries worktree level))))

(defun %workspace-worktree-needs-attention-p (worktree)
  "T when WORKTREE itself belongs under the Attention section: WORKTREE-
   ATTENTION-P (dirty/conflict/ahead/behind/missing -- the existing model
   predicate), or any of its panes has exited. An exited pane is not part of
   WORKTREE-ATTENTION-P's own definition (that predicate knows nothing about
   panes), but leaving a dead shell buried under a collapsed repository row
   is exactly the kind of thing this section exists to surface."
  (or (worktree-attention-p worktree)
      (some #'pane-process-exited-p (worktree-panes worktree))))

(defun %workspace-classify-worktrees (organizations)
  "Three values, plus a fourth: a list of (ORGANIZATION REPOSITORY WORKTREE)
   tuples for every worktree needing attention (%WORKSPACE-WORKTREE-NEEDS-
   ATTENTION-P); the same shape for every other worktree holding at least
   one pane (Active); a list of (ORGANIZATION REPOSITORY) tuples for every
   repository; and an EQ hash-table of every worktree already placed into
   Attention or Active, so the Repositories section's own worktree listing
   (%WORKSPACE-REPOSITORIES-SECTION-ENTRIES) can exclude them -- a worktree
   appears in at most one section, never twice under a different one.

   All three lists preserve ORGANIZATIONS' own order: %SORT-WORKSPACE-
   ORGANIZATIONS-BY-ACTIVITY (vcs.lisp) already put organizations,
   repositories, and worktrees into activity order once, at catalog publish
   time -- this walk never re-sorts, so a row does not move under the cursor
   between refreshes."
  (let (attention
        active
        repositories
        (shown (make-hash-table :test #'eq)))
    (dolist (organization organizations)
      (dolist (repository (organization-repositories organization))
        (push (list organization repository) repositories)
        (dolist (worktree (repository-worktrees repository))
          (cond
            ((%workspace-worktree-needs-attention-p worktree)
              (push (list organization repository worktree) attention)
              (setf (gethash worktree shown) t))
            ((worktree-panes worktree)
              (push (list organization repository worktree) active)
              (setf (gethash worktree shown) t))))))
    (values (nreverse attention)
            (nreverse active)
            (nreverse repositories)
            shown)))

(defun %workspace-section-worktree-label (organization repository worktree)
  "\"org/repo · branch\" row label for a worktree under Attention or Active."
  (format nil
          "~A/~A · ~A"
          (%organization-tree-label organization)
          (%repository-tree-label repository)
          (%worktree-tree-label worktree)))

(defun %workspace-repository-row-label (organization repository)
  "\"org/name\" row label for a repository under the Repositories section."
  (format nil
          "~A/~A"
          (%organization-tree-label organization)
          (%repository-tree-label repository)))

(defun %workspace-repository-node-expanded-p (id expanded-node-ids)
  "T when the (:REPOSITORY ID) row under the Repositories section shows its
   worktrees. Repository rows here default COLLAPSED (a section-based-
   redesign decision) -- the opposite sense from every other row's own
   collapse state, which defaults expanded (%WORKSPACE-NODE-EXPANDED-P) --
   so this checks presence in EXPANDED-NODE-IDS rather than absence."
  (and expanded-node-ids (gethash (list :repository id) expanded-node-ids) t))

(defun %workspace-worktree-section-entries (triples refreshing-ids
                                                    stale-ids
                                                    expanded-node-ids
                                                    &key
                                                    file-diffs)
  "One level-1 (LEVEL LABEL OBJECT :WORKTREE) entry per (ORGANIZATION
   REPOSITORY WORKTREE) in TRIPLES, for the Attention/Active sections,
   followed by that worktree's own inline-expansion child rows at
   level 2) when it is expanded."
  (loop for (organization repository worktree) in triples
        append (cons
                (list 1
                      (concatenate 'string
                                   (%workspace-section-worktree-label
                                    organization
                                    repository
                                    worktree)
                                   (%workspace-node-refresh-tag :worktree
                                                                (worktree-id
                                                                 worktree)
                                                                refreshing-ids
                                                                stale-ids))
                      worktree
                      :worktree)
                (%workspace-worktree-detail-entries worktree
                                                    2
                                                    expanded-node-ids
                                                    :file-diffs
                                                    file-diffs))))

(defun %workspace-repositories-section-entries (repository-tuples
                                                shown-worktrees
                                                expanded-node-ids
                                                filter-active-p
                                                refreshing-ids
                                                stale-ids
                                                &key
                                                file-diffs)
  "One level-1 (LEVEL LABEL OBJECT :REPOSITORY) entry per (ORGANIZATION
   REPOSITORY) in REPOSITORY-TUPLES, followed -- when that repository row is
   expanded (%WORKSPACE-REPOSITORY-NODE-EXPANDED-P, or FILTER-ACTIVE-P
   bypasses the default collapse the same way organization/repository rows
   used to) -- by one level-2 (LEVEL LABEL OBJECT :WORKTREE) entry per
   worktree not already in SHOWN-WORKTREES (the Attention/Active set: a
   worktree never appears twice), each followed in turn by its own inline-
   expansion child rows at level 3 when that worktree is expanded.
   Repository rows themselves are never gated by section collapse -- only
   the wrapping %WORKSPACE-SECTION-ENTRIES call folds the whole
   Repositories section, including its repository rows, as one unit."
  (loop for (organization repository) in repository-tuples
        append (cons
                (list 1
                      (concatenate 'string
                                   (%workspace-repository-row-label organization
                                                                    repository)
                                   (%workspace-node-refresh-tag :repository
                                                                (repository-id
                                                                 repository)
                                                                refreshing-ids
                                                                stale-ids))
                      repository
                      :repository)
                (when 
                    (or filter-active-p
                        (%workspace-repository-node-expanded-p
                         (repository-id repository)
                         expanded-node-ids))
                  (loop for worktree in (repository-worktrees repository)
                        unless (gethash worktree shown-worktrees)
                          append (cons
                                  (list 2
                                        (concatenate 'string
                                                     (%worktree-tree-label
                                                      worktree)
                                                     (%workspace-node-refresh-tag
                                                      :worktree
                                                      (worktree-id worktree)
                                                      refreshing-ids
                                                      stale-ids))
                                        worktree
                                        :worktree)
                                  (%workspace-worktree-detail-entries worktree
                                                                      3
                                                                      expanded-node-ids
                                                                      :file-diffs
                                                                      file-diffs)))))))

(defun %workspace-section-entries (key label
                                       count
                                       row-entries
                                       collapsed-node-ids
                                       filter-active-p)
  "One level-0 (LEVEL LABEL OBJECT :SECTION) header entry for KEY (one of
   :ATTENTION/:ACTIVE/:REPOSITORIES) carrying a live \"LABEL (COUNT)\", plus
   ROW-ENTRIES beneath it when the section itself is expanded -- absent from
   COLLAPSED-NODE-IDS under key (:SECTION KEY) (the same table and the same
   default-expanded polarity %WORKSPACE-NODE-EXPANDED-P uses elsewhere), or
   FILTER-ACTIVE-P, so a filter can still surface a match inside a collapsed
   section. Returns NIL -- omitting the section entirely -- when COUNT is
   zero (empty sections are omitted from the tree)."
  (when (plusp count)
    (cons (list 0 (format nil "~A (~D)" label count) key :section)
          (when 
              (or filter-active-p
                  (%workspace-node-expanded-p :section key collapsed-node-ids))
            row-entries))))

(defun workspace-tree-objects (organizations collapsed-node-ids
                                             &key
                                             filter
                                             expanded-node-ids
                                             file-diffs)
  "The objects the tree currently shows, in display order."
  (mapcar #'third
          (%workspace-flat-tree-entries organizations
                                        collapsed-node-ids
                                        :filter
                                        filter
                                        :expanded-node-ids
                                        expanded-node-ids
                                        :file-diffs
                                        file-diffs)))

(defun %workspace-flat-tree-entries (organizations collapsed-node-ids
                                                   &key
                                                   refreshing-ids
                                                   stale-ids
                                                   filter
                                                   expanded-node-ids
                                                   file-diffs)
  "Flatten ORGANIZATIONS into (LEVEL LABEL OBJECT KIND) display tuples, in
   three fixed sections -- Attention, Active, Repositories (see
   %WORKSPACE-CLASSIFY-WORKTREES) -- optionally narrowed to FILTER (see
   %WORKSPACE-FILTER-TREE-ENTRIES). EXPANDED-NODE-IDS (default-COLLAPSED
   polarity; see %WORKSPACE-REPOSITORY-NODE-EXPANDED-P) governs whether a
   Repositories-section repository row shows its worktrees; COLLAPSED-NODE-
   IDS (default-EXPANDED polarity; see %WORKSPACE-NODE-EXPANDED-P) governs
   whether a section itself is folded, keyed (:SECTION :ATTENTION/:ACTIVE/
   :REPOSITORIES).

   Search penetrates collapse: when FILTER is non-blank, every section and
   every repository row is descended into regardless of COLLAPSED-NODE-IDS/
   EXPANDED-NODE-IDS -- a collapsed section or repository can still hold the
   row the user is searching for, and the contract a caller reads off this
   function's name is \"search the whole tree\", not \"search whatever
   happens to be expanded\". %WORKSPACE-FILTER-TREE-ENTRIES alone decides
   what is actually visible from the (now fully descended) raw entries."
  (let ((filter-active-p (and filter (plusp (length (string-trim " " filter))))))
    (multiple-value-bind (attention active repositories shown) 
        (%workspace-classify-worktrees organizations)
      (let ((entries
             (append
              (%workspace-section-entries :attention
                                          "Attention"
                                          (length attention)
                                          (%workspace-worktree-section-entries
                                           attention
                                           refreshing-ids
                                           stale-ids
                                           expanded-node-ids
                                           :file-diffs
                                           file-diffs)
                                          collapsed-node-ids
                                          filter-active-p)
              (%workspace-section-entries :active
                                          "Active"
                                          (length active)
                                          (%workspace-worktree-section-entries
                                           active
                                           refreshing-ids
                                           stale-ids
                                           expanded-node-ids
                                           :file-diffs
                                           file-diffs)
                                          collapsed-node-ids
                                          filter-active-p)
              (%workspace-section-entries :repositories
                                          "Repositories"
                                          (length repositories)
                                          (%workspace-repositories-section-entries
                                           repositories
                                           shown
                                           expanded-node-ids
                                           filter-active-p
                                           refreshing-ids
                                           stale-ids
                                           :file-diffs
                                           file-diffs)
                                          collapsed-node-ids
                                          filter-active-p))))
        (%workspace-filter-tree-entries entries filter)))))
