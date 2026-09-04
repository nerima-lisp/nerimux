(in-package #:nerimux/test/renderer)

(defun %build-five-level-tree ()
  "One organization -> one repository -> one worktree -> two windows (one
   with two panes, one with one pane). Returns (VALUES ORGANIZATION REPOSITORY
   WORKTREE WINDOW-1 WINDOW-2)."
  (let* ((pane-1 (nerimux/pane:make-pane :id 1 :fd -1 :title "shell"))
         (pane-2 (nerimux/pane:make-pane :id 2 :fd -1 :title "test"))
         (pane-3 (nerimux/pane:make-pane :id 3 :fd -1 :title "logs"))
         (window-1
          (nerimux/window:make-window :id
                                      1
                                      :name
                                      "feature/tree"
                                      :panes
                                      (list pane-1 pane-2)))
         (window-2
          (nerimux/window:make-window :id
                                      2
                                      :name
                                      "feature/tree (2)"
                                      :panes
                                      (list pane-3)))
         (worktree
          (nerimux/workspace-model:make-worktree :id
                                                 "wt-1"
                                                 :path
                                                 "/repo/wt"
                                                 :branch
                                                 "feature/tree"))
         (repository
          (nerimux/workspace-model:make-repository :id
                                                   "repo-1"
                                                   :specification
                                                   "github.com/team/tree"
                                                   :local-path
                                                   "/repo"
                                                   :worktrees
                                                   (list worktree)))
         (organization
          (nerimux/workspace-model:make-organization :id
                                                     "github.com/team"
                                                     :host
                                                     "github.com"
                                                     :name
                                                     "team"
                                                     :repositories
                                                     (list repository))))
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
  (let* ((worktree
          (nerimux/workspace-model:make-worktree :id
                                                 "wt-section"
                                                 :path
                                                 "/repo/wt"
                                                 :branch
                                                 "feature/section"
                                                 :dirty-p
                                                 attention-p))
         (repository
          (nerimux/workspace-model:make-repository :id
                                                   "repo-section"
                                                   :specification
                                                   "github.com/team/section"
                                                   :local-path
                                                   "/repo"
                                                   :worktrees
                                                   (list worktree)))
         (organization
          (nerimux/workspace-model:make-organization :id
                                                     "github.com/team-section"
                                                     :host
                                                     "github.com"
                                                     :name
                                                     "team-section"
                                                     :repositories
                                                     (list repository))))
    (when pane-p
      (let* ((pane (nerimux/pane:make-pane :id 1 :fd -1))
             (window
              (nerimux/window:make-window :id 1 :name "w" :panes (list pane))))
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
          (nerimux/workspace-model:make-worktree :id
                                                 "wt-match"
                                                 :path
                                                 "/repo/match"
                                                 :branch
                                                 "only-match"
                                                 :dirty-p
                                                 t))
         (match-repo
          (nerimux/workspace-model:make-repository :id
                                                   "repo-match"
                                                   :specification
                                                   "github.com/team/match"
                                                   :local-path
                                                   "/repo/match"
                                                   :worktrees
                                                   (list match-worktree)))
         (other-worktree
          (nerimux/workspace-model:make-worktree :id
                                                 "wt-other"
                                                 :path
                                                 "/repo/other"
                                                 :branch
                                                 "buried-worktree"))
         (other-repo
          (nerimux/workspace-model:make-repository :id
                                                   "repo-other"
                                                   :specification
                                                   "github.com/team/other"
                                                   :local-path
                                                   "/repo/other"
                                                   :worktrees
                                                   (list other-worktree)))
         (organization
          (nerimux/workspace-model:make-organization :id
                                                     "github.com/team-filter"
                                                     :host
                                                     "github.com"
                                                     :name
                                                     "team-filter"
                                                     :repositories
                                                     (list match-repo
                                                           other-repo))))
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
          (expect (search " refreshing" (second (second entries))))
          (expect (search " stale" (second (fourth entries))))))))

  (it "prefers refreshing over stale when both apply to the same row"
    (let ((refreshing (make-hash-table :test #'equal))
          (stale (make-hash-table :test #'equal)))
      (setf (gethash (list :worktree "wt-both") refreshing) t)
      (setf (gethash (list :worktree "wt-both") stale) t)
      (expect (string= " refreshing"
                       (nerimux/renderer::%workspace-node-refresh-tag
                        :worktree "wt-both" refreshing stale))))))

(describe "renderer-suite/workspace-scanning-placeholder"

  (it "shows only the scanning message while the initial catalog scan is still running"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :scanning-p t)))
      (expect (search "scanning workspaces..." frame))
      (expect (not (search " nerimux " frame)))))

  (it "renders the ordinary tree once organizations have arrived, even if scanning-p lingers"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let ((frame
              (nerimux/renderer:render-workspace-overview-to-string
               (list organization) 24 80 :scanning-p t)))
        (expect (search " nerimux " frame))
        (expect (not (search "scanning workspaces..." frame))))))

  (it "shows the repository count in the scanning message when scan-progress is a positive integer"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :scanning-p t :scan-progress 12)))
      (expect (search "scanning workspaces... 12 repositories" frame))))

  (it "keeps the plain ellipsis wording when scan-progress is nil"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :scanning-p t :scan-progress nil)))
      (expect (search "scanning workspaces..." frame))
      (expect (not (search "repositories" frame))))))

