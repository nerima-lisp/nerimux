(in-package #:nerimux/renderer)

;;;; magit-style per-worktree status view (FR-003, magit alignment contract
;;;; §3 Unit STATUS-VIEW).
;;;;
;;;; This is the third full-screen view alongside the repolist tree
;;;; (renderer-workspace-tree.lisp / renderer-tui-kit.lisp) and the `?` help
;;;; view (renderer-tui-kit-help.lisp): one worktree's HEAD, its four
;;;; partitioned change lists (Unit MODEL), stashes, recent commits, its
;;;; panes, and its sibling worktrees, flattened into the same (LEVEL LABEL
;;;; OBJECT KIND) tuple shape %WORKSPACE-FLAT-TREE-ENTRIES already uses for
;;;; the repolist tree -- so every row-kind helper the tree already built
;;;; (file/commit/pane child rows, Wave C's inline diff expansion) is called
;;;; here rather than re-implemented.
;;;;
;;;; Unlike the repolist tree, this view does not go through cl-tui-kit's
;;;; list-widget: a status row routinely mixes more than one colour (a
;;;; file's status code plus its path, a commit's hash plus its subject),
;;;; and the list-widget can only carry one uniform style per row
;;;; (constraint §4.4). It draws directly onto a CL-TUI-KIT/CORE surface via
;;;; SURFACE-DRAW-STYLED-TEXT spans instead -- the same pattern
;;;; RENDER-HELP-VIEW-TO-TUI-STRING (renderer-tui-kit-help.lisp) already
;;;; uses for exactly this reason -- so it never touches %EMIT-STYLED-ROW or
;;;; %DISPLAY-CLIP, both of which count SGR escape bytes as display width
;;;; (constraint §4.1) and would corrupt a two-colour row.
;;;;
;;;; FR-005's visibility level (1-4) is a LENS over the per-row expand
;;;; table, not a replacement for it: %WORKSPACE-STATUS-ROW-EXPANDED-P below
;;;; only consults the level when the caller never explicitly toggled that
;;;; row, so changing level can never destroy an explicit per-row TAB
;;;; toggle, and returning to an earlier level reproduces the exact same
;;;; rows (see that function's docstring).

;;; ── Styles (CL-TUI-KIT spans) ────────────────────────────────────────────
;;;
;;; The RGB triples below mirror renderer-style.lisp's documented Dracula
;;; palette exactly (bg 40,42,54 / current-line 68,71,90 / comment 98,114,164
;;; / cyan 139,233,253 / green 80,250,123 / orange 255,184,108 / purple
;;; 189,147,249 / red 255,85,85 / yellow 241,250,140), following
;;; %MAKE-WORKSPACE-TREE-THEME's (renderer-tui-kit-widgets.lisp) and
;;; RENDER-HELP-VIEW-TO-TUI-STRING's (renderer-tui-kit-help.lisp) own
;;; precedent of hardcoding the same values as CL-TUI-KIT style objects
;;; locally -- renderer-style.lisp only defines SGR-string constants for the
;;; plain-ANSI path, not CL-TUI-KIT style objects, and this agent does not
;;; own that file.

(defun %workspace-status-style-plain ()
  (cl-tui-kit/core:make-style))

(defun %workspace-status-style-heading ()
  (cl-tui-kit/core:make-style
   :bold t :foreground (cl-tui-kit/core:rgb-color 189 147 249)))

(defun %workspace-status-style-muted ()
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 98 114 164)))

(defun %workspace-status-style-faint ()
  ;; No separate "dim" attribute in CL-TUI-KIT/CORE:STYLE -- the same muted
  ;; foreground the plain-ANSI path's +SGR-FAINT+ falls back to visually.
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 98 114 164)))

(defun %workspace-status-style-ok ()
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 80 250 123)))

(defun %workspace-status-style-warn ()
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 241 250 140)))

(defun %workspace-status-style-alert ()
  (cl-tui-kit/core:make-style
   :bold t :foreground (cl-tui-kit/core:rgb-color 255 85 85)))

