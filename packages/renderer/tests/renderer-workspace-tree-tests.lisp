(in-package #:nerimux/test/renderer)

;;;; Direct unit tests for %WORKSPACE-FLAT-TREE-ENTRIES / %WORKSPACE-NODE-
;;;; EXPANDED-P / %WORKSPACE-NODE-REFRESH-TAG (renderer-workspace-tree.lisp).
;;;;
;;;; The section-based overview redesign (magit-style) replaced the old
;;;; org -> repo -> worktree -> window -> pane hierarchy with three fixed
;;;; sections -- Attention, Active, Repositories -- so most of this file's
;;;; describe blocks below are section-shaped rather than level-shaped:
;;;;
;;;;   - A worktree needing attention (or holding an exited pane) shows
;;;;     under Attention; any other worktree with at least one pane shows
;;;;     under Active; every repository always has a row under Repositories,
;;;;     collapsed by default. A worktree never appears twice.
;;;;   - Window and pane rows are no longer part of the overview tree at all.
;;;;   - Expansion is keyed by (KIND . stable ID) in an external hash table
;;;;     the caller owns, not by object identity, so it survives being handed
;;;;     a freshly-scanned tree after a refresh.
;;;;   - Refresh state (R6.2) is a second, independent per-row tag.
;;;;
;;;; %BUILD-FIVE-LEVEL-TREE still builds the underlying MODEL fixture --
;;;; organization -> repository -> worktree -> 2 windows -> 3 panes -- for
;;;; tests of label/info-cluster/activity helpers that operate on those
;;;; objects directly rather than on the flattened overview tree, where
;;;; window/pane rows no longer appear.

(defun %build-five-level-tree ()
  "One organization -> one repository -> one worktree -> two windows (one
   with two panes, one with one pane). Returns (VALUES ORGANIZATION REPOSITORY
   WORKTREE WINDOW-1 WINDOW-2)."
  (let* ((pane-1 (nerimux/pane:make-pane :id 1 :fd -1 :title "shell"))
         (pane-2 (nerimux/pane:make-pane :id 2 :fd -1 :title "test"))
         (pane-3 (nerimux/pane:make-pane :id 3 :fd -1 :title "logs"))
         (window-1 (nerimux/window:make-window :id 1 :name "feature/tree"
                                              :panes (list pane-1 pane-2)))
         (window-2 (nerimux/window:make-window :id 2 :name "feature/tree (2)"
                                              :panes (list pane-3)))
         (worktree (nerimux/workspace-model:make-worktree
                    :id "wt-1" :path "/repo/wt" :branch "feature/tree"))
         (repository (nerimux/workspace-model:make-repository
                      :id "repo-1" :specification "github.com/team/tree"
                      :local-path "/repo" :worktrees (list worktree)))
         (organization (nerimux/workspace-model:make-organization
                        :id "github.com/team" :host "github.com" :name "team"
                        :repositories (list repository))))
    (setf (nerimux/pane:pane-window pane-1) window-1
          (nerimux/pane:pane-window pane-2) window-1
          (nerimux/pane:pane-window pane-3) window-2)
    (nerimux/pane:worktree-add-pane worktree pane-1)
    (nerimux/pane:worktree-add-pane worktree pane-2)
    (nerimux/pane:worktree-add-pane worktree pane-3)
    (values organization repository worktree window-1 window-2)))

(defun %build-section-fixture (&key attention-p pane-p)
  "One organization -> one repository -> one worktree, WORKTREE optionally
   dirty (ATTENTION-P, so it needs attention) and optionally holding one
   pane (PANE-P). Returns (VALUES ORGANIZATION REPOSITORY WORKTREE)."
  (let* ((worktree (nerimux/workspace-model:make-worktree
                    :id "wt-section" :path "/repo/wt" :branch "feature/section"
                    :dirty-p attention-p))
         (repository (nerimux/workspace-model:make-repository
                      :id "repo-section" :specification "github.com/team/section"
                      :local-path "/repo" :worktrees (list worktree)))
         (organization (nerimux/workspace-model:make-organization
                        :id "github.com/team-section" :host "github.com"
                        :name "team-section" :repositories (list repository))))
    (when pane-p
      (let* ((pane (nerimux/pane:make-pane :id 1 :fd -1))
             (window (nerimux/window:make-window :id 1 :name "w" :panes (list pane))))
        (setf (nerimux/pane:pane-window pane) window)
        (nerimux/pane:worktree-add-pane worktree pane)))
    (values organization repository worktree)))

(defun %build-filter-fixture ()
  "One organization holding two repositories: MATCH-REPO with a dirty
   (Attention) worktree branch \"only-match\", and OTHER-REPO with a clean,
   pane-less worktree branch \"buried-worktree\" reachable only by expanding
   its (default-collapsed) Repositories row. Returns (VALUES ORGANIZATION
   MATCH-REPO MATCH-WORKTREE OTHER-REPO OTHER-WORKTREE)."
  (let* ((match-worktree
           (nerimux/workspace-model:make-worktree
            :id "wt-match" :path "/repo/match" :branch "only-match" :dirty-p t))
         (match-repo
           (nerimux/workspace-model:make-repository
            :id "repo-match" :specification "github.com/team/match"
            :local-path "/repo/match" :worktrees (list match-worktree)))
         (other-worktree
           (nerimux/workspace-model:make-worktree
            :id "wt-other" :path "/repo/other" :branch "buried-worktree"))
         (other-repo
           (nerimux/workspace-model:make-repository
            :id "repo-other" :specification "github.com/team/other"
            :local-path "/repo/other" :worktrees (list other-worktree)))
         (organization
           (nerimux/workspace-model:make-organization
            :id "github.com/team-filter" :host "github.com" :name "team-filter"
            :repositories (list match-repo other-repo))))
    (values organization match-repo match-worktree other-repo other-worktree)))

