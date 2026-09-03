(in-package #:nerimux/renderer)

(defun %repository-attention-p (repository)
  "T when REPOSITORY itself, or any worktree under it, needs attention."
  (or (repository-dirty-p repository)
      (repository-conflict-p repository)
      (plusp (repository-ahead repository))
      (plusp (repository-behind repository))
      (repository-missing-p repository)
      (some #'worktree-attention-p (repository-worktrees repository))))

(defun %worktree-tree-windows (worktree)
  "Distinct windows holding at least one of WORKTREE's panes, ordered by
   window id -- the order the tree and status line show them in (R5.8)."
  (sort
   (remove-duplicates (mapcar #'pane-window (worktree-panes worktree))
                      :test
                      #'eq)
   #'<
   :key
   #'window-id))

(defun %workspace-tree-node-key (node)
  "Stable, EQUAL-comparable identity for a tree row. Covers a struct-backed
   organization/repository/worktree/window/pane row, a cons-keyed :FILE/
   :COMMIT/:DIFF-LINE/:DIFF-MORE inline-expansion row (Wave B/C), and a
   :SECTION row keyed by its own keyword (:ATTENTION/:ACTIVE/:REPOSITORIES)
   via the fallback branch below. Used both for tree-widget selection and,
   at the section and repository levels, as the collapse/expand-state
   table's key."
  (typecase node
    (organization (list :organization (organization-id node)))
    (repository (list :repository (repository-id node)))
    (worktree (list :worktree (worktree-id node)))
    (window (list :window (window-id node)))
    (pane (list :pane (window-id (pane-window node)) (pane-id node)))
    (cons node)
    (t (list :workspace-object node))))

(defun %workspace-node-expanded-p (kind id collapsed-node-ids)
  "T unless the (KIND ID) organization/repository row is marked collapsed in
   COLLAPSED-NODE-IDS (a hash-table of tree-node keys -> T, or NIL). Absent
   means expanded -- the tree's default state since the one-column overview
   redesign (PR2), which replaced R6.3's collapse-by-default with full
   expansion so a newly attached client sees the whole hierarchy at once.
   Worktree/window/pane rows have no collapse state of their own; once both
   ancestors are not collapsed, everything under a worktree shows."
  (not (and collapsed-node-ids (gethash (list kind id) collapsed-node-ids))))

(defun %organization-tree-label (organization)
  (let ((host (organization-host organization))
        (name (organization-name organization)))
    (cond
      ((and (plusp (length host)) (plusp (length name)))
       (format nil "~A/~A" host name))
      ((plusp (length host)) host)
      ((plusp (length name)) name)
      (t (organization-id organization)))))

(defun %strip-dot-git-suffix (name)
  "NAME with a trailing \".git\" removed (case-insensitively), unless NAME
   is nothing but \".git\" itself -- in which case stripping it would leave
   an empty label, so NAME is returned unchanged."
  (if (and (> (length name) 4)
           (string-equal name ".git" :start1 (- (length name) 4)))
      (subseq name 0 (- (length name) 4))
      name))

(defun %repository-tree-label (repository)
  "Repository row label: the repository NAME only (SPECIFICATION's segment
   after its last `/', with a trailing `.git' stripped, or the whole string
   when there is no `/') -- the organization row above it already shows the
   org/host part, so repeating it on every repository row wasted width and
   read as noise once the tree became the overview's only panel (PR2), and
   `.git' is a hosting-convention artifact no one reads the name by. Falls
   back to LOCAL-PATH or ID exactly as before when SPECIFICATION is empty."
  (let ((specification (repository-specification repository)))
    (if (plusp (length specification))
        (let ((slash (position #\/ specification :from-end t)))
          (%strip-dot-git-suffix
           (if slash
               (subseq specification (1+ slash))
               specification)))
        (or
         (and (plusp (length (repository-local-path repository)))
              (repository-local-path repository))
         (repository-id repository)))))

(defun %worktree-tree-label (worktree)
  "WORKTREE's tree-row label: BRANCH when set; otherwise \"(bare)\" for a
   bare worktree (WORKTREE-BARE-P) rather than its full PATH, which read as
   noise on a bare root row in real-terminal smoke testing -- a bare
   worktree's path is rarely meaningful to look at and every row already
   crowds a full path into a single line; otherwise PATH, then ID, exactly
   as before."
  (let ((branch (worktree-branch worktree))
        (path (worktree-path worktree)))
    (cond
      ((and branch (plusp (length branch))) branch)
      ((worktree-bare-p worktree) "(bare)")
      ((plusp (length path)) path)
      (t (worktree-id worktree)))))

(defun %window-tree-label (window)
  "WINDOW's tree-row label: id + name. NAME is already branch + sequence
   number (R5.8, computed once at window-creation time in
   workspace-window.lisp) -- this only formats it, it does not recompute it."
  (format nil "win ~D:~A" (window-id window) (window-name window)))

(defun %pane-tree-label (pane)
  (format nil
          "pane/~D ~A"
          (pane-id pane)
          (or (and (plusp (length (pane-title pane))) (pane-title pane))
              (and (plusp (length (pane-start-command pane)))
                   (pane-start-command pane))
              "shell")))

(defun %workspace-tree-node-attention-p (object kind)
  "T when OBJECT (a KIND tree node) should carry the `!` attention mark."
  (case kind
    (:organization (or (plusp (organization-attention-count object))
                        (organization-attention-worktrees object)))
    (:repository (%repository-attention-p object))
    (:worktree (worktree-attention-p object))
    (:pane (pane-attention-p object))
    (:section nil)
    (t nil)))

(defun %workspace-node-refresh-tag (kind id refreshing-ids stale-ids)
  "Return the refresh-state suffix for an organization, repository, or worktree."
  (let ((key (list kind id)))
    (cond
      ((and refreshing-ids (gethash key refreshing-ids)) " refreshing")
      ((and stale-ids (gethash key stale-ids)) " stale")
      (t ""))))

(defun %worktree-relative-time-text (universal-time)
  "ASCII relative-time label for UNIVERSAL-TIME (a GET-UNIVERSAL-TIME
   integer, or NIL for \"never\"): \"now\" under a minute, then Nm/Nh/Nd.
   Plain ASCII, never an arrow glyph -- the UI theme convention bans
   ambiguous-width characters, which is exactly the class the obvious
   compact alternatives (arrows, clock glyphs) fall into."
  (when universal-time
    (let ((delta (max 0 (- (get-universal-time) universal-time))))
      (cond
        ((< delta 60) "now")
        ((< delta 3600) (format nil "~Dm" (floor delta 60)))
        ((< delta 86400) (format nil "~Dh" (floor delta 3600)))
        (t (format nil "~Dd" (floor delta 86400)))))))

(defun %worktree-last-activity-time (worktree)
  "The most recent of every pane's LAST-OUTPUT-TIME/LAST-FOCUSED-TIME under
   WORKTREE (both GET-UNIVERSAL-TIME integers or NIL, set by
   PANE-MARK-OUTPUT/PANE-MARK-FOCUSED in pane-core.lisp), or NIL when none
   of them has ever fired."
  (let (latest)
    (dolist (pane (worktree-panes worktree) latest)
      (dolist 
          (time
           (list (pane-last-output-time pane) (pane-last-focused-time pane)))
        (when (and time (or (null latest) (> time latest)))
          (setf latest time))))))

(defun %worktree-ahead-behind-parts (worktree)
  "List of (TEXT . SGR) pairs for WORKTREE's nonzero ahead/behind counts,
   ahead first -- \"+N\"/\"-N\" (ASCII, never the ambiguous-width arrow
   glyphs the pre-redesign status line used)."
  (append
   (when (plusp (worktree-ahead worktree))
     (list (cons (format nil "+~D" (worktree-ahead worktree)) +sgr-ahead+)))
   (when (plusp (worktree-behind worktree))
     (list (cons (format nil "-~D" (worktree-behind worktree)) +sgr-behind+)))))

(defun %worktree-pane-count-text (worktree)
  "\"Np\" for WORKTREE's pane count, or \"Np!\" when any pane has exited; NIL
   when WORKTREE has no panes at all (nothing to show)."
  (let ((panes (worktree-panes worktree)))
    (and panes
         (format nil
                 "~Dp~:[~;!~]"
                 (length panes)
                 (some #'pane-process-exited-p panes)))))

(defun %worktree-state-tag (worktree)
  "The single most salient %WORKTREE-STATUS-TOKENS entry for the info
   cluster, excluding AHEAD/BEHIND (those get their own cluster field so
   would otherwise show twice). Falls back to \"CLEAN\" when every token
   present is an AHEAD/BEHIND count, matching %WORKTREE-STATUS-TOKENS'S own
   CLEAN-when-nothing-else-applies default."
  (or
   (find-if
    (lambda (token)
      (not
       (or (and (>= (length token) 5) (string= (subseq token 0 5) "AHEAD"))
           (and (>= (length token) 6) (string= (subseq token 0 6) "BEHIND")))))
    (%worktree-status-tokens worktree))
   "CLEAN"))

(defun %worktree-tree-info-tokens (worktree)
  "Ordered (PLAIN . STYLED) token pairs for WORKTREE's tree-row info
   cluster, lowest priority first -- the order %WORKTREE-TREE-INFO-SUFFIX
   drops from when the row does not fit: relative time, then ahead/behind,
   then pane count; the state tag is never dropped."
  (let* ((time
          (%worktree-relative-time-text (%worktree-last-activity-time worktree)))
         (ahead-behind (%worktree-ahead-behind-parts worktree))
         (pane-count (%worktree-pane-count-text worktree))
         (state (%worktree-state-tag worktree))
         (state-sgr (%worktree-state-token-sgr state)))
    (remove nil
            (list (and time (cons time (%sgr-wrap time +sgr-faint+)))
                  (and ahead-behind
                       (cons
                        (format nil "~{~A~^/~}" (mapcar #'car ahead-behind))
                        (format nil
                                "~{~A~^/~}"
                                (mapcar
                                 (lambda (part)
                                   (%sgr-wrap (car part) (cdr part)))
                                 ahead-behind))))
                  (and pane-count
                       (cons pane-count
                             (%sgr-wrap pane-count
                                        (if (find #\! pane-count)
                                            +sgr-alert+
                                            +sgr-faint+))))
                  (cons state
                        (if state-sgr
                            (%sgr-wrap state state-sgr)
                            state))))))

(defun %worktree-tree-info-suffix (worktree width)
  "Two values -- PLAIN and STYLED text for WORKTREE's tree-row info cluster
   (state tag, ahead/behind, pane count, relative last-activity time),
   space-joined. Tokens drop from the front (lowest priority: relative time,
   then ahead/behind, then pane count; the state tag never drops) until the
   plain form fits WIDTH display columns. %DISPLAY-CLIP's own
   truncate-with-ellipsis contract is the safety net for the case where even
   the state tag alone overflows WIDTH."
  (let ((tokens (%worktree-tree-info-tokens worktree)))
    (loop for remaining on tokens
          for plain = (format nil "~{~A~^ ~}" (mapcar #'car remaining))
          for styled = (format nil "~{~A~^ ~}" (mapcar #'cdr remaining))
          when (or (null (cdr remaining)) (<= (%display-width plain) width))
            return (values (%display-clip plain width) styled))))

(defun %workspace-tree-node-search-text (kind object &optional label)
  "Lowercased text FILTER is matched against for one tree row: label for an
   organization, specification+name for a repository, branch+path for a
   worktree, title+start-command for a pane. Window rows have no fields of
   their own to search, so they fall back to their own label.

   :FILE and :COMMIT rows (the inline worktree expansion, Wave B) match
   independently through their own visible text -- path+code, hash+subject
   -- exactly like every other row kind here; a filter matching the parent
   worktree's OWN text does not, by itself, keep a non-matching child row.
   That is the same ancestor-only propagation %WORKSPACE-FILTER-TREE-
   ENTRIES already applies to every other level of this tree (a matching
   Attention-section worktree does not force its non-matching siblings to
   survive either), so this is the existing rule extended rather than a new
   one invented for this wave.

   :DIFF-LINE and :DIFF-MORE rows (Wave C) match on LABEL instead of OBJECT:
   their OBJECT deliberately carries only WORKTREE-ID/PATH/INDEX, not the
   line text itself (keeping it out of the node key, which only needs to be
   stable, not searchable), so the caller passes the row's own LABEL --
   which for these two kinds already IS the raw diff-line text -- through
   from %WORKSPACE-FILTER-TREE-ENTRIES."
  (string-downcase
   (case kind
     (:organization (%organization-tree-label object))
     (:repository
      (format nil
              "~A ~A"
              (repository-specification object)
              (%repository-tree-label object)))
     (:worktree
      (format nil
              "~A ~A"
              (or (worktree-branch object) "")
              (worktree-path object)))
     (:window (%window-tree-label object))
     (:pane
      (format nil "~A ~A" (pane-title object) (pane-start-command object)))
     (:file (format nil "~A ~A" (third object) (fourth object)))
     (:commit
      (format nil
              "~A ~A"
              (if (stringp (third object))
                  (third object)
                  "")
              (or (fourth object) "")))
     ((:diff-line :diff-more) (or label ""))
     (t ""))))

(defun %workspace-tree-node-matches-filter-p (kind object
                                                   downcased-filter
                                                   &optional
                                                   label)
  "T when OBJECT's search text contains DOWNCASED-FILTER. DOWNCASED-FILTER
   is expected already lower-cased by the caller
   (%WORKSPACE-FILTER-TREE-ENTRIES downcases FILTER once per call rather
   than re-downcasing it on every node, which is what this function used to
   do). LABEL is forwarded to %WORKSPACE-TREE-NODE-SEARCH-TEXT for the
   :DIFF-LINE/:DIFF-MORE kinds it needs it for; every other kind ignores it."
  (and downcased-filter
       (plusp (length downcased-filter))
       (search downcased-filter
               (%workspace-tree-node-search-text kind object label))
       t))

(defun %workspace-filter-tree-entries (entries filter)
  "Keep only ENTRIES (LEVEL LABEL OBJECT KIND, in pre-order) whose own node
   or some descendant matches FILTER (case-insensitive substring). A single
   left-to-right pass suffices: ANCESTORS tracks the path from the root to
   the current row (popped back to the current LEVEL on entry, since a row
   at or below the current level can no longer be an ancestor), and a match
   marks both itself and everything still on that stack -- which is exactly
   every strict ancestor, so no separate ancestor-collection step is
   needed. NIL or an all-blank FILTER returns ENTRIES unchanged."
  (if (or (null filter) (zerop (length (string-trim " " filter))))
      entries
      (let* ((downcased-filter (string-downcase filter))
             (vector (coerce entries 'vector))
             (count (length vector))
             (keep (make-array count :initial-element nil))
             (ancestors nil))
        (dotimes (index count)
          (let* ((entry (aref vector index))
                 (level (first entry)))
            (loop while (and ancestors
                             (>= (first (aref vector (car ancestors))) level))
                  do (pop ancestors))
            (when 
                (%workspace-tree-node-matches-filter-p (fourth entry)
                                                       (third entry)
                                                       downcased-filter
                                                       (second entry))
              (setf (aref keep index) t)
              (dolist (ancestor-index ancestors)
                (setf (aref keep ancestor-index) t)))
            (push index ancestors)))
        (loop for index below
              count
              when (aref keep index)
                collect (aref vector index)))))

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
  "LEVEL entries for one expanded :FILE row's own inline diff (Wave C),
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
  "The inline-diff child rows for one :FILE row (Wave C), when that file's
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
  "One LEVEL entry per WORKTREE-CHANGED-FILES entry (D1's plain (CODE . PATH)
   conses), labelled \"XY path\" the way `git status --short` shows it,
   followed by that file's own inline-diff child rows (Wave C, LEVEL+1)."
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
   (%WORKSPACE-WORKTREE-NODE-EXPANDED-P). FILE-DIFFS (Wave C) is forwarded
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
   followed by that worktree's own inline-expansion child rows (Wave B,
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
   expansion child rows (Wave B, level 3) when that worktree is expanded.
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

(defun workspace-tree-view-rows (terminal-rows)
  "Rows available for the tree in the one-column overview layout:
   TERMINAL-ROWS minus header(1) + separator(1) + detail(2) + message(1) +
   the bottom key panel -- 3 rows (a divider and 2 content lines) at
   TERMINAL-ROWS >= 12, or the single-line footer it collapses to below that
   height (see RENDER-WORKSPACE-OVERVIEW-TO-STRING) -- floored at 1. Shared
   with the bootstrap scroll-clamping math for the same reason
   %WORKSPACE-LEFT-WIDTH used to be shared: two layers computing this
   independently can silently disagree about where the tree ends."
  (max 1
       (- terminal-rows
          (if (< terminal-rows 12)
              6
              8))))