(defun %workspace-status-style-accent ()
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %workspace-status-style-accent-bold ()
  (cl-tui-kit/core:make-style
   :bold t :foreground (cl-tui-kit/core:rgb-color 139 233 253)))

(defun %workspace-status-style-orange ()
  (cl-tui-kit/core:make-style
   :foreground (cl-tui-kit/core:rgb-color 255 184 108)))

(defun %workspace-status-style-header-chip ()
  (cl-tui-kit/core:make-style
   :bold t
   :foreground (cl-tui-kit/core:rgb-color 40 42 54)
   :background (cl-tui-kit/core:rgb-color 189 147 249)))

;;; ── Per-row expansion: level as a lens over an explicit override table ──

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

;;; ── HEAD row ──────────────────────────────────────────────────────────────

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
    (remove
     nil
     (list
      (cons "Head:     " nil)
      (cons (or branch "(detached)") (%workspace-status-style-accent-bold))
      (and head (plusp (length head))
           (cons (format nil " (~A)" head) (%workspace-status-style-faint)))
      (and (plusp ahead)
           (cons (format nil " +~D" ahead) (%workspace-status-style-ok)))
      (and (plusp behind)
           (cons (format nil " -~D" behind) (%workspace-status-style-orange)))))))

(defun %workspace-status-head-label (worktree)
  (format nil "~{~A~}" (mapcar #'car (%workspace-status-head-parts worktree))))

(defun %workspace-status-head-spans (worktree)
  (mapcar (lambda (part)
            (if (cdr part)
                (cl-tui-kit/core:make-text-span (car part) :style (cdr part))
                (cl-tui-kit/core:make-text-span (car part))))
          (%workspace-status-head-parts worktree)))

(defun %workspace-status-head-entries (worktree)
  "The Head section: one KIND :HEAD row, omitted only when WORKTREE has
   neither a branch nor a resolved HEAD at all (an uninitialised worktree) --
   the same \"omitted when empty\" rule every other section in this view
   follows, applied to a section that never has a count of its own."
  (when (or (and (worktree-branch worktree) (plusp (length (worktree-branch worktree))))
            (and (worktree-head worktree) (plusp (length (worktree-head worktree)))))
    (list (list 0 (%workspace-status-head-label worktree) worktree :head))))

;;; ── File rows (Unmerged/Untracked/Unstaged/Staged) ──────────────────────

(defun %workspace-status-file-diff-child-entries
    (worktree-id path code level expanded-node-ids file-diffs diff-default-p)
  "The inline-diff child rows for one status-view :FILE row (Wave C), gated
   by the status view's own level-aware %WORKSPACE-STATUS-ROW-EXPANDED-P
   rather than %WORKSPACE-WORKTREE-FILE-DIFF-ENTRIES's plain presence check
   (renderer-workspace-tree.lisp) -- that function's gate has no notion of
   VISIBILITY-LEVEL, and it is not this agent's file to add one to. The
   untracked-file placeholder and the cache-entry lookup are the same shape
   that function uses; the actual line formatting is still
   %WORKSPACE-FILE-DIFF-LINE-ENTRIES (Wave C), which is reused unchanged."
  (when (%workspace-status-row-expanded-p
         (list :file-diff worktree-id path) expanded-node-ids diff-default-p)
    (if (string= code "??")
        (list (list level "(untracked file)"
                    (list :diff-line worktree-id path :untracked) :diff-line))
        (%workspace-file-diff-line-entries
         worktree-id path level
         (and file-diffs (gethash (list worktree-id path) file-diffs))))))

(defun %workspace-status-file-entries
    (files worktree-id level expanded-node-ids file-diffs diff-default-p)
  "One LEVEL entry per (CODE . PATH) cons in FILES -- one of WORKTREE's four
   partitioned change lists (Unit MODEL: staged/unstaged/untracked/unmerged-
   files) -- each followed by its own inline-diff child rows."
  (loop for (code . path) in files
        append (cons (list level (format nil "~A ~A" code path)
                           (list :file worktree-id path code) :file)
                     (%workspace-status-file-diff-child-entries
                      worktree-id path code (1+ level)
                      expanded-node-ids file-diffs diff-default-p))))

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

;;; ── Stash rows ────────────────────────────────────────────────────────────

(defun %workspace-status-stash-entries (worktree level)
  "LEVEL entries for WORKTREE's stash group -- mirrors %WORKSPACE-WORKTREE-
   COMMIT-CHILD-ENTRIES's :PENDING/:FAILED placeholder convention exactly
   (renderer-workspace-tree.lisp). Stash messages are already control-
   character-stripped at the source (LIST-WORKTREE-STASHES,
   vcs-git-write.lisp, via %SANITIZE-RETAINED-TEXT) -- not re-stripped here,
   which would just be the same trust boundary re-applied a second time."
  (case (worktree-stashes-state worktree)
    (:pending
     (list (list level "stashes: refreshing..."
                 (list :stash (worktree-id worktree) :pending nil) :stash)))
    (:failed
     (list (list level "stashes: UNKNOWN"
                 (list :stash (worktree-id worktree) :failed nil) :stash)))
    (:ready
     (loop for (reference . message) in (worktree-stashes worktree)
           collect (list level (format nil "~A ~A" reference message)
                         (list :stash (worktree-id worktree) reference message)
                         :stash)))
    (t nil)))

;;; ── Sibling worktree rows ─────────────────────────────────────────────────

(defun %workspace-status-sibling-worktree-entries (worktree level)
  "One LEVEL entry per sibling of WORKTREE under its own repository -- every
   REPOSITORY-WORKTREES entry except WORKTREE itself, sorted by path for a
   stable, deterministic row order the way %WORKSPACE-WORKTREE-PANE-CHILD-
   ENTRIES sorts by PANE-ID for the same reason (renderer-workspace-
   tree.lisp): REPOSITORY-WORKTREES is push order (REPOSITORY-ADD-WORKTREE),
   which would otherwise read newest-first."
  (let ((repository (worktree-repository worktree)))
    (loop for sibling in (sort (copy-list (and repository (repository-worktrees repository)))
                               #'string< :key #'worktree-path)
          unless (eq sibling worktree)
            collect (list level (%worktree-tree-label sibling) sibling :worktree))))

;;; ── Flattening ───────────────────────────────────────────────────────────

(defun %workspace-status-section-entries
    (key heading count child-entries expanded-node-ids section-default-p)
  "One level-0 (0 LABEL KEY :SECTION) header entry carrying a live
   \"HEADING (COUNT)\", plus CHILD-ENTRIES beneath it when the section is
   expanded -- NIL (the section omitted entirely) when COUNT is zero. Same
   contract as %WORKSPACE-SECTION-ENTRIES (renderer-workspace-tree.lisp) for
   the repolist tree, keyed instead by this view's own per-section
   expansion entry -- see %WORKSPACE-STATUS-ROW-EXPANDED-P."
  (when (plusp count)
    (cons (list 0 (format nil "~A (~D)" heading count) key :section)
          (when (%workspace-status-row-expanded-p
                 (list :status-section key) expanded-node-ids section-default-p)
            child-entries))))

(defun workspace-status-entries
    (worktree &key expanded-node-ids file-diffs (visibility-level 2))
  "The magit-style status buffer's rows for WORKTREE, flattened into (LEVEL
   LABEL OBJECT KIND) tuples in this fixed section order, each section
   omitted entirely when it has nothing to show: Head, Unmerged, Untracked,
   Unstaged, Staged, Stashes, Recent commits, Panes, Worktrees (contract §3)."
  (let* ((level (or visibility-level 2))
         (section-default-p (%workspace-status-section-default-expanded-p level))
         (diff-default-p (%workspace-status-file-diff-default-expanded-p level))
         (worktree-id (worktree-id worktree))
         (unmerged-children
           (%workspace-status-file-entries
            (worktree-unmerged-files worktree) worktree-id 1
            expanded-node-ids file-diffs diff-default-p))
         (untracked-children
           (%workspace-status-file-entries
            (worktree-untracked-files worktree) worktree-id 1
            expanded-node-ids file-diffs diff-default-p))
         (unstaged-children
           (%workspace-status-file-entries
            (worktree-unstaged-files worktree) worktree-id 1
            expanded-node-ids file-diffs diff-default-p))
         (staged-children
           (%workspace-status-file-entries
            (worktree-staged-files worktree) worktree-id 1
            expanded-node-ids file-diffs diff-default-p))
         (stash-children (%workspace-status-stash-entries worktree 1))
         (commit-children (%workspace-worktree-commit-child-entries worktree 1))
         (pane-children (%workspace-worktree-pane-child-entries worktree 1))
         (worktree-children (%workspace-status-sibling-worktree-entries worktree 1)))
    (append
     (%workspace-status-head-entries worktree)
     (%workspace-status-section-entries
      :unmerged "Unmerged changes" (length (worktree-unmerged-files worktree))
      unmerged-children expanded-node-ids section-default-p)
     (%workspace-status-section-entries
      :untracked "Untracked files" (length (worktree-untracked-files worktree))
      untracked-children expanded-node-ids section-default-p)
     (%workspace-status-section-entries
      :unstaged "Unstaged changes" (length (worktree-unstaged-files worktree))
      unstaged-children expanded-node-ids section-default-p)
     (%workspace-status-section-entries
      :staged "Staged changes" (length (worktree-staged-files worktree))
      staged-children expanded-node-ids section-default-p)
     (%workspace-status-section-entries
      :stashes "Stashes" (length stash-children)
      stash-children expanded-node-ids section-default-p)
     (%workspace-status-section-entries
      :commits "Recent commits" (length commit-children)
      commit-children expanded-node-ids section-default-p)
     (%workspace-status-section-entries
      :panes "Panes" (length pane-children)
      pane-children expanded-node-ids section-default-p)
     (%workspace-status-section-entries
      :worktrees "Worktrees" (length worktree-children)
      worktree-children expanded-node-ids section-default-p))))

(defun workspace-status-objects
    (worktree &key expanded-node-ids file-diffs visibility-level)
  "The objects WORKSPACE-STATUS-ENTRIES shows, in display order. Key
   dispatch selects by index into this list, so it must be exactly the same
   list RENDER-WORKSPACE-STATUS-TO-TUI-STRING draws from -- the same
   contract WORKSPACE-TREE-OBJECTS holds for the repolist tree
   (package-presentation.lisp)."
  (mapcar #'third
          (workspace-status-entries
           worktree :expanded-node-ids expanded-node-ids
                    :file-diffs file-diffs :visibility-level visibility-level)))

(defun workspace-status-view-rows (terminal-rows)
  "Rows available for the status view's scrollable row list: TERMINAL-ROWS
   minus header(1) + separator(1) + footer(1) -- plus, at TERMINAL-ROWS >=
   12, the message line(1) and the 2-line key panel with its own
   divider(+3), the same TERMINAL-ROWS = 12 threshold and same reasoning
   WORKSPACE-TREE-VIEW-ROWS uses for the repolist tree's own key panel
   (renderer-workspace-tree.lisp) -- below that height the panel collapses
   to a single footer line and the message line is dropped rather than
   stealing a row from an already-tight frame. Floored at 1."
  (max 1 (- (max 1 terminal-rows) (if (< terminal-rows 12) 3 6))))

;;; ── Row rendering (spans) ────────────────────────────────────────────────

(defun %workspace-status-row-selected-p (object selected-object)
  ;; A :FILE/:COMMIT/:STASH/:DIFF-LINE row's OBJECT is a fresh cons every
  ;; WORKSPACE-STATUS-ENTRIES call, so EQ never matches it against a
  ;; SELECTED-OBJECT captured on an earlier frame -- fall back to EQUAL for
  ;; that case only, exactly as the repolist tree's own TREE-ROW-TEXT does
  ;; (renderer-workspace.lisp).
  (or (eq object selected-object)
      (and (consp object) (consp selected-object) (equal object selected-object))))

(defun %workspace-status-row-prefix-spans (level selected-p attention-p)
  (list
   (cl-tui-kit/core:make-text-span
    (make-string (* 2 level) :initial-element #\Space))
   (cl-tui-kit/core:make-text-span
    (if selected-p ">" " ")
    :style (if selected-p (%workspace-status-style-accent-bold) (%workspace-status-style-plain)))
   (cl-tui-kit/core:make-text-span
    (if attention-p "!" " ")
    :style (if attention-p (%workspace-status-style-alert) (%workspace-status-style-plain)))
   (cl-tui-kit/core:make-text-span " ")))

(defun %workspace-status-diff-line-style (object label)
  ;; Mirrors DETAIL-ROW-STYLED-LABEL's :DIFF-LINE case (renderer-
  ;; workspace.lisp) exactly, just returning a CL-TUI-KIT style object
  ;; instead of an SGR-wrapped string.
  (cond
    ((eq (first object) :diff-more) (%workspace-status-style-muted))
    (t (case (fourth object)
         (:pending (%workspace-status-style-muted))
         (:failed (%workspace-status-style-faint))
         (:untracked (%workspace-status-style-muted))
         (t (cond
              ((and (plusp (length label)) (char= (char label 0) #\+))
               (%workspace-status-style-ok))
              ((and (plusp (length label)) (char= (char label 0) #\-))
               (%workspace-status-style-alert))
              ((and (>= (length label) 2) (string= label "@@" :end1 2))
               (%workspace-status-style-accent))
              (t (%workspace-status-style-muted))))))))

(defun %workspace-status-row-content-spans (label object kind)
  "Content spans for one row, dispatched on KIND. :FILE/:COMMIT/:STASH read
   their colour from OBJECT's own fields (mirroring DETAIL-ROW-STYLED-LABEL,
   renderer-workspace.lisp) rather than re-parsing LABEL; every other kind
   draws LABEL as a single span, optionally styled."
  (case kind
    (:section (list (cl-tui-kit/core:make-text-span
                     label :style (%workspace-status-style-heading))))
    (:head (%workspace-status-head-spans object))
    (:file
     (let ((code (fourth object)) (path (third object)))
       (list (cl-tui-kit/core:make-text-span
              code :style (%workspace-status-file-code-style code))
             (cl-tui-kit/core:make-text-span (format nil " ~A" path)))))
    (:commit
     (let ((hash (third object)) (subject (fourth object)))
       (if (stringp hash)
           (list (cl-tui-kit/core:make-text-span
                  hash :style (%workspace-status-style-accent))
                 (cl-tui-kit/core:make-text-span
                  (format nil " ~A" subject) :style (%workspace-status-style-faint)))
           (list (cl-tui-kit/core:make-text-span
                  label :style (%workspace-status-style-faint))))))
    (:stash
     (let ((reference (third object)) (message (fourth object)))
       (if (stringp reference)
           (list (cl-tui-kit/core:make-text-span
                  reference :style (%workspace-status-style-accent))
                 (cl-tui-kit/core:make-text-span
                  (format nil " ~A" (or message "")) :style (%workspace-status-style-faint)))
           (list (cl-tui-kit/core:make-text-span
                  label :style (%workspace-status-style-faint))))))
    (:pane
     (if (pane-process-exited-p object)
         (list (cl-tui-kit/core:make-text-span
                label :style (%workspace-status-style-alert)))
         (list (cl-tui-kit/core:make-text-span label))))
    (:diff-line
     (list (cl-tui-kit/core:make-text-span
            label :style (%workspace-status-diff-line-style object label))))
    (t (list (cl-tui-kit/core:make-text-span label)))))

(defun %workspace-status-row-spans (entry selected-object)
  (destructuring-bind (level label object kind) entry
    (let ((selected-p (%workspace-status-row-selected-p object selected-object))
          (attention-p (%workspace-tree-node-attention-p object kind)))
      (append
       (%workspace-status-row-prefix-spans level selected-p attention-p)
       (%workspace-status-row-content-spans label object kind)))))

;;; ── Header ───────────────────────────────────────────────────────────────

(defun %workspace-status-header-spans (worktree)
  (let* ((repository (worktree-repository worktree))
         (organization (and repository (repository-organization repository)))
         (repository-label
           (cond
             ((and repository organization)
              (format nil "~A/~A"
                      (%organization-tree-label organization)
                      (%repository-tree-label repository)))
             (repository (%repository-tree-label repository))
             (t nil))))
    (list
     (cl-tui-kit/core:make-text-span
      " nerimux " :style (%workspace-status-style-header-chip))
     (cl-tui-kit/core:make-text-span
      "  STATUS  " :style (%workspace-status-style-heading))
     (cl-tui-kit/core:make-text-span
      (if repository-label
          (format nil " ~A · ~A" repository-label (%worktree-tree-label worktree))
          (format nil " ~A" (%worktree-tree-label worktree)))))))

;;; ── Bottom key panel ─────────────────────────────────────────────────────

(defun %workspace-status-hint-spans (pairs)
  "One flat spans list for PAIRS (KEY . DESCRIPTION) -- the span equivalent
   of %WORKSPACE-HINT's plain-ANSI string building (renderer-workspace.lisp),
   needed here because this view draws directly onto a surface instead of
   concatenating SGR strings."
  (loop for (key . description) in pairs
        for firstp = t then nil
        append (list (cl-tui-kit/core:make-text-span
                      (if firstp key (format nil "  ~A" key))
                      :style (%workspace-status-style-accent-bold))
                     (cl-tui-kit/core:make-text-span
                      (format nil " ~A" description)
                      :style (%workspace-status-style-muted)))))

(defun %workspace-status-selected-entry (entries selected-object)
  (find-if (lambda (entry)
             (%workspace-status-row-selected-p (third entry) selected-object))
           entries))

(defun %workspace-status-key-panel-spans (kind prefix-code)
  "Two span lists -- the status view's bottom key-panel lines -- switching on
   the selected row's KIND. Mirrors %WORKSPACE-KEY-PANEL-CONTENT's per-kind
   dispatch (renderer-workspace.lisp) but with FR-003's status-only stage/
   unstage/discard keys (contract §2) in place of the repolist's worktree-
   management keys, which do not apply to this view."
  (values
   (%workspace-status-hint-spans
    (case kind
      (:section (list (cons "TAB" "fold") (cons "1..4" "visibility") (cons "?" "transient")))
      (:file (list (cons "s" "stage") (cons "u" "unstage") (cons "k" "discard")
                   (cons "TAB" "diff")))
      (:stash (list (cons "z" "stash") (cons "TAB" "fold")))
      (:commit (list (cons "n/p" "move")))
      (:pane (list (cons "RET" "focus")))
      (:worktree (list (cons "RET" "open")))
      (t (list (cons "n/p" "move") (cons "TAB" "expand") (cons "g" "refresh")))))
   (%workspace-status-hint-spans
    (list (cons "$" "process log") (cons "/" "filter") (cons ":" "command")
          (cons "C-p" "picker")
          (cons (format nil "~A d" (%workspace-prefix-label prefix-code)) "detach")
          (cons "q" "back")))))

;;; ── Frame assembly ───────────────────────────────────────────────────────

(defun %workspace-status-panel-rows-available (rows)
  "Rows the bottom key panel occupies below TERMINAL-ROWS = 12's threshold
   (2 content lines) vs. above the single-line footer it collapses to (1) --
   what a TRANSIENT (Unit TRANSIENT) must fit within before
   RENDER-WORKSPACE-STATUS-TO-TUI-STRING falls back to drawing it full-
   screen instead (contract §3's TRANSIENT-VIEW-HEIGHT/height-fallback
   note)."
  (if (>= rows 12) 2 1))

(defun %workspace-status-render-frame
    (worktree rows cols selected-object scroll expanded-node-ids file-diffs
     level messages transient prefix-code)
  (let* ((surface (cl-tui-kit/core:make-surface cols rows))
         (entries (workspace-status-entries
                   worktree :expanded-node-ids expanded-node-ids
                            :file-diffs file-diffs :visibility-level level))
         (view-rows (workspace-status-view-rows rows))
         (entry-count (length entries))
         (max-scroll (max 0 (- entry-count view-rows)))
         (scroll (max 0 (min (or scroll 0) max-scroll)))
         (visible (subseq entries (min scroll entry-count)
                          (min (+ scroll view-rows) entry-count)))
         (key-panel-p (>= rows 12))
         (content-top 1)
         (content-bottom (+ content-top view-rows))
         (separator-row content-bottom)
         (message-row (1+ separator-row))
         (footer-row (max 0 (1- rows)))
         (key-panel-line-1 (1- footer-row))
         (key-panel-separator-row (1- key-panel-line-1))
         (selected-entry (%workspace-status-selected-entry entries selected-object))
         (selected-kind (and selected-entry (fourth selected-entry))))
    (cl-tui-kit/core:surface-draw-styled-text
     surface 0 0 (%workspace-status-header-spans worktree) :max-width cols)
    (loop for entry in visible
          for row from content-top
          do (cl-tui-kit/core:surface-draw-styled-text
              surface 0 row
              (%workspace-status-row-spans entry selected-object)
              :max-width cols))
    (cl-tui-kit/core:surface-draw-styled-text
     surface 0 separator-row
     (list (cl-tui-kit/core:make-text-span
            (make-string cols :initial-element #\─)
            :style (%workspace-status-style-muted)))
     :max-width cols)
    (let ((panel-top (if key-panel-p key-panel-separator-row footer-row)))
      (cond
        (transient
         (render-transient-panel
          surface
          (cl-tui-kit/core:make-rectangle 0 panel-top cols (- rows panel-top))
          transient))
        (key-panel-p
         (when messages
           (cl-tui-kit/core:surface-draw-styled-text
            surface 0 message-row
            (list (cl-tui-kit/core:make-text-span
                   (format nil "message: ~A" (first messages))
                   :style (%workspace-status-style-muted)))
            :max-width cols))
         (cl-tui-kit/core:surface-draw-styled-text
          surface 0 key-panel-separator-row
          (list (cl-tui-kit/core:make-text-span
                 (make-string cols :initial-element #\─)
                 :style (%workspace-status-style-muted)))
          :max-width cols)
         (multiple-value-bind (line-1 line-2)
             (%workspace-status-key-panel-spans selected-kind prefix-code)
           (cl-tui-kit/core:surface-draw-styled-text
            surface 0 key-panel-line-1 line-1 :max-width cols)
           (cl-tui-kit/core:surface-draw-styled-text
            surface 0 footer-row line-2 :max-width cols)))
        (t
         (cl-tui-kit/core:surface-draw-styled-text
          surface 0 footer-row
          (%workspace-status-hint-spans (list (cons "q" "back") (cons "?" "help")))
          :max-width cols))))
    (%surface-to-ansi-frame surface)))

(defun render-workspace-status-to-tui-string
    (worktree rows cols &key selected-object (scroll 0) expanded-node-ids
                             file-diffs visibility-level messages transient
                             (prefix-code #x11))
  "Render the magit-style status buffer for WORKTREE through CL-TUI-KIT's
   headless surface, same contract as RENDER-WORKSPACE-OVERVIEW-TO-TUI-
   STRING (renderer-tui-kit.lisp): a complete ANSI frame string. TRANSIENT,
   when non-NIL and taller than the bottom key panel can hold
   (%WORKSPACE-STATUS-PANEL-ROWS-AVAILABLE), replaces the WHOLE frame with
   Unit TRANSIENT's own full-screen fallback (RENDER-TRANSIENT-FULL-SCREEN-
   TO-TUI-STRING) instead of being drawn into the panel -- the same height-
   fallback contract §3 documents for TRANSIENT-VIEW-HEIGHT."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (level (or visibility-level 2)))
    (if (and transient
             (> (transient-view-height transient)
                (%workspace-status-panel-rows-available rows)))
        (render-transient-full-screen-to-tui-string transient rows cols)
        (%workspace-status-render-frame
         worktree rows cols selected-object scroll expanded-node-ids
         file-diffs level messages transient prefix-code))))