(defun %tree-entry-kinds (entries)
  (mapcar #'fourth entries))

(describe "renderer-suite/workspace-tree-sections"

  (it "classifies a dirty worktree under Attention"
    (multiple-value-bind (organization repository worktree)
        (%build-section-fixture :attention-p t :pane-p t)
      (declare (ignore repository))
      (let ((entries (nerimux/renderer::%workspace-flat-tree-entries
                      (list organization) nil)))
        (expect (equal '(:section :worktree :section :repository)
                       (%tree-entry-kinds entries)))
        (expect (search "Attention (1)" (second (first entries))))
        (expect (eq worktree (third (second entries))))
        (expect (search "Repositories (1)" (second (third entries)))))))

  (it "classifies a clean worktree with panes under Active"
    (multiple-value-bind (organization repository worktree)
        (%build-section-fixture :attention-p nil :pane-p t)
      (declare (ignore repository))
      (let ((entries (nerimux/renderer::%workspace-flat-tree-entries
                      (list organization) nil)))
        (expect (equal '(:section :worktree :section :repository)
                       (%tree-entry-kinds entries)))
        (expect (search "Active (1)" (second (first entries))))
        (expect (eq worktree (third (second entries)))))))

  (it "omits Attention and Active entirely for a clean, pane-less worktree"
    (multiple-value-bind (organization) (%build-section-fixture)
      (let* ((entries (nerimux/renderer::%workspace-flat-tree-entries
                       (list organization) nil))
             (kinds (%tree-entry-kinds entries)))
        ;; Only the Repositories section (header + its always-visible
        ;; repository row) shows -- the worktree itself stays hidden behind
        ;; that repository row's own default collapse.
        (expect (equal '(:section :repository) kinds))
        (expect (search "Repositories (1)" (second (first entries)))))))

  (it "shows a repository row's worktrees only once expanded, default collapsed"
    (multiple-value-bind (organization repository worktree)
        (%build-section-fixture)
      (let ((collapsed-entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil)))
        (expect (equal '(:section :repository) (%tree-entry-kinds collapsed-entries))))
      (let ((expanded (make-hash-table :test #'equal)))
        (setf (gethash (list :repository (nerimux/workspace-model:repository-id repository))
                       expanded)
              t)
        (let ((expanded-entries
                (nerimux/renderer::%workspace-flat-tree-entries
                 (list organization) nil :expanded-node-ids expanded)))
          (expect (equal '(:section :repository :worktree)
                         (%tree-entry-kinds expanded-entries)))
          (expect (eq worktree (third (third expanded-entries))))))))

  (it "excludes an Attention worktree from its own repository's expansion"
    (multiple-value-bind (organization repository worktree)
        (%build-section-fixture :attention-p t)
      (let ((expanded (make-hash-table :test #'equal)))
        (setf (gethash (list :repository (nerimux/workspace-model:repository-id repository))
                       expanded)
              t)
        (let* ((entries (nerimux/renderer::%workspace-flat-tree-entries
                         (list organization) nil :expanded-node-ids expanded))
               (worktree-entries
                 (remove-if-not (lambda (e) (eq (fourth e) :worktree)) entries)))
          ;; WORKTREE shows once, under Attention -- not a second time nested
          ;; under the (now expanded) Repositories > repository row.
          (expect (= 1 (length worktree-entries)))
          (expect (eq worktree (third (first worktree-entries))))))))

  (it "folds a section's rows behind its header when the section itself is collapsed"
    (multiple-value-bind (organization) (%build-section-fixture :pane-p t)
      (let ((collapsed (make-hash-table :test #'equal)))
        (setf (gethash (list :section :active) collapsed) t)
        (let* ((entries (nerimux/renderer::%workspace-flat-tree-entries
                         (list organization) collapsed))
               (kinds (%tree-entry-kinds entries)))
          (expect (equal '(:section :section :repository) kinds))
          (expect (search "Active (1)" (second (first entries))))))))

  (it "keeps collapse state across a refresh that rebuilds the tree with the same IDs"
    (multiple-value-bind (organization repository)
        (%build-section-fixture)
      (let ((collapsed (make-hash-table :test #'equal))
            (expanded (make-hash-table :test #'equal)))
        (setf (gethash (list :repository (nerimux/workspace-model:repository-id repository))
                       expanded)
              t)
        ;; Simulate a refresh: a new organization/repository/worktree tree
        ;; with the SAME stable IDs as before, but different (non-EQ) structs.
        (let* ((new-worktree
                 (nerimux/workspace-model:make-worktree
                  :id "wt-section" :path "/repo/wt" :branch "feature/tree-2"))
               (new-repository
                 (nerimux/workspace-model:make-repository
                  :id "repo-section" :specification "github.com/team/section"
                  :local-path "/repo" :worktrees (list new-worktree)))
               (new-organization
                 (nerimux/workspace-model:make-organization
                  :id "github.com/team-section" :host "github.com"
                  :name "team-section" :repositories (list new-repository))))
          (expect (not (eq new-repository repository)))
          (let ((kinds
                  (%tree-entry-kinds
                   (nerimux/renderer::%workspace-flat-tree-entries
                    (list new-organization) collapsed :expanded-node-ids expanded))))
            (expect (equal '(:section :repository :worktree) kinds))))))))

(describe "renderer-suite/workspace-tree-refresh-tags"

  ;; R6.2: a row being refreshed carries a " refreshing" suffix; a row whose
  ;; last refresh failed carries " stale" instead. Neither tag is present
  ;; when the row is in neither table.
  (it "appends refreshing/stale suffixes to worktree and repository labels"
    (multiple-value-bind (organization repository worktree)
        (%build-section-fixture :attention-p t)
      (let* ((repo-id (nerimux/workspace-model:repository-id repository))
             (wt-id (nerimux/workspace-model:worktree-id worktree))
             (refreshing (make-hash-table :test #'equal))
             (stale (make-hash-table :test #'equal)))
        (setf (gethash (list :worktree wt-id) refreshing) t)
        (setf (gethash (list :repository repo-id) stale) t)
        (let ((entries
                (nerimux/renderer::%workspace-flat-tree-entries
                 (list organization) nil
                 :refreshing-ids refreshing :stale-ids stale)))
          ;; entries: (Attention header) (worktree, refreshing)
          ;;          (Repositories header) (repository, stale)
          (expect (search " refreshing" (second (second entries))))
          (expect (search " stale" (second (fourth entries))))))))

  ;; Refreshing wins over stale when a row is (transiently) in both tables.
  ;; %WORKSPACE-NODE-REFRESH-TAG is a generic (KIND ID) lookup, independent
  ;; of whether that KIND currently has any row in the tree.
  (it "prefers refreshing over stale when both apply to the same row"
    (let ((refreshing (make-hash-table :test #'equal))
          (stale (make-hash-table :test #'equal)))
      (setf (gethash (list :worktree "wt-both") refreshing) t)
      (setf (gethash (list :worktree "wt-both") stale) t)
      (expect (string= " refreshing"
                       (nerimux/renderer::%workspace-node-refresh-tag
                        :worktree "wt-both" refreshing stale))))))

(describe "renderer-suite/workspace-scanning-placeholder"

  ;; R6.2: while the initial ghq/worktree scan is still running, the whole
  ;; frame is replaced by an empty tree plus a centred scanning message
  ;; -- no header, no tree box, nothing that implies data has loaded.
  ;; The " nerimux " chip is the ordinary frame's header signature.
  (it "shows only the scanning message while the initial catalog scan is still running"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :scanning-p t)))
      (expect (search "scanning workspaces..." frame))
      (expect (not (search " nerimux " frame)))))

  ;; Once organizations exist, scanning-p no longer applies even if left T --
  ;; the guard is specifically "still scanning AND nothing has arrived yet".
  (it "renders the ordinary tree once organizations have arrived, even if scanning-p lingers"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let ((frame
              (nerimux/renderer:render-workspace-overview-to-string
               (list organization) 24 80 :scanning-p t)))
        (expect (search " nerimux " frame))
        (expect (not (search "scanning workspaces..." frame))))))

  ;; FR-004b: a positive SCAN-PROGRESS names how many repositories the scan
  ;; has found so far, instead of the bare ellipsis -- a scan that
  ;; legitimately runs tens of seconds otherwise looks identical at second 1
  ;; and second 30.
  (it "shows the repository count in the scanning message when scan-progress is a positive integer"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :scanning-p t :scan-progress 12)))
      (expect (search "scanning workspaces... 12 repositories" frame))))

  ;; NIL scan-progress (the default) keeps the plain ellipsis wording.
  (it "keeps the plain ellipsis wording when scan-progress is nil"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :scanning-p t :scan-progress nil)))
      (expect (search "scanning workspaces..." frame))
      (expect (not (search "repositories" frame))))))

(describe "renderer-suite/workspace-catalog-empty-hint"

  ;; FR-004c: an empty catalog with no scan running shows a 3-line guide
  ;; naming the ghq root, instead of leaving the interior blank -- an empty
  ;; tree because the scan has not finished (the scanning-p placeholder
  ;; above) needs to read differently from an empty tree because there is
  ;; genuinely nothing to find.
  (it "shows the no-repositories-found guide with the ghq root when the catalog is empty"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :catalog-empty-hint "/tmp/ghq")))
      (expect (search "no repositories found" frame))
      (expect (search "/tmp/ghq" frame))
      (expect (search "ghq get <owner>/<repo>" frame))))

  ;; While a scan is running, this branch never applies -- scanning-p on an
  ;; empty catalog takes the whole-frame scanning placeholder instead (R6.2),
  ;; which has nothing to do with catalog-empty-hint at all.
  (it "does not show the empty-catalog hint while a scan is running"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :scanning-p t :catalog-empty-hint "/tmp/ghq")))
      (expect (not (search "no repositories found" frame))))))

;;; PR2 `/` text filter: %WORKSPACE-FILTER-TREE-ENTRIES keeps a row when its
;;; own node matches, or any descendant does -- which, read the other way,
;;; keeps every ancestor of a match too. Siblings of a match that do not
;;; themselves match must NOT survive, which is the precise thing a filter
;;; is for. The section-based redesign adds a second collapse layer (a
;;; repository row's own default-collapsed worktree list) that filter must
;;; also penetrate.

(describe "renderer-suite/workspace-tree-filter"

  ;; A filter matching one worktree's branch keeps that worktree and its
  ;; Attention section header (ancestor) -- but prunes the sibling
  ;; repository/worktree that do not match at all.
  (it "keeps a matching worktree and its section header, prunes the non-matching sibling"
    (multiple-value-bind (organization match-repo match-worktree)
        (%build-filter-fixture)
      (declare (ignore match-repo))
      (let* ((entries
               (nerimux/renderer::%workspace-flat-tree-entries
                (list organization) nil :filter "only-match"))
             (kinds (%tree-entry-kinds entries))
             (objects (mapcar #'third entries)))
        (expect (equal '(:section :worktree) kinds))
        (expect (member match-worktree objects :test #'eq)))))

  ;; Case-insensitive: an uppercase query matches a lowercase branch.
  (it "matches case-insensitively"
    (multiple-value-bind (organization) (%build-filter-fixture)
      (let ((entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil :filter "ONLY-MATCH")))
        (expect (find :worktree entries :key #'fourth)))))

  ;; NIL or an all-blank filter is treated as "no filter": every row survives.
  (it "returns every row unchanged for a NIL or all-blank filter"
    (multiple-value-bind (organization) (%build-filter-fixture)
      (let ((unfiltered
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil))
            (nil-filtered
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil :filter nil))
            (blank-filtered
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil :filter "   ")))
        (expect (equal (%tree-entry-kinds unfiltered) (%tree-entry-kinds nil-filtered)))
        (expect (equal (%tree-entry-kinds unfiltered) (%tree-entry-kinds blank-filtered))))))

  ;; A filter matching nothing at all leaves an empty tree, not an error and
  ;; not the unfiltered tree.
  (it "returns no rows for a filter matching nothing"
    (multiple-value-bind (organization) (%build-filter-fixture)
      (let ((entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil :filter "no-such-match-anywhere")))
        (expect (null entries)))))

  ;; Search penetrates a repository row's own default collapse: OTHER-
  ;; WORKTREE is clean and pane-less (no Attention/Active row of its own),
  ;; reachable unfiltered only by expanding OTHER-REPO's Repositories row --
  ;; which is collapsed by default (no EXPANDED-NODE-IDS entry at all). A
  ;; filter matching its branch must still surface it and its repository.
  (it "search penetrates a repository row's default-collapsed worktree list"
    (multiple-value-bind (organization match-repo match-worktree other-repo other-worktree)
        (%build-filter-fixture)
      (declare (ignore match-repo match-worktree))
      (expect (null (find other-worktree
                         (nerimux/renderer::%workspace-flat-tree-entries
                          (list organization) nil)
                         :key #'third)))
      (let* ((entries
               (nerimux/renderer::%workspace-flat-tree-entries
                (list organization) nil :filter "buried"))
             (objects (mapcar #'third entries)))
        (expect (member other-worktree objects :test #'eq))
        (expect (member other-repo objects :test #'eq))))))

;;; Bug fix: RENDER-WORKSPACE-OVERVIEW-TO-STRING used to compare MODE
;;; against the retired :TREE-FILTER modal (the legacy *command* name in
;;; server-multi-dispatch-command-workspace.lisp's mapping table) instead
;;; of the live :FILTER modal %CLIENT-ENTER-TREE-FILTER-MODE actually sets
;;; (server-multi-dispatch-command-input.lisp) -- so pressing `/` fell
;;; through to the ordinary key-panel branch and the query the user was
;;; typing never appeared on screen.

(describe "renderer-suite/workspace-tree-filter-prompt"

  (it "shows the /query prompt at the footer row when mode is :filter, and no ordinary key hints"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((frame
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization) 24 100
                :mode :filter :tree-filter "abc"))
             (plain (strip-sgr frame)))
        (expect (search "/abc" plain))
        (expect (not (search "refresh" plain)))
        (expect (not (search "detach" plain))))))

  ;; An empty (but non-NIL) tree-filter still draws the bare `/` prompt --
  ;; the moment the user presses `/` and has typed nothing yet.
  (it "shows a bare / prompt when mode is :filter and tree-filter is empty"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((frame
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization) 24 100
                :mode :filter :tree-filter ""))
             (plain (strip-sgr frame)))
        (expect (search "/" plain))
        (expect (not (search "detach" plain)))))))

;;; PR2 worktree-row info cluster: state tag, ahead/behind, pane count, and a
;;; relative last-activity time, in that priority order. Unaffected by the
;;; section-based redesign: a :WORKTREE row's info cluster is built the same
;;; way regardless of which section it appears under.

(describe "renderer-suite/workspace-tree-info-cluster"

  ;; A fixed worktree: ahead 2, dirty, 2 panes with one exited, and a known
  ;; last-output-time 5 minutes in the past. All four fields must appear in
  ;; the rendered (SGR-stripped) tree row.
  (it "shows ahead count, pane count with exit marker, state tag, and relative time"
    (let* ((pane-1 (nerimux/pane:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/pane:make-pane :id 2 :fd -1 :process-exited-p t))
           ;; %WORKTREE-TREE-WINDOWS (called while flattening the tree) sorts
           ;; WORKTREE-PANES by their owning window's id, so every pane here
           ;; needs a real WINDOW -- a pane with no window at all is a type
           ;; error there, not just an incomplete fixture.
           (window
             (nerimux/window:make-window
              :id 1 :name "info" :panes (list pane-1 pane-2)))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-info" :path "/repo/info" :branch "info"
              :status t :dirty-p t :ahead 2))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-info" :specification "github.com/team/info"
              :local-path "/repo" :worktrees (list worktree)))
           (organization
             (nerimux/workspace-model:make-organization
              :id "github.com/team-info" :host "github.com" :name "team-info"
              :repositories (list repository))))
      (setf (nerimux/pane:pane-window pane-1) window
            (nerimux/pane:pane-window pane-2) window)
      (nerimux/pane:worktree-add-pane worktree pane-1)
      (nerimux/pane:worktree-add-pane worktree pane-2)
      (setf (nerimux/pane:pane-last-output-time pane-1)
            (- (get-universal-time) 300))
      (let* ((frame
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization) 24 100))
             (plain (strip-sgr frame)))
        (expect (search "+2" plain))
        (expect (search "2p!" plain))
        (expect (search "DIRTY" plain))
        (expect (search "5m" plain)))))

  ;; %WORKTREE-RELATIVE-TIME-TEXT's own boundaries: <60s is "now"; the Nm/Nh/
  ;; Nd buckets switch exactly at 60/3600/86400 seconds, per its own
  ;; (< DELTA 60) / (< DELTA 3600) / (< DELTA 86400) guards.
  (it "switches relative-time buckets at the 60s/3600s/86400s boundaries"
    (flet ((relative (delta)
             (nerimux/renderer::%worktree-relative-time-text
              (- (get-universal-time) delta))))
      (expect (string= "now" (relative 59)))
      (expect (string= "1m" (relative 60)))
      (expect (string= "59m" (relative 3599)))
      (expect (string= "1h" (relative 3600)))
      (expect (string= "1d" (relative 86400)))))

  ;; NIL (a pane that has never produced output or been focused) reports
  ;; "never" by returning NIL itself -- the caller (%WORKTREE-TREE-INFO-
  ;; TOKENS) drops a NIL time token entirely rather than showing a literal
  ;; string for it.
  (it "returns NIL for a worktree with no pane activity at all"
    (expect (null (nerimux/renderer::%worktree-relative-time-text nil)))))

;;; Section-based redesign: the Dracula truecolour palette (renderer-
;;; style.lisp) and the new +SGR-SECTION+ constant reach an actual rendered
;;; frame through the plain-ANSI tree row path (TREE-ROW-TEXT in
;;; renderer-workspace.lisp) -- the only render path that emits inline SGR
;;; for tree rows at all (see renderer-workspace-tree.lisp's file header on
;;; why the real cl-tui-kit client path does not).

(describe "renderer-suite/workspace-tree-dracula-colors"

  (it "renders a section header in +sgr-section+ and a worktree's ahead count in Dracula truecolour"
    (multiple-value-bind (organization repository worktree)
        (%build-section-fixture :attention-p t :pane-p t)
      (declare (ignore repository))
      (setf (nerimux/workspace-model:worktree-ahead worktree) 1)
      (let ((frame
              (nerimux/renderer:render-workspace-overview-to-string
               (list organization) 24 100)))
        (expect frame :to-contain-sgr nerimux/renderer::+sgr-section+)
        (expect frame :to-contain-sgr nerimux/renderer::+sgr-ahead+)))))

;;; Review-round fix: a "no matches: /query" placeholder replaces the empty
;;; tree box when a non-empty filter narrows a non-empty catalog to zero
;;; rows, on BOTH render paths -- the plain-ANSI pass draws the message
;;; itself, and the cl-tui-kit pass must skip invoking the tree widget
;;; entirely rather than overlay an empty (or worse, stale) box on top of it.

(describe "renderer-suite/workspace-tree-no-matches"

  ;; (a) The plain-ANSI pass shows the placeholder and leaks no tree-row
  ;; text (the worktree's branch label) through.
  (it "shows a no-matches placeholder and no tree-row text when the filter matches nothing"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((frame
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization) 24 100 :tree-filter "zzz-no-match-anywhere"))
             (plain (strip-sgr frame)))
        (expect (search "no matches: /zzz-no-match-anywhere" plain))
        (expect (not (search "feature/tree" plain))))))

  ;; (b) The cl-tui-kit pass skips drawing the tree widget entirely in the
  ;; same case -- the organization's own label must not appear anywhere in
  ;; the final output either, which only holds if the widget-renderer was
  ;; never invoked (not merely that it drew zero rows).
  (it "suppresses the tree widget so no organization label appears either"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((output
               (nerimux/renderer:render-workspace-overview-to-tui-string
                (list organization) 24 100 :tree-filter "zzz-no-match-anywhere"))
             (plain (strip-sgr output)))
        (expect (search "no matches: /zzz-no-match-anywhere" plain))
        (expect (not (search "github.com/team" plain)))))))

;;; Review-round fix: below the 7-row floor (TALL-ENOUGH-P in RENDER-
;;; WORKSPACE-OVERVIEW-TO-STRING), the ordinary tree/separator/detail/
;;; message layout is replaced by a single "too short" message instead of
;;; letting rows computed past the terminal's actual height silently
;;; overlap (the footer landing on top of the detail rows, for instance).

(describe "renderer-suite/workspace-tree-too-short"

  (it "shows a single too-short message instead of the ordinary layout below 7 rows"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((frame
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization) 5 100 :selected-tree-object organization))
             (plain (strip-sgr frame)))
        (expect (search "terminal too short for panels" plain))
        ;; No ordinary tree-row content (the worktree's branch label) and no
        ;; detail-panel content (an organization field, or the no-selection
        ;; placeholder) ever renders in this branch -- DETAIL-LINES is never
        ;; called at all when TALL-ENOUGH-P is false.
        (expect (not (search "feature/tree" plain)))
        (expect (not (search "(no selection)" plain)))
        (expect (not (search "organization:" plain)))))))

;;; S3: %WORKSPACE-KEY-PANEL-CONTENT switches its first line's hints on the
;;; selected row's KIND with no test coverage of any branch -- collapsing
;;; every branch to the same default would have gone unnoticed. Each case
;;; below asserts a hint substring unique to that branch is present, and a
;;; substring unique to a neighbouring, easily-confused branch is absent, so
;;; a dispatch that quietly falls through to the wrong branch fails loudly
;;; rather than passing on a coincidental substring match.

(describe "renderer-suite/workspace-key-panel-content"

  (it "shows the fold/section hints for a :section-keyword selection"
    (let ((plain (strip-sgr
                  (nerimux/renderer::%workspace-key-panel-content
                   :repositories :normal #x11 nil))))
      (expect (search "fold" plain))
      (expect (not (search "shell(main)" plain)))))

  (it "shows the shell(main)/fetch hints for a repository selection"
    (let* ((repository (nerimux/workspace-model:make-repository :id "repo-panel" :specification "s"))
           (plain (strip-sgr
                   (nerimux/renderer::%workspace-key-panel-content
                    repository :normal #x11 nil))))
      (expect (search "shell(main)" plain))
      (expect (not (search "fold" plain)))))

  (it "shows the default worktree-row hints for a worktree selection"
    (let* ((worktree (nerimux/workspace-model:make-worktree :id "wt-panel" :path "/wt"))
           (plain (strip-sgr
                   (nerimux/renderer::%workspace-key-panel-content
                    worktree :normal #x11 nil))))
      ;; Destructive worktree actions moved behind the `w` menu when the magit
      ;; keymap retired their single-key shortcuts, so the panel names the menu
      ;; rather than an `X` that no longer does anything.
      (expect (search "worktree menu" plain))
      (expect (not (search "shell(main)" plain)))
      ;; This panel is permanently on screen, so a retired key advertised here
      ;; misleads on every frame -- worse than the help view, which the user
      ;; has to ask for.
      (expect (not (search "X delete" plain)))
      (expect (not (search "L/U" plain)))))

  (it "shows the diff and stage hints for a :file row selection"
    (let ((plain (strip-sgr
                  (nerimux/renderer::%workspace-key-panel-content
                   (list :file "wt-panel" "src/foo.lisp" " M") :normal #x11 nil))))
      (expect (search "diff" plain))
      (expect (search "stage" plain))
      (expect (not (search "worktree menu" plain)))))

  (it "shows the move-only hint for a :diff-line row selection, without :file's diff hint"
    (let ((plain (strip-sgr
                  (nerimux/renderer::%workspace-key-panel-content
                   (list :diff-line "wt-panel" "src/foo.lisp" 0) :normal #x11 nil))))
      (expect (search "move" plain))
      (expect (not (search "diff" plain)))))

  (it "shows the select hint with no Enter action for a :commit row selection"
    (let ((plain (strip-sgr
                  (nerimux/renderer::%workspace-key-panel-content
                   (list :commit "wt-panel" "abc1234" "subject") :normal #x11 nil))))
      (expect (search "select" plain))
      (expect (not (search "focus" plain)))))

  (it "shows the focus hint for a pane selection"
    (let* ((pane (nerimux/pane:make-pane :id 1 :fd -1))
           (plain (strip-sgr
                   (nerimux/renderer::%workspace-key-panel-content
                    pane :normal #x11 nil))))
      (expect (search "focus" plain))
      (expect (not (search "delete" plain))))))

(describe "renderer-suite/workspace-repository-state"

  (it "renders every repository health state in the selected detail panel"
    (multiple-value-bind (organization repository) (%build-five-level-tree)
      (let ((states
              (list (list :missing "MISSING"
                          (lambda () (setf (nerimux/workspace-model:repository-missing-p repository) t)))
                    (list :conflict "CONFLICT"
                          (lambda () (setf (nerimux/workspace-model:repository-conflict-p repository) t)))
                    (list :dirty "DIRTY"
                          (lambda () (setf (nerimux/workspace-model:repository-dirty-p repository) t)))
                    (list :no-worktree "NO-WORKTREE"
                          (lambda () (setf (nerimux/workspace-model:repository-worktrees repository) nil)))
                    (list :ready "ready" nil))))
        (dolist (state states)
          (setf (nerimux/workspace-model:repository-missing-p repository) nil
                (nerimux/workspace-model:repository-conflict-p repository) nil
                (nerimux/workspace-model:repository-dirty-p repository) nil
                (nerimux/workspace-model:repository-worktrees repository)
                (list (nerimux/workspace-model:make-worktree :id "state-wt" :path "/wt")))
          (when (third state) (funcall (third state)))
          (let ((plain
                  (strip-sgr
                   (nerimux/renderer:render-workspace-overview-to-string
                    (list organization) 24 100
                    :selected-tree-object repository))))
            (expect (search (second state) plain))))))))

(describe "renderer-suite/workspace-tree-projection-helpers"

  (it "uses stable identities for every model level and a generic fallback"
    (multiple-value-bind (organization repository worktree window-1)
        (%build-five-level-tree)
      (let ((pane (first (nerimux/window:window-panes window-1))))
        (expect (equal '(:organization "github.com/team")
                       (nerimux/renderer::%workspace-tree-node-key organization)))
        (expect (equal '(:repository "repo-1")
                       (nerimux/renderer::%workspace-tree-node-key repository)))
        (expect (equal '(:worktree "wt-1")
                       (nerimux/renderer::%workspace-tree-node-key worktree)))
        (expect (equal '(:window 1)
                       (nerimux/renderer::%workspace-tree-node-key window-1)))
        (expect (equal '(:pane 1 1)
                       (nerimux/renderer::%workspace-tree-node-key pane)))
        (expect (equal '(:workspace-object :other)
                       (nerimux/renderer::%workspace-tree-node-key :other))))))

  (it "falls back to readable identifiers when labels lack descriptive data"
    (let ((organization (nerimux/workspace-model:make-organization :id "local-id" :host "" :name ""))
          (repository (nerimux/workspace-model:make-repository :id "repo-id" :specification "" :local-path ""))
          (worktree (nerimux/workspace-model:make-worktree :id "wt-id" :path "" :branch nil))
          (pane (nerimux/pane:make-pane :id 7 :fd -1 :title "" :start-command "")))
      (expect (string= "local-id" (nerimux/renderer::%organization-tree-label organization)))
      (expect (string= "repo-id" (nerimux/renderer::%repository-tree-label repository)))
      (expect (string= "wt-id" (nerimux/renderer::%worktree-tree-label worktree)))
      (expect (string= "pane/7 shell" (nerimux/renderer::%pane-tree-label pane)))))

  (it "prefers each available partial label before its identifier fallback"
    (let ((host-only (nerimux/workspace-model:make-organization :id "org-id" :host "git.example" :name ""))
          (name-only (nerimux/workspace-model:make-organization :id "org-id" :host "" :name "team"))
          (path-only (nerimux/workspace-model:make-repository :id "repo-id" :specification "" :local-path "/work/repo"))
          (command-only (nerimux/pane:make-pane :id 7 :fd -1 :title "" :start-command "make test")))
      (expect (string= "git.example" (nerimux/renderer::%organization-tree-label host-only)))
      (expect (string= "team" (nerimux/renderer::%organization-tree-label name-only)))
      (expect (string= "/work/repo" (nerimux/renderer::%repository-tree-label path-only)))
      (expect (string= "pane/7 make test" (nerimux/renderer::%pane-tree-label command-only)))))

  (it "keeps only meaningful activity and info tokens"
    (let* ((worktree (nerimux/workspace-model:make-worktree
                      :id "wt" :path "/tmp/wt" :branch "main"
                      :ahead 0 :behind 0))
           (pane (nerimux/pane:make-pane :id 1 :fd -1)))
      (nerimux/pane:worktree-add-pane worktree pane)
      (expect (null (nerimux/renderer::%worktree-last-activity-time worktree)))
      (expect (nerimux/renderer::%worktree-tree-info-tokens worktree))
      (expect (string= "" (nerimux/renderer::%workspace-tree-node-search-text :unknown worktree)))))

  (it "uses a readable fallback for non-letter prefix bindings"
    (expect (string= "key/999"
                     (nerimux/renderer::%workspace-prefix-label 999))))

  (it "selects the newest output or focus timestamp"
    (multiple-value-bind (organization repository worktree window-1)
        (%build-five-level-tree)
      (declare (ignorable organization repository))
      (let ((pane-1 (first (nerimux/window:window-panes window-1)))
            (pane-2 (second (nerimux/window:window-panes window-1))))
        (setf (nerimux/pane:pane-last-output-time pane-1) 10
              (nerimux/pane:pane-last-focused-time pane-2) 20)
        (expect (= 20 (nerimux/renderer::%worktree-last-activity-time worktree))))))

  (it "renders behind-only repository information"
    (let ((worktree (nerimux/workspace-model:make-worktree :id "wt" :behind 2)))
      (multiple-value-bind (plain styled)
          (nerimux/renderer::%worktree-tree-info-suffix worktree 80)
        (declare (ignore styled))
        (expect (search "-2" plain))))))

;;; PR2 tree row budget: the section-based redesign's key panel reserves 8
;;; rows around the tree at TERMINAL-ROWS >= 12 (a divider + 2 content lines
;;; instead of the single-line footer), collapsing back to the original 6
;;; rows below that height. Floored at 1.

(describe "renderer-suite/workspace-tree-view-rows"

  (it "reserves 6 rows around the tree below the key-panel height threshold"
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 7)))
    (expect (= 5 (nerimux/renderer:workspace-tree-view-rows 11))))

  (it "reserves 8 rows around the tree at and above the key-panel height threshold"
    (expect (= 4 (nerimux/renderer:workspace-tree-view-rows 12)))
    (expect (= 22 (nerimux/renderer:workspace-tree-view-rows 30))))

  ;; The floor at 1 kicks in for any terminal too short to spare the
  ;; reserved rows, rather than going negative or zero.
  (it "floors at 1 row for a terminal shorter than the reserved rows"
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 6)))
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 1)))
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 0)))))

;;; Inline worktree expansion (Wave B): Tab on a worktree row emits pane/
;;; file/commit child rows one level deeper, in that fixed order, when
;;; expanded via *WORKSPACE-EXPANDED-NODE-IDS* keyed (:WORKTREE ID) -- the
;;; same table and default-COLLAPSED polarity a Repositories-section
;;; repository row already uses for its own expansion.

(describe "renderer-suite/workspace-tree-worktree-expansion"

  (it "emits pane, file, and commit child rows in order when expanded"
    (let* ((pane (nerimux/pane:make-pane :id 1 :fd -1 :title "shell"))
           (window (nerimux/window:make-window :id 1 :name "w" :panes (list pane)))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-expand" :path "/repo/wt" :branch "expand" :dirty-p t
              :changed-files (list (cons " M" "src/foo.lisp"))
              :recent-commits (list (cons "abc1234" "fix a bug"))
              :commits-state :ready))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-expand" :specification "github.com/team/expand"
              :local-path "/repo" :worktrees (list worktree)))
           (organization
             (nerimux/workspace-model:make-organization
              :id "github.com/team-expand" :host "github.com" :name "team-expand"
              :repositories (list repository))))
      (setf (nerimux/pane:pane-window pane) window)
      (nerimux/pane:worktree-add-pane worktree pane)
      (let ((expanded (make-hash-table :test #'equal)))
        (setf (gethash (list :worktree "wt-expand") expanded) t)
        (let* ((entries
                 (nerimux/renderer::%workspace-flat-tree-entries
                  (list organization) nil :expanded-node-ids expanded))
               (kinds (%tree-entry-kinds entries)))
          ;; (Attention header) worktree pane file commit (Repositories header) repository
          (expect (equal '(:section :worktree :pane :file :commit :section :repository)
                         kinds))
          (expect (eq pane (third (third entries))))
          (expect (equal (list :file "wt-expand" "src/foo.lisp" " M")
                         (third (fourth entries))))
          (expect (equal (list :commit "wt-expand" "abc1234" "fix a bug")
                         (third (fifth entries))))))))

  (it "omits empty groups and stays collapsed by default"
    (multiple-value-bind (organization repository worktree)
        (%build-section-fixture :attention-p t)
      (declare (ignore repository))
      ;; Collapsed by default: no expansion-table entry at all.
      (let ((collapsed-entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil)))
        (expect (equal '(:section :worktree :section :repository)
                       (%tree-entry-kinds collapsed-entries))))
      ;; Expanded, but with no panes/changed-files/commits at all: still no
      ;; child rows -- an empty group contributes nothing, not a blank row.
      (let ((expanded (make-hash-table :test #'equal)))
        (setf (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                       expanded)
              t)
        (let ((entries
                (nerimux/renderer::%workspace-flat-tree-entries
                 (list organization) nil :expanded-node-ids expanded)))
          (expect (equal '(:section :worktree :section :repository)
                         (%tree-entry-kinds entries)))))))

  (it "shows a placeholder row while commits-state is :pending or :failed, none while NIL"
    (multiple-value-bind (organization repository worktree)
        (%build-section-fixture :attention-p t)
      (declare (ignore repository))
      (let ((expanded (make-hash-table :test #'equal)))
        (setf (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                       expanded)
              t)
        (setf (nerimux/workspace-model:worktree-commits-state worktree) :pending)
        (let ((entries
                (nerimux/renderer::%workspace-flat-tree-entries
                 (list organization) nil :expanded-node-ids expanded)))
          (expect (equal '(:section :worktree :commit :section :repository)
                         (%tree-entry-kinds entries)))
          (expect (search "refreshing" (second (third entries)))))
        (setf (nerimux/workspace-model:worktree-commits-state worktree) :failed)
        (let ((entries
                (nerimux/renderer::%workspace-flat-tree-entries
                 (list organization) nil :expanded-node-ids expanded)))
          (expect (search "UNKNOWN" (second (third entries)))))
        ;; NIL (never fetched): no placeholder row at all, not even a blank
        ;; one -- distinct from :FAILED, which always shows "UNKNOWN".
        (setf (nerimux/workspace-model:worktree-commits-state worktree) nil)
        (let ((entries
                (nerimux/renderer::%workspace-flat-tree-entries
                 (list organization) nil :expanded-node-ids expanded)))
          (expect (equal '(:section :worktree :section :repository)
                         (%tree-entry-kinds entries)))))))

  (it "keeps a cons node's own list as its node key, EQUAL-stable across two flatten calls"
    (let ((first-key
            (nerimux/renderer::%workspace-tree-node-key
             (list :file "wt-1" "src/foo.lisp" " M")))
          (second-key
            (nerimux/renderer::%workspace-tree-node-key
             (list :file "wt-1" "src/foo.lisp" " M"))))
      (expect (equal first-key second-key))
      (expect (not (eq first-key second-key)))))

  ;; Wave C: a :FILE row's own inline-diff expansion, one level deeper than
  ;; the :FILE row itself, gated by *WORKSPACE-EXPANDED-NODE-IDS* under
  ;; (:FILE-DIFF WORKTREE-ID PATH) -- NOT the file row's own node key -- and
  ;; sourced from the *WORKSPACE-FILE-DIFFS* cache passed in as :FILE-DIFFS.
  (it "keeps a diff-line cons node's own list EQUAL-stable across two flatten calls"
    (let ((first-key
            (nerimux/renderer::%workspace-tree-node-key
             (list :diff-line "wt-1" "src/foo.lisp" 0)))
          (second-key
            (nerimux/renderer::%workspace-tree-node-key
             (list :diff-line "wt-1" "src/foo.lisp" 0))))
      (expect (equal first-key second-key))
      (expect (not (eq first-key second-key))))))

(describe "renderer-suite/workspace-tree-file-diff-expansion"

  (flet ((%build-diff-fixture (&key (code " M") (path "src/foo.lisp"))
           (let* ((worktree
                    (nerimux/workspace-model:make-worktree
                     :id "wt-diff" :path "/repo/wt" :branch "diff" :dirty-p t
                     :changed-files (list (cons code path))))
                  (repository
                    (nerimux/workspace-model:make-repository
                     :id "repo-diff" :specification "github.com/team/diff"
                     :local-path "/repo" :worktrees (list worktree)))
                  (organization
                    (nerimux/workspace-model:make-organization
                     :id "github.com/team-diff" :host "github.com" :name "team-diff"
                     :repositories (list repository))))
             (values organization repository worktree))))

    (it "emits one :diff-line row per cached line, in order, when a file's diff is expanded"
      (multiple-value-bind (organization repository worktree)
          (%build-diff-fixture)
        (declare (ignore repository))
        (let ((expanded (make-hash-table :test #'equal))
              (file-diffs (make-hash-table :test #'equal))
              (wt-id (nerimux/workspace-model:worktree-id worktree)))
          (setf (gethash (list :worktree wt-id) expanded) t)
          (setf (gethash (list :file-diff wt-id "src/foo.lisp") expanded) t)
          (setf (gethash (list wt-id "src/foo.lisp") file-diffs)
                (list :ready 3 (list "@@ -1,2 +1,2 @@" "-old line" "+new line")))
          (let* ((entries
                   (nerimux/renderer::%workspace-flat-tree-entries
                    (list organization) nil
                    :expanded-node-ids expanded :file-diffs file-diffs))
                 (diff-entries (remove-if-not (lambda (e) (eq (fourth e) :diff-line)) entries)))
            (expect (= 3 (length diff-entries)))
            (expect (equal (list "@@ -1,2 +1,2 @@" "-old line" "+new line")
                           (mapcar #'second diff-entries)))
            (expect (equal (list :diff-line wt-id "src/foo.lisp" 0)
                           (third (first diff-entries))))
            (expect (equal (list :diff-line wt-id "src/foo.lisp" 2)
                           (third (third diff-entries))))))))

    (it "appends a truncation row naming the remaining count when total exceeds the cached lines"
      (multiple-value-bind (organization repository worktree)
          (%build-diff-fixture)
        (declare (ignore repository))
        (let ((expanded (make-hash-table :test #'equal))
              (file-diffs (make-hash-table :test #'equal))
              (wt-id (nerimux/workspace-model:worktree-id worktree))
              (lines (loop for i from 1 to 200 collect (format nil "line ~D" i))))
          (setf (gethash (list :worktree wt-id) expanded) t)
          (setf (gethash (list :file-diff wt-id "src/foo.lisp") expanded) t)
          (setf (gethash (list wt-id "src/foo.lisp") file-diffs)
                (list :ready 250 lines))
          (let* ((entries
                   (nerimux/renderer::%workspace-flat-tree-entries
                    (list organization) nil
                    :expanded-node-ids expanded :file-diffs file-diffs))
                 (diff-entries (remove-if-not (lambda (e) (eq (fourth e) :diff-line)) entries)))
            ;; 200 real lines + 1 trailing "more" row.
            (expect (= 201 (length diff-entries)))
            (expect (search "more lines" (second (car (last diff-entries)))))
            (expect (search "50" (second (car (last diff-entries)))))
            (expect (equal (list :diff-more wt-id "src/foo.lisp")
                           (third (car (last diff-entries)))))))))

    (it "shows a refreshing placeholder while :pending and UNKNOWN while :failed"
      (multiple-value-bind (organization repository worktree)
          (%build-diff-fixture)
        (declare (ignore repository))
        (let ((expanded (make-hash-table :test #'equal))
              (file-diffs (make-hash-table :test #'equal))
              (wt-id (nerimux/workspace-model:worktree-id worktree)))
          (setf (gethash (list :worktree wt-id) expanded) t)
          (setf (gethash (list :file-diff wt-id "src/foo.lisp") expanded) t)
          (setf (gethash (list wt-id "src/foo.lisp") file-diffs) (list :pending 0 nil))
          (let ((entries
                  (nerimux/renderer::%workspace-flat-tree-entries
                   (list organization) nil
                   :expanded-node-ids expanded :file-diffs file-diffs)))
            (expect (search "diff: refreshing"
                            (second (find :diff-line entries :key #'fourth)))))
          (setf (gethash (list wt-id "src/foo.lisp") file-diffs) (list :failed 0 nil))
          (let ((entries
                  (nerimux/renderer::%workspace-flat-tree-entries
                   (list organization) nil
                   :expanded-node-ids expanded :file-diffs file-diffs)))
            (expect (search "diff: UNKNOWN"
                            (second (find :diff-line entries :key #'fourth))))))))

    (it "shows an untracked placeholder instead of a cache lookup for a ?? file, even with no cache entry"
      (multiple-value-bind (organization repository worktree)
          (%build-diff-fixture :code "??" :path "new.txt")
        (declare (ignore repository))
        (let ((expanded (make-hash-table :test #'equal))
              (wt-id (nerimux/workspace-model:worktree-id worktree)))
          (setf (gethash (list :worktree wt-id) expanded) t)
          (setf (gethash (list :file-diff wt-id "new.txt") expanded) t)
          (let* ((entries
                   (nerimux/renderer::%workspace-flat-tree-entries
                    (list organization) nil :expanded-node-ids expanded))
                 (diff-entries (remove-if-not (lambda (e) (eq (fourth e) :diff-line)) entries)))
            (expect (= 1 (length diff-entries)))
            (expect (string= "(untracked file)" (second (first diff-entries))))
            (expect (equal (list :diff-line wt-id "new.txt" :untracked)
                           (third (first diff-entries))))))))

    (it "shows no diff rows at all while the file itself is not expanded"
      (multiple-value-bind (organization repository worktree)
          (%build-diff-fixture)
        (declare (ignore repository))
        (let ((expanded (make-hash-table :test #'equal))
              (file-diffs (make-hash-table :test #'equal))
              (wt-id (nerimux/workspace-model:worktree-id worktree)))
          (setf (gethash (list :worktree wt-id) expanded) t)
          (setf (gethash (list wt-id "src/foo.lisp") file-diffs)
                (list :ready 1 (list "+a line")))
          (let ((entries
                  (nerimux/renderer::%workspace-flat-tree-entries
                   (list organization) nil
                   :expanded-node-ids expanded :file-diffs file-diffs)))
            (expect (null (find :diff-line entries :key #'fourth)))))))

    ;; The ANSI render path (renderer-workspace.lisp's TREE-ROW-TEXT) is the
    ;; only one that colours tree rows at all (see renderer-workspace-tree's
    ;; own file header on why the cl-tui-kit widget path does not) -- same
    ;; rationale the Dracula-colour test above uses for +SGR-SECTION+.
    (it "colours diff lines by their leading character: + ok, - alert, @@ accent"
      (multiple-value-bind (organization repository worktree)
          (%build-diff-fixture)
        (declare (ignore repository))
        (let ((expanded (make-hash-table :test #'equal))
              (file-diffs (make-hash-table :test #'equal))
              (wt-id (nerimux/workspace-model:worktree-id worktree)))
          (setf (gethash (list :worktree wt-id) expanded) t)
          (setf (gethash (list :file-diff wt-id "src/foo.lisp") expanded) t)
          (setf (gethash (list wt-id "src/foo.lisp") file-diffs)
                (list :ready 3
                      (list "@@ -1,2 +1,2 @@" "-removed line" "+added line")))
          (let ((frame
                  (nerimux/renderer:render-workspace-overview-to-string
                   (list organization) 24 100
                   :expanded-node-ids expanded :file-diffs file-diffs)))
            (expect frame :to-contain-sgr nerimux/renderer::+sgr-ok+)
            (expect frame :to-contain-sgr nerimux/renderer::+sgr-alert+)
            (expect frame :to-contain-sgr nerimux/renderer::+sgr-accent+)))))))
