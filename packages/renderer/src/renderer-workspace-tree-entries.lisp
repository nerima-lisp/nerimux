(in-package #:nerimux/renderer)

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
  (when (and expanded-node-ids
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
   conses), labelled \"state path\" with CODE's porcelain XY pair turned into
   a word (%CHANGED-FILE-STATE-TEXT), followed by that file's own inline-diff
   child rows (LEVEL+1). The row's OBJECT still carries the raw CODE, which
   the detail panel and the styling both read."
  (let ((worktree-id (worktree-id worktree)))
    (loop for (code . path) in (worktree-changed-files worktree)
          append (cons
                  (list level
                        (format nil "~A ~A" (%changed-file-state-text code) path)
                        (list :file worktree-id path code)
                        :file
                        (%workspace-tree-row-fold
                         (list :file worktree-id path code)
                         :file
                         (and expanded-node-ids
                              (gethash (list :file-diff worktree-id path)
                                       expanded-node-ids)
                              t)))
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
  "T when WORKTREE itself belongs under the Attention section: at least one
   of its NERIMUX/PANE:WORKTREE-ATTENTION-REASONS is :CONFLICT, :MISSING,
   :WAITING or :PANE, or one of its panes has exited. Dirty and ahead/behind
   alone no longer qualify: those are the routine, expected state of a
   worktree-per-task workflow rather than something the user must act on --
   for one user's 339 real worktrees, the old WORKTREE-ATTENTION-P-based rule
   (which treats dirty/ahead/behind the same as conflict/missing) put 184 of
   them under Attention, crowding the Repositories section off screen below
   them. A worktree excluded here by this narrower rule still shows under
   its own repository row, still carrying its `!' mark via
   %WORKSPACE-TREE-NODE-MARK -- that mark reads WORKTREE-ATTENTION-P
   (unchanged) and repository-level aggregation, neither of which this
   function touches."
  (and (or (intersection '(:conflict :missing :waiting :pane)
                        (nerimux/pane:worktree-attention-reasons worktree))
           (some #'pane-process-exited-p (worktree-panes worktree)))
       t))

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

(defun %workspace-repository-node-expanded-p (id expanded-node-ids)
  "T when the (:REPOSITORY ID) row under the Repositories section shows its
   worktrees. Repository rows default COLLAPSED, unlike other rows whose
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
                      :worktree
                      (%workspace-tree-row-fold
                       worktree
                       :worktree
                       (%workspace-worktree-node-expanded-p worktree
                                                            expanded-node-ids)))
                (%workspace-worktree-detail-entries worktree
                                                    2
                                                    expanded-node-ids
                                                    :file-diffs
                                                    file-diffs))))

(defun %repository-row-expandable-p (repository)
  "T when REPOSITORY's row under the Repositories section has worktrees of
   its own to unfold. Applies %WORKSPACE-CLASSIFY-WORKTREES' rule to one
   repository: a worktree already listed under Attention or Active is not
   repeated here, so a repository whose only worktree is shown above unfolds
   onto nothing. The key panel's own Enter/Tab hint for a repository row no
   longer conditions on this (it always reads \"expand\" now); this
   predicate remains for server-side dispatch code deciding whether
   Enter/Tab actually has a worktree list to toggle."
  (and (some (lambda (worktree)
               (not (or (%workspace-worktree-needs-attention-p worktree)
                        (worktree-panes worktree))))
             (repository-worktrees repository))
       t))

(defun %workspace-repository-row-entries (repository shown-worktrees
                                          expanded-node-ids
                                          filter-active-p
                                          refreshing-ids
                                          stale-ids
                                          file-diffs)
  "One level-2 (LEVEL LABEL OBJECT :REPOSITORY) entry for REPOSITORY under
   an expanded organization row, labelled by %REPOSITORY-TREE-LABEL alone
   (the enclosing organization row already carries the org/host context),
   followed -- when the repository row itself is expanded
   (%WORKSPACE-REPOSITORY-NODE-EXPANDED-P, or FILTER-ACTIVE-P bypasses the
   default collapse) -- by one level-3 (LEVEL LABEL OBJECT :WORKTREE) entry
   per worktree not already in SHOWN-WORKTREES (the Attention/Active set: a
   worktree never appears twice), each followed by its own inline-expansion
   child rows at level 4."
  (let* ((expanded-p (or filter-active-p
                         (%workspace-repository-node-expanded-p
                          (repository-id repository)
                          expanded-node-ids)))
         (worktrees (remove-if (lambda (worktree)
                                 (gethash worktree shown-worktrees))
                               (repository-worktrees repository))))
    (cons (list 2
                (concatenate 'string
                             (%repository-tree-label repository)
                             (%workspace-node-refresh-tag :repository
                                                          (repository-id
                                                           repository)
                                                          refreshing-ids
                                                          stale-ids))
                repository
                :repository
                (when worktrees
                  (if expanded-p :expanded :collapsed)))
          (when expanded-p
            (loop for worktree in worktrees
                  append (cons
                          (list 3
                                (concatenate 'string
                                             (%worktree-tree-label worktree)
                                             (%workspace-node-refresh-tag
                                              :worktree
                                              (worktree-id worktree)
                                              refreshing-ids
                                              stale-ids))
                                worktree
                                :worktree
                                (%workspace-tree-row-fold
                                 worktree
                                 :worktree
                                 (%workspace-worktree-node-expanded-p
                                  worktree
                                  expanded-node-ids)))
                          (%workspace-worktree-detail-entries worktree
                                                              4
                                                              expanded-node-ids
                                                              :file-diffs
                                                              file-diffs)))))))

(defun %workspace-organization-row-entries (organization repository-tuples
                                            shown-worktrees
                                            expanded-node-ids
                                            filter-active-p
                                            refreshing-ids
                                            stale-ids
                                            collapsed-node-ids
                                            file-diffs)
  "One level-1 (LEVEL LABEL ORGANIZATION :ORGANIZATION FOLD) entry for
   ORGANIZATION, carrying \"label (N)\" for the N repositories in
   REPOSITORY-TUPLES (all of ORGANIZATION's own repositories: this group is
   never itself narrowed), followed -- unless the row is collapsed
   (%WORKSPACE-NODE-EXPANDED-P, or FILTER-ACTIVE-P bypasses that) -- by one
   %WORKSPACE-REPOSITORY-ROW-ENTRIES group per repository, at level 2."
  (let ((expanded-p (or filter-active-p
                       (%workspace-node-expanded-p :organization
                                                   (organization-id
                                                    organization)
                                                   collapsed-node-ids))))
    (cons (list 1
                (format nil "~A (~D)"
                        (%organization-tree-label organization)
                        (length repository-tuples))
                organization
                :organization
                (if expanded-p :expanded :collapsed))
          (when expanded-p
            (loop for (nil repository) in repository-tuples
                  append (%workspace-repository-row-entries
                          repository
                          shown-worktrees
                          expanded-node-ids
                          filter-active-p
                          refreshing-ids
                          stale-ids
                          file-diffs))))))

(defun %workspace-repositories-section-entries (repository-tuples
                                                shown-worktrees
                                                expanded-node-ids
                                                filter-active-p
                                                refreshing-ids
                                                stale-ids
                                                collapsed-node-ids
                                                &key
                                                file-diffs)
  "One %WORKSPACE-ORGANIZATION-ROW-ENTRIES group per organization named in
   REPOSITORY-TUPLES (a list of (ORGANIZATION REPOSITORY) tuples already in
   organization order and already grouped into contiguous per-organization
   runs by %WORKSPACE-CLASSIFY-WORKTREES' own nested walk), each holding
   that organization's repository rows (and, under an expanded repository,
   its worktree rows and their own inline-expansion children). Repository
   and worktree rows are never gated by section collapse on their own --
   only the wrapping %WORKSPACE-SECTION-ENTRIES call folds the whole
   Repositories section as one unit, and only an organization or repository
   row's own fold state gates what is nested under it."
  (loop with remaining = repository-tuples
        while remaining
        for organization = (first (first remaining))
        for boundary = (or (position organization remaining
                                     :key #'first :test-not #'eq)
                           (length remaining))
        for group = (subseq remaining 0 boundary)
        append (%workspace-organization-row-entries
                organization
                group
                shown-worktrees
                expanded-node-ids
                filter-active-p
                refreshing-ids
                stale-ids
                collapsed-node-ids
                file-diffs)
        do (setf remaining (nthcdr boundary remaining))))

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
  (let ((expanded-p
         (or filter-active-p
             (%workspace-node-expanded-p :section key collapsed-node-ids))))
    (when (plusp count)
      (cons (list 0
                  (format nil "~A (~D)" label count)
                  key
                  :section
                  (if expanded-p :expanded :collapsed))
            (when expanded-p row-entries)))))

(defun %workspace-job-segment-badge (segment)
  "The user-facing badge for one \"KIND:STATE[ SPINNER][ DETAIL]\" job
   segment: nothing for a finished job, \"...\" while it runs, and
   \"failed: DETAIL\" for a failure. Work the tool itself declined -- retired
   by a newer refresh, cancelled by the user, or excluded from a prune -- is
   not a failure to report on a row; the message strip already said so, and
   the row would otherwise call `prune SUCCEEDED' a failure."
  (let* ((colon (position #\: segment))
         (state-start (if colon (1+ colon) 0))
         (space (position #\Space segment :start state-start))
         (state (subseq segment state-start (or space (length segment))))
         (detail (string-trim " " (if space (subseq segment (1+ space)) ""))))
    (cond
      ((string-equal state "succeeded") nil)
      ((not (string-equal state "failed")) "...")
      ((member detail '("retired" "cancelled" "excluded") :test #'string-equal) nil)
      ((plusp (length detail))
       (format nil "failed: ~A" (%display-clip detail 24)))
      (t "failed"))))

(defun %workspace-job-row-badge (label)
  "The badge for one row's raw job LABEL -- the bracketed
   \" [KIND:STATE ...]\" segments %WORKSPACE-JOB-LABELS (server-multi.lisp)
   concatenates for every job touching that row -- or NIL when none of them
   has anything to say. Settled jobs used to sit on every resting row as a
   permanent \"[scan:succeeded]\" chip."
  (when label
    (let ((badges
           (loop with start = 0
                 for open = (position #\[ label :start start)
                 while open
                 for close = (or (position #\] label :start open) (length label))
                 for badge = (%workspace-job-segment-badge
                              (subseq label (1+ open) close))
                 do (setf start (min (length label) (1+ close)))
                 when badge
                   collect badge)))
      (when badges
        (format nil " ~{~A~^ ~}" (remove-duplicates badges :test #'string=))))))

(defun workspace-tree-objects (organizations collapsed-node-ids
                                             &key
                                             filter
                                             expanded-node-ids
                                             file-diffs)
  "The objects the tree currently shows, in display order."
  (mapcar #'third
          (workspace-flat-tree-entries organizations
                                        collapsed-node-ids
                                        :filter
                                        filter
                                        :expanded-node-ids
                                        expanded-node-ids
                                        :file-diffs
                                        file-diffs)))

(defun workspace-flat-tree-entries (organizations collapsed-node-ids
                                                   &key
                                                   job-labels
                                                   refreshing-ids
                                                   stale-ids
                                                   filter
                                                   expanded-node-ids
                                                   file-diffs)
  "Flatten ORGANIZATIONS into (LEVEL LABEL OBJECT KIND FOLD) display tuples,
   FOLD being :EXPANDED, :COLLAPSED or NIL for a row with nothing under it
   (%WORKSPACE-TREE-ROW-FOLD), in
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
   happens to be expanded\". %WORKSPACE-FILTER-TREE-ENTRIES decides what is
   actually visible, run once per section on that section's own raw entries
   -- not a second time on the merged three-section list, since a section's
   header/row nesting never crosses into another section and a repeat pass
   over already-filtered rows could only repeat the same verdict -- and each
   section header counts the rows that survive it, so \"Attention (2)\"
   never sits above one row."
  (let ((filter-active-p (and filter (plusp (length (string-trim " " filter))))))
    (multiple-value-bind (attention active repositories shown)
        (%workspace-classify-worktrees organizations)
      (flet ((section (key label rows count)
               (let ((rows (if filter-active-p
                               (%workspace-filter-tree-entries rows filter)
                               rows)))
                 (%workspace-section-entries
                  key
                  label
                  (if filter-active-p
                      (count (if (eq key :repositories) :repository :worktree)
                             rows :key #'fourth)
                      count)
                  rows
                  collapsed-node-ids
                  filter-active-p))))
        (let ((entries
               (append
                (section :attention
                         "Attention"
                         (%workspace-worktree-section-entries
                          attention
                          refreshing-ids
                          stale-ids
                          expanded-node-ids
                          :file-diffs
                          file-diffs)
                         (length attention))
                (section :active
                         "Active"
                         (%workspace-worktree-section-entries
                          active
                          refreshing-ids
                          stale-ids
                          expanded-node-ids
                          :file-diffs
                          file-diffs)
                         (length active))
                (section :repositories
                         "Repositories"
                         (%workspace-repositories-section-entries
                          repositories
                          shown
                          expanded-node-ids
                          filter-active-p
                          refreshing-ids
                          stale-ids
                          collapsed-node-ids
                          :file-diffs
                          file-diffs)
                         (length repositories)))))
          (when job-labels
            (dolist (entry entries)
              (let* ((object (third entry))
                     (kind (fourth entry))
                     (id (case kind
                           (:section object)
                           (:repository (repository-id object))
                           (:worktree (worktree-id object))))
                     (badge (and id
                                 (%workspace-job-row-badge
                                  (gethash (list kind id) job-labels)))))
                (when badge
                  (setf (second entry)
                        (concatenate 'string (second entry) badge))))))
          entries)))))
