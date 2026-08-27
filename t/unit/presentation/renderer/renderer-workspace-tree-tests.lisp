(in-package #:nerimux/test)

;;;; Direct unit tests for %WORKSPACE-FLAT-TREE-ENTRIES / %WORKSPACE-NODE-
;;;; EXPANDED-P / %WORKSPACE-NODE-REFRESH-TAG (renderer-workspace-tree.lisp), the
;;;; R6.2/R6.3 tree contract:
;;;;
;;;;   - 5 levels: organization -> repository -> worktree -> window -> pane.
;;;;   - Initial state is fully collapsed: only organization rows show.
;;;;   - Enter on an organization/repository row toggles that row's expansion
;;;;     (worktree/window/pane rows have no collapse state of their own; once
;;;;     both ancestors are expanded, everything under a worktree shows).
;;;;   - Expansion is keyed by (KIND . stable ID) in an external hash table
;;;;     the caller owns, not by object identity, so it survives being handed
;;;;     a freshly-scanned tree after a refresh (R6.3: "開閉状態はrefreshを
;;;;     またいで保つ").
;;;;   - Refresh state (R6.2) is a second, independent per-row tag.

(defun %build-five-level-tree ()
  "One organization -> one repository -> one worktree -> two windows (one
   with two panes, one with one pane). Returns (VALUES ORGANIZATION REPOSITORY
   WORKTREE WINDOW-1 WINDOW-2)."
  (let* ((pane-1 (nerimux/model:make-pane :id 1 :fd -1 :title "shell"))
         (pane-2 (nerimux/model:make-pane :id 2 :fd -1 :title "test"))
         (pane-3 (nerimux/model:make-pane :id 3 :fd -1 :title "logs"))
         (window-1 (nerimux/model:make-window :id 1 :name "feature/tree"
                                              :panes (list pane-1 pane-2)))
         (window-2 (nerimux/model:make-window :id 2 :name "feature/tree (2)"
                                              :panes (list pane-3)))
         (worktree (nerimux/model:make-worktree
                    :id "wt-1" :path "/repo/wt" :branch "feature/tree"))
         (repository (nerimux/model:make-repository
                      :id "repo-1" :specification "github.com/team/tree"
                      :local-path "/repo" :worktrees (list worktree)))
         (organization (nerimux/model:make-organization
                        :id "github.com/team" :host "github.com" :name "team"
                        :repositories (list repository))))
    (setf (nerimux/model:pane-window pane-1) window-1
          (nerimux/model:pane-window pane-2) window-1
          (nerimux/model:pane-window pane-3) window-2)
    (nerimux/model:worktree-add-pane worktree pane-1)
    (nerimux/model:worktree-add-pane worktree pane-2)
    (nerimux/model:worktree-add-pane worktree pane-3)
    (values organization repository worktree window-1 window-2)))

(defun %tree-entry-kinds (entries)
  (mapcar #'fourth entries))

(describe "renderer-suite/workspace-tree-collapse"

  ;; PR2 polarity inversion: the tree's default state (no COLLAPSED-NODE-IDS
  ;; at all, the NIL a freshly-attached client starts with) shows the WHOLE
  ;; depth -- organization -> repository -> worktree -> window -> pane --
  ;; the opposite of the pre-PR2 collapsed-by-default contract this replaces.
  (it "shows the full tree depth when nothing is collapsed"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let ((entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil)))
        (expect (equal '(:organization :repository :worktree
                         :window :pane :pane :window :pane)
                       (%tree-entry-kinds entries))))))

  ;; Collapsing the organization hides everything under it -- its repository
  ;; row included, since a repository row is only ever emitted when its
  ;; owning organization is not collapsed.
  (it "collapsing the organization hides its repository and everything under it"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((collapsed (make-hash-table :test #'equal)))
        (setf (gethash (list :organization (nerimux/model:organization-id organization))
                       collapsed)
              t)
        (let ((entries
                (nerimux/renderer::%workspace-flat-tree-entries
                 (list organization) collapsed)))
          (expect (equal '(:organization) (%tree-entry-kinds entries)))))))

  ;; Collapsing only the repository keeps the organization and repository
  ;; rows (the organization is not collapsed) but hides the worktree/window/
  ;; pane rows beneath the repository.
  (it "collapsing the repository hides worktree, window, and pane rows"
    (multiple-value-bind (organization repository) (%build-five-level-tree)
      (let* ((collapsed (make-hash-table :test #'equal)))
        (setf (gethash (list :repository (nerimux/model:repository-id repository))
                       collapsed)
              t)
        (let* ((entries
                 (nerimux/renderer::%workspace-flat-tree-entries
                  (list organization) collapsed))
               (kinds (%tree-entry-kinds entries)))
          (expect (equal '(:organization :repository) kinds))
          (expect (null (find :window entries :key #'fourth)))))))

  ;; Round trip: removing a collapse entry (Enter's toggle, from the caller's
  ;; side) restores the full depth the same table showed before the entry
  ;; was added.
  (it "restores full depth when a collapse entry is removed"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((key (list :organization (nerimux/model:organization-id organization)))
             (collapsed (make-hash-table :test #'equal)))
        (setf (gethash key collapsed) t)
        (expect (equal '(:organization)
                       (%tree-entry-kinds
                        (nerimux/renderer::%workspace-flat-tree-entries
                         (list organization) collapsed))))
        (remhash key collapsed)
        (expect (equal '(:organization :repository :worktree
                         :window :pane :pane :window :pane)
                       (%tree-entry-kinds
                        (nerimux/renderer::%workspace-flat-tree-entries
                         (list organization) collapsed)))))))

  ;; R6.3: collapse state is keyed by stable ID, not by EQ object identity, so
  ;; it survives a refresh that hands the renderer a brand-new organization/
  ;; repository struct sharing the same IDs -- the same hash table, reused
  ;; across "generations" of the scanned catalog, still finds its entries.
  (it "keeps collapse state across a refresh that rebuilds the tree with the same IDs"
    (multiple-value-bind (organization repository worktree) (%build-five-level-tree)
      (declare (ignore worktree))
      (let* ((collapsed (make-hash-table :test #'equal)))
        (setf (gethash (list :repository (nerimux/model:repository-id repository))
                       collapsed)
              t)
        ;; Simulate a refresh: a new organization/repository/worktree tree
        ;; with the SAME stable IDs as before, but different (non-EQ) structs
        ;; -- exactly what NERIMUX/VCS:LIST-REPOSITORY-WORKTREES produces
        ;; each scan (see vcs.lisp:227-292, which never reuses the old
        ;; worktree struct).
        (let* ((new-worktree
                 (nerimux/model:make-worktree
                  :id "wt-1" :path "/repo/wt" :branch "feature/tree"))
               (new-repository
                 (nerimux/model:make-repository
                  :id "repo-1" :specification "github.com/team/tree"
                  :local-path "/repo" :worktrees (list new-worktree)))
               (new-organization
                 (nerimux/model:make-organization
                  :id "github.com/team" :host "github.com" :name "team"
                  :repositories (list new-repository))))
          (expect (not (eq new-repository repository)))
          (let ((kinds
                  (%tree-entry-kinds
                   (nerimux/renderer::%workspace-flat-tree-entries
                    (list new-organization) collapsed))))
            (expect (equal '(:organization :repository) kinds))))))))

(describe "renderer-suite/workspace-tree-refresh-tags"

  ;; R6.2: a row being refreshed carries a " refreshing" suffix; a row whose
  ;; last refresh failed carries " stale" instead. Neither tag is present
  ;; when the row is in neither table.
  (it "appends refreshing/stale suffixes to organization and repository labels"
    (multiple-value-bind (organization repository) (%build-five-level-tree)
      (let* ((org-id (nerimux/model:organization-id organization))
             (repo-id (nerimux/model:repository-id repository))
             (refreshing (make-hash-table :test #'equal))
             (stale (make-hash-table :test #'equal))
             ;; Nothing collapsed here (PR2 default-expanded polarity): the
             ;; organization and repository rows must both stay visible for
             ;; the assertions below to check anything real.
             (collapsed-node-ids (make-hash-table :test #'equal)))
        (setf (gethash (list :organization org-id) refreshing) t)
        (setf (gethash (list :repository repo-id) stale) t)
        (let ((entries
                (nerimux/renderer::%workspace-flat-tree-entries
                 (list organization) collapsed-node-ids
                 :refreshing-ids refreshing :stale-ids stale)))
          ;; Each entry is (LEVEL LABEL OBJECT KIND) -- LABEL is SECOND.
          (expect (search " refreshing" (second (first entries))))
          (expect (search " stale" (second (second entries))))))))

  ;; Refreshing wins over stale when a row is (transiently) in both tables.
  (it "prefers refreshing over stale when both apply to the same row"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((org-id (nerimux/model:organization-id organization))
             (refreshing (make-hash-table :test #'equal))
             (stale (make-hash-table :test #'equal)))
        (setf (gethash (list :organization org-id) refreshing) t)
        (setf (gethash (list :organization org-id) stale) t)
        (expect (string= " refreshing"
                         (nerimux/renderer::%workspace-node-refresh-tag
                          :organization org-id refreshing stale))))))

  ;; Window/pane rows never carry a refresh tag -- a VCS refresh has no
  ;; notion of a window or pane, only organization/repository/worktree.
  ;; PR2 note: under the old EXPANDED-NODE-IDS polarity, marking organization
  ;; and repository "expanded" (as this test used to) revealed the window
  ;; row. Under the new COLLAPSED-NODE-IDS polarity, marking those SAME two
  ;; keys present in the argument this function now takes as its collapse
  ;; table COLLAPSES them instead -- the org row's children (repository,
  ;; worktree, window, pane) never get emitted at all, WINDOW-ENTRY comes
  ;; back NIL, and (search " refreshing" (second nil)) is (search ... nil),
  ;; which returns NIL unconditionally -- so (not ...) is always true and the
  ;; assertion passed whether or not the tag logic worked. Nothing must be
  ;; collapsed here for the window row to exist to test against in the first
  ;; place; the explicit WINDOW-ENTRY precondition check below is what turns
  ;; that silent vacuity into a hard failure if it recurs.
  (it "never tags window or pane rows even when everything is refreshing"
    (multiple-value-bind (organization repository worktree window-1)
        (%build-five-level-tree)
      (declare (ignore repository worktree))
      (let* ((refreshing (make-hash-table :test #'equal))
             (collapsed-node-ids (make-hash-table :test #'equal)))
        (dolist (kind '(:organization :repository :worktree :window :pane))
          (setf (gethash (list kind "anything") refreshing) t))
        (let* ((entries
                 (nerimux/renderer::%workspace-flat-tree-entries
                  (list organization) collapsed-node-ids :refreshing-ids refreshing))
               (window-entry (find window-1 entries :key #'third)))
          ;; Precondition: the window row must actually be present, or the
          ;; assertion below would vacuously pass against a NIL WINDOW-ENTRY.
          (expect window-entry)
          (expect (not (search " refreshing" (second window-entry)))))))))

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
;;; is for.

(describe "renderer-suite/workspace-tree-filter"

  ;; A filter matching one pane's title keeps that pane, its owning window
  ;; (ancestor), worktree, repository, and organization -- but prunes the
  ;; sibling window/pane that do not match.
  (it "keeps a matching pane and its ancestors, prunes non-matching siblings"
    (multiple-value-bind (organization repository worktree window-1 window-2)
        (%build-five-level-tree)
      (declare (ignore repository worktree window-2))
      (let* ((entries
               (nerimux/renderer::%workspace-flat-tree-entries
                (list organization) nil :filter "test"))
             (kinds (%tree-entry-kinds entries))
             (objects (mapcar #'third entries)))
        (expect (equal '(:organization :repository :worktree :window :pane) kinds))
        (expect (member window-1 objects :test #'eq))
        (expect (string= "pane/2 test" (second (find :pane entries :key #'fourth)))))))

  ;; Case-insensitive: an uppercase query matches a lowercase pane title.
  (it "matches case-insensitively"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let ((entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil :filter "TEST")))
        (expect (find :pane entries :key #'fourth)))))

  ;; NIL or an all-blank filter is treated as "no filter": every row survives.
  (it "returns every row unchanged for a NIL or all-blank filter"
    (multiple-value-bind (organization) (%build-five-level-tree)
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
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let ((entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil :filter "no-such-match-anywhere")))
        (expect (null entries)))))

  ;; Review-round fix: search penetrates collapse. Collapsing the repository
  ;; hides everything under it when no filter is active (confirmed first, so
  ;; the second half actually proves something) -- but once a filter matches
  ;; a descendant pane, that pane and every ancestor down to the collapsed
  ;; repository must reappear regardless of the collapse entry.
  (it "search penetrates a collapsed repository -- a matching descendant and its ancestors still appear"
    (multiple-value-bind (organization repository worktree window-1)
        (%build-five-level-tree)
      (declare (ignore worktree))
      (let ((collapsed (make-hash-table :test #'equal)))
        (setf (gethash (list :repository (nerimux/model:repository-id repository))
                       collapsed)
              t)
        (expect (equal '(:organization :repository)
                       (%tree-entry-kinds
                        (nerimux/renderer::%workspace-flat-tree-entries
                         (list organization) collapsed))))
        (let* ((entries
                 (nerimux/renderer::%workspace-flat-tree-entries
                  (list organization) collapsed :filter "test"))
               (kinds (%tree-entry-kinds entries))
               (objects (mapcar #'third entries)))
          (expect (equal '(:organization :repository :worktree :window :pane) kinds))
          (expect (member window-1 objects :test #'eq)))))))

;;; PR2 window-row omission: a worktree's window row (level 3) is only drawn
;;; when it holds 2 or more distinct windows; with exactly one window, that
;;; window contributes no row of its own and its panes attach directly under
;;; the worktree at level 3 instead of level 4.

(describe "renderer-suite/workspace-tree-window-row-omission"

  (it "omits the window row and attaches panes at level 3 when a worktree has one window"
    (let* ((pane-1 (nerimux/model:make-pane :id 1 :fd -1 :title "solo-a"))
           (pane-2 (nerimux/model:make-pane :id 2 :fd -1 :title "solo-b"))
           (window (nerimux/model:make-window
                    :id 1 :name "solo" :panes (list pane-1 pane-2)))
           (worktree
             (nerimux/model:make-worktree
              :id "wt-solo" :path "/repo/solo" :branch "solo"))
           (repository
             (nerimux/model:make-repository
              :id "repo-solo" :specification "github.com/team/solo"
              :local-path "/repo" :worktrees (list worktree)))
           (organization
             (nerimux/model:make-organization
              :id "github.com/team-solo" :host "github.com" :name "team-solo"
              :repositories (list repository))))
      (setf (nerimux/model:pane-window pane-1) window
            (nerimux/model:pane-window pane-2) window)
      (nerimux/model:worktree-add-pane worktree pane-1)
      (nerimux/model:worktree-add-pane worktree pane-2)
      (let* ((entries
               (nerimux/renderer::%workspace-flat-tree-entries
                (list organization) nil))
             (pane-entries (remove-if-not (lambda (e) (eq (fourth e) :pane)) entries)))
        (expect (null (find :window entries :key #'fourth)))
        (expect (= 2 (length pane-entries)))
        (expect (every (lambda (e) (= 3 (first e))) pane-entries)))))

  (it "draws the window row and attaches panes at level 4 when a worktree has two windows"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((entries
               (nerimux/renderer::%workspace-flat-tree-entries
                (list organization) nil))
             (window-entries (remove-if-not (lambda (e) (eq (fourth e) :window)) entries))
             (pane-entries (remove-if-not (lambda (e) (eq (fourth e) :pane)) entries)))
        (expect (= 2 (length window-entries)))
        (expect (every (lambda (e) (= 3 (first e))) window-entries))
        (expect (= 3 (length pane-entries)))
        (expect (every (lambda (e) (= 4 (first e))) pane-entries))))))

;;; PR2 worktree-row info cluster: state tag, ahead/behind, pane count, and a
;;; relative last-activity time, in that priority order.

(describe "renderer-suite/workspace-tree-info-cluster"

  ;; A fixed worktree: ahead 2, dirty, 2 panes with one exited, and a known
  ;; last-output-time 5 minutes in the past. All four fields must appear in
  ;; the rendered (SGR-stripped) tree row.
  (it "shows ahead count, pane count with exit marker, state tag, and relative time"
    (let* ((pane-1 (nerimux/model:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/model:make-pane :id 2 :fd -1 :process-exited-p t))
           ;; %WORKTREE-TREE-WINDOWS (called while flattening the tree) sorts
           ;; WORKTREE-PANES by their owning window's id, so every pane here
           ;; needs a real WINDOW -- a pane with no window at all is a type
           ;; error there, not just an incomplete fixture.
           (window
             (nerimux/model:make-window
              :id 1 :name "info" :panes (list pane-1 pane-2)))
           (worktree
             (nerimux/model:make-worktree
              :id "wt-info" :path "/repo/info" :branch "info"
              :status t :dirty-p t :ahead 2))
           (repository
             (nerimux/model:make-repository
              :id "repo-info" :specification "github.com/team/info"
              :local-path "/repo" :worktrees (list worktree)))
           (organization
             (nerimux/model:make-organization
              :id "github.com/team-info" :host "github.com" :name "team-info"
              :repositories (list repository))))
      (setf (nerimux/model:pane-window pane-1) window
            (nerimux/model:pane-window pane-2) window)
      (nerimux/model:worktree-add-pane worktree pane-1)
      (nerimux/model:worktree-add-pane worktree pane-2)
      (setf (nerimux/model:pane-last-output-time pane-1)
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

;;; PR2 tree row budget: WORKSPACE-TREE-VIEW-ROWS reserves 6 rows around the
;;; tree (header/separator/detail x2/message/footer), floored at 1.

(describe "renderer-suite/workspace-tree-view-rows"

  (it "reserves exactly 6 rows around the tree"
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 7)))
    (expect (= 24 (nerimux/renderer:workspace-tree-view-rows 30))))

  ;; The floor at 1 kicks in for any terminal too short to spare the full 6
  ;; rows, rather than going negative or zero.
  (it "floors at 1 row for a terminal shorter than the reserved 6 rows"
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 6)))
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 1)))
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 0)))))

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