(describe "renderer-suite/workspace-catalog-empty-hint"

  (it "shows the no-repositories-found guide with the ghq root when the catalog is empty"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :catalog-empty-hint "/tmp/ghq")))
      (expect (search "no repositories found" frame))
      (expect (search "/tmp/ghq" frame))
      (expect (search "ghq get <owner>/<repo>" frame))))

  (it "does not show the empty-catalog hint while a scan is running"
    (let ((frame
            (nerimux/renderer:render-workspace-overview-to-string
             nil 24 80 :scanning-p t :catalog-empty-hint "/tmp/ghq")))
      (expect (not (search "no repositories found" frame))))))

(describe "renderer-suite/workspace-tree-filter"

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

  (it "matches case-insensitively"
    (multiple-value-bind (organization) (%build-filter-fixture)
      (let ((entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil :filter "ONLY-MATCH")))
        (expect (find :worktree entries :key #'fourth)))))

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

  (it "returns no rows for a filter matching nothing"
    (multiple-value-bind (organization) (%build-filter-fixture)
      (let ((entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil :filter "no-such-match-anywhere")))
        (expect (null entries)))))

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

  (it "shows a bare / prompt when mode is :filter and tree-filter is empty"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((frame
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization) 24 100
                :mode :filter :tree-filter ""))
             (plain (strip-sgr frame)))
        (expect (search "/" plain))
        (expect (not (search "detach" plain)))))))

(describe "renderer-suite/workspace-tree-info-cluster"

  (it "shows ahead count, pane count with exit marker, state tag, and relative time"
    (let* ((pane-1 (nerimux/pane:make-pane :id 1 :fd -1))
           (pane-2 (nerimux/pane:make-pane :id 2 :fd -1 :process-exited-p t))
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

  (it "switches relative-time buckets at the 60s/3600s/86400s boundaries"
    (flet ((relative (delta)
             (nerimux/renderer::%worktree-relative-time-text
              (- (get-universal-time) delta))))
      (expect (string= "now" (relative 59)))
      (expect (string= "1m" (relative 60)))
      (expect (string= "59m" (relative 3599)))
      (expect (string= "1h" (relative 3600)))
      (expect (string= "1d" (relative 86400)))))

  (it "returns NIL for a worktree with no pane activity at all"
    (expect (null (nerimux/renderer::%worktree-relative-time-text nil)))))

(describe "renderer-suite/workspace-tree-dracula-colors"
          (it
           "renders a section header in +sgr-section+ and a worktree's ahead count in Dracula truecolour"
           (multiple-value-bind (organization repository worktree) 
               (%build-section-fixture :attention-p t :pane-p t)
             (declare (ignore repository))
             (setf (nerimux/workspace-model:worktree-ahead worktree) 1)
             (let ((frame
                    (nerimux/renderer:render-workspace-overview-to-string
                     (list organization)
                     24
                     100)))
               (expect frame :to-contain-sgr nerimux/renderer::+sgr-section+)
               (expect frame :to-contain-sgr nerimux/renderer::+sgr-ahead+)))))

(describe "renderer-suite/workspace-tree-no-matches"

  (it "shows a no-matches placeholder and no tree-row text when the filter matches nothing"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((frame
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization) 24 100 :tree-filter "zzz-no-match-anywhere"))
             (plain (strip-sgr frame)))
        (expect (search "no matches: /zzz-no-match-anywhere" plain))
        (expect (not (search "feature/tree" plain))))))

  (it "suppresses the tree widget so no organization label appears either"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((output
               (nerimux/renderer:render-workspace-overview-to-tui-string
                (list organization) 24 100 :tree-filter "zzz-no-match-anywhere"))
             (plain (strip-sgr output)))
        (expect (search "no matches: /zzz-no-match-anywhere" plain))
        (expect (not (search "github.com/team" plain)))))))

(describe "renderer-suite/workspace-tree-too-short"

  (it "shows a single too-short message instead of the ordinary layout below 7 rows"
    (multiple-value-bind (organization) (%build-five-level-tree)
      (let* ((frame
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization) 5 100 :selected-tree-object organization))
             (plain (strip-sgr frame)))
        (expect (search "terminal too short for panels" plain))
        (expect (not (search "feature/tree" plain)))
        (expect (not (search "(no selection)" plain)))
        (expect (not (search "organization:" plain)))))))
