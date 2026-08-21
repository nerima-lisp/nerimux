(in-package #:nerimux/test)

;;;; Direct unit tests for %WORKSPACE-FLAT-TREE-ENTRIES / %WORKSPACE-NODE-
;;;; EXPANDED-P / %WORKSPACE-NODE-REFRESH-TAG (renderer-workspace.lisp), the
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

  ;; R6.3: the tree's default state (no EXPANDED-NODE-IDS at all, the NIL a
  ;; freshly-attached client starts with) shows only organization rows.
  (it "shows only the organization row when nothing is expanded"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let ((entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil)))
        (expect (equal '(:organization) (%tree-entry-kinds entries))))))

  ;; Expanding only the organization row reveals its repositories, but not
  ;; yet the worktree/window/pane rows underneath (those wait on the
  ;; repository row's own expansion).
  (it "expanding the organization reveals repositories, not worktrees"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((expanded (make-hash-table :test #'equal)))
        (setf (gethash (list :organization (nerimux/model:organization-id organization))
                       expanded)
              t)
        (let ((entries
                (nerimux/renderer::%workspace-flat-tree-entries
                 (list organization) expanded)))
          (expect (equal '(:organization :repository) (%tree-entry-kinds entries)))))))

  ;; Expanding both organization and repository reveals the full depth:
  ;; worktree -> window -> window -> pane -> pane -> pane, in that order
  ;; (window/pane rows carry no collapse state of their own -- R6.3).
  (it "expanding organization and repository reveals worktree, window, and pane rows"
    (multiple-value-bind (organization repository) (%build-five-level-tree)
      (let* ((expanded (make-hash-table :test #'equal)))
        (setf (gethash (list :organization (nerimux/model:organization-id organization))
                       expanded)
              t)
        (setf (gethash (list :repository (nerimux/model:repository-id repository))
                       expanded)
              t)
        (let* ((entries
                 (nerimux/renderer::%workspace-flat-tree-entries
                  (list organization) expanded))
               (kinds (%tree-entry-kinds entries)))
          (expect (equal '(:organization :repository :worktree
                           :window :pane :pane :window :pane)
                         kinds))
          ;; The two window rows carry the R5.8 branch+sequence-number name.
          (let ((window-labels
                  (mapcar #'second (remove-if-not (lambda (e) (eq (fourth e) :window))
                                                  entries))))
            (expect (equal '("win 1:feature/tree" "win 2:feature/tree (2)")
                           window-labels)))
          ;; Pane rows carry "pane/N title".
          (let ((pane-labels
                  (mapcar #'second (remove-if-not (lambda (e) (eq (fourth e) :pane))
                                                  entries))))
            (expect (equal '("pane/1 shell" "pane/2 test" "pane/3 logs")
                           pane-labels)))))))

  ;; Enter toggles: pressing it again on an already-expanded organization row
  ;; collapses it back to organization-only. The renderer has no notion of
  ;; "Enter" itself (that is a caller/dispatch concern, out of this file's
  ;; scope) but the collapse round-trip through the same hash table it is
  ;; handed is exactly what the caller's toggle must produce.
  (it "collapses back to organization-only when the expansion entry is removed"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((key (list :organization (nerimux/model:organization-id organization)))
             (expanded (make-hash-table :test #'equal)))
        (setf (gethash key expanded) t)
        (expect (equal '(:organization :repository)
                       (%tree-entry-kinds
                        (nerimux/renderer::%workspace-flat-tree-entries
                         (list organization) expanded))))
        (remhash key expanded)
        (expect (equal '(:organization)
                       (%tree-entry-kinds
                        (nerimux/renderer::%workspace-flat-tree-entries
                         (list organization) expanded)))))))

  ;; R6.3: expansion is keyed by stable ID, not by EQ object identity, so it
  ;; survives a refresh that hands the renderer a brand-new organization/
  ;; repository struct sharing the same IDs -- the same hash table, reused
  ;; across "generations" of the scanned catalog, still finds its entries.
  (it "keeps expansion across a refresh that rebuilds the tree with the same IDs"
    (multiple-value-bind (organization repository worktree) (%build-five-level-tree)
      (declare (ignore worktree))
      (let* ((expanded (make-hash-table :test #'equal)))
        (setf (gethash (list :organization (nerimux/model:organization-id organization))
                       expanded)
              t)
        (setf (gethash (list :repository (nerimux/model:repository-id repository))
                       expanded)
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
                    (list new-organization) expanded))))
            (expect (equal '(:organization :repository :worktree) kinds))))))))

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
             (expanded (make-hash-table :test #'equal)))
        (setf (gethash (list :organization org-id) expanded) t)
        (setf (gethash (list :organization org-id) refreshing) t)
        (setf (gethash (list :repository repo-id) stale) t)
        (let ((entries
                (nerimux/renderer::%workspace-flat-tree-entries
                 (list organization) expanded
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
  (it "never tags window or pane rows even when everything is refreshing"
    (multiple-value-bind (organization repository worktree window-1)
        (%build-five-level-tree)
      (declare (ignore repository worktree))
      (let* ((refreshing (make-hash-table :test #'equal))
             (expanded (make-hash-table :test #'equal)))
        (dolist (kind '(:organization :repository :worktree :window :pane))
          (setf (gethash (list kind "anything") refreshing) t))
        (setf (gethash (list :organization (nerimux/model:organization-id organization))
                       expanded)
              t)
        (setf (gethash (list :repository "repo-1") expanded) t)
        (let* ((entries
                 (nerimux/renderer::%workspace-flat-tree-entries
                  (list organization) expanded :refreshing-ids refreshing))
               (window-entry (find window-1 entries :key #'third)))
          (expect (not (search " refreshing" (second window-entry)))))))))

(describe "renderer-suite/workspace-scanning-placeholder"

  ;; R6.2: while the initial ghq/worktree scan is still running, the whole
  ;; frame is replaced by an empty tree plus a centred "scanning..." message
  ;; -- no header, no tree box, nothing that implies data has loaded.
  (it "shows only scanning... while the initial catalog scan is still running"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :scanning-p t)))
      (expect (search "scanning..." frame))
      (expect (not (search "WORKSPACES" frame)))))

  ;; Once organizations exist, scanning-p no longer applies even if left T --
  ;; the guard is specifically "still scanning AND nothing has arrived yet".
  (it "renders the ordinary tree once organizations have arrived, even if scanning-p lingers"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let ((frame
              (nerimux/renderer:render-workspace-overview-to-string
               (list organization) 24 80 :scanning-p t)))
        (expect (search "WORKSPACES" frame))
        (expect (not (search "scanning..." frame)))))))
