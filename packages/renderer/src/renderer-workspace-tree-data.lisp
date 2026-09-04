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
   :COMMIT/:DIFF-LINE/:DIFF-MORE inline-expansion row, and a
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
   glyphs)."
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

   :FILE and :COMMIT rows (the inline worktree expansion) match
   independently through their own visible text -- path+code, hash+subject
   -- exactly like every other row kind here; a filter matching the parent
   worktree's OWN text does not, by itself, keep a non-matching child row.
   That is the same ancestor-only propagation %WORKSPACE-FILTER-TREE-
   ENTRIES already applies to every other level of this tree (a matching
   Attention-section worktree does not force its non-matching siblings to
   survive either).

   :DIFF-LINE and :DIFF-MORE rows match on LABEL instead of OBJECT:
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

