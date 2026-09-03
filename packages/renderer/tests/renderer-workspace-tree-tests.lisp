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
      (expect (search "worktree menu" plain))
      (expect (not (search "shell(main)" plain)))
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
          (it
           "renders every repository health state in the selected detail panel"
           (multiple-value-bind (organization repository) 
               (%build-five-level-tree)
             (let ((states
                    (list
                     (list :missing
                           "MISSING"
                           (lambda ()
                             (setf (nerimux/workspace-model:repository-missing-p
                                    repository) t)))
                     (list :conflict
                           "CONFLICT"
                           (lambda ()
                             (setf (nerimux/workspace-model:repository-conflict-p
                                    repository) t)))
                     (list :dirty
                           "DIRTY"
                           (lambda ()
                             (setf (nerimux/workspace-model:repository-dirty-p
                                    repository) t)))
                     (list :no-worktree
                           "NO-WORKTREE"
                           (lambda ()
                             (setf (nerimux/workspace-model:repository-worktrees
                                    repository) nil)))
                     (list :ready "ready" nil))))
               (dolist (state states)
                 (setf (nerimux/workspace-model:repository-missing-p repository) nil
                       (nerimux/workspace-model:repository-conflict-p
                        repository) nil
                       (nerimux/workspace-model:repository-dirty-p repository) nil
                       (nerimux/workspace-model:repository-worktrees repository) (list
                                                                                  (nerimux/workspace-model:make-worktree
                                                                                   :id
                                                                                   "state-wt"
                                                                                   :path
                                                                                   "/wt")))
                 (when (third state)
                   (funcall (third state)))
                 (let ((plain
                        (strip-sgr
                         (nerimux/renderer:render-workspace-overview-to-string
                          (list organization)
                          24
                          100
                          :selected-tree-object
                          repository))))
                   (expect (search (second state) plain))))))))

(describe "renderer-suite/workspace-tree-projection-helpers"
          (it
           "uses stable identities for every model level and a generic fallback"
           (multiple-value-bind (organization repository worktree window-1) 
               (%build-five-level-tree)
             (let ((pane (first (nerimux/window:window-panes window-1))))
               (expect
                (equal '(:organization "github.com/team")
                       (nerimux/renderer::%workspace-tree-node-key organization)))
               (expect
                (equal '(:repository "repo-1")
                       (nerimux/renderer::%workspace-tree-node-key repository)))
               (expect
                (equal '(:worktree "wt-1")
                       (nerimux/renderer::%workspace-tree-node-key worktree)))
               (expect
                (equal '(:window 1)
                       (nerimux/renderer::%workspace-tree-node-key window-1)))
               (expect
                (equal '(:pane 1 1)
                       (nerimux/renderer::%workspace-tree-node-key pane)))
               (expect
                (equal '(:workspace-object :other)
                       (nerimux/renderer::%workspace-tree-node-key :other))))))
          (it
           "falls back to readable identifiers when labels lack descriptive data"
           (let ((organization
                  (nerimux/workspace-model:make-organization :id
                                                             "local-id"
                                                             :host
                                                             ""
                                                             :name
                                                             ""))
                 (repository
                  (nerimux/workspace-model:make-repository :id
                                                           "repo-id"
                                                           :specification
                                                           ""
                                                           :local-path
                                                           ""))
                 (worktree
                  (nerimux/workspace-model:make-worktree :id
                                                         "wt-id"
                                                         :path
                                                         ""
                                                         :branch
                                                         nil))
                 (pane
                  (nerimux/pane:make-pane :id
                                          7
                                          :fd
                                          -1
                                          :title
                                          ""
                                          :start-command
                                          "")))
             (expect
              (string= "local-id"
                       (nerimux/renderer::%organization-tree-label organization)))
             (expect
              (string= "repo-id"
                       (nerimux/renderer::%repository-tree-label repository)))
             (expect
              (string= "wt-id"
                       (nerimux/renderer::%worktree-tree-label worktree)))
             (expect
              (string= "pane/7 shell" (nerimux/renderer::%pane-tree-label pane)))))
          (it
           "prefers each available partial label before its identifier fallback"
           (let ((host-only
                  (nerimux/workspace-model:make-organization :id
                                                             "org-id"
                                                             :host
                                                             "git.example"
                                                             :name
                                                             ""))
                 (name-only
                  (nerimux/workspace-model:make-organization :id
                                                             "org-id"
                                                             :host
                                                             ""
                                                             :name
                                                             "team"))
                 (path-only
                  (nerimux/workspace-model:make-repository :id
                                                           "repo-id"
                                                           :specification
                                                           ""
                                                           :local-path
                                                           "/work/repo"))
                 (command-only
                  (nerimux/pane:make-pane :id
                                          7
                                          :fd
                                          -1
                                          :title
                                          ""
                                          :start-command
                                          "make test")))
             (expect
              (string= "git.example"
                       (nerimux/renderer::%organization-tree-label host-only)))
             (expect
              (string= "team"
                       (nerimux/renderer::%organization-tree-label name-only)))
             (expect
              (string= "/work/repo"
                       (nerimux/renderer::%repository-tree-label path-only)))
             (expect
              (string= "pane/7 make test"
                       (nerimux/renderer::%pane-tree-label command-only)))))
          (it "keeps only meaningful activity and info tokens"
              (let* ((worktree
                      (nerimux/workspace-model:make-worktree :id
                                                             "wt"
                                                             :path
                                                             "/tmp/wt"
                                                             :branch
                                                             "main"
                                                             :ahead
                                                             0
                                                             :behind
                                                             0))
                     (pane (nerimux/pane:make-pane :id 1 :fd -1)))
                (nerimux/pane:worktree-add-pane worktree pane)
                (expect
                 (null
                  (nerimux/renderer::%worktree-last-activity-time worktree)))
                (expect (nerimux/renderer::%worktree-tree-info-tokens worktree))
                (expect
                 (string= ""
                          (nerimux/renderer::%workspace-tree-node-search-text
                           :unknown
                           worktree)))))
          (it "uses a readable fallback for non-letter prefix bindings"
              (expect
               (string= "key/999"
                        (nerimux/renderer::%workspace-prefix-label 999))))
          (it "selects the newest output or focus timestamp"
              (multiple-value-bind (organization repository worktree window-1) 
                  (%build-five-level-tree)
                (declare (ignorable organization repository))
                (let ((pane-1 (first (nerimux/window:window-panes window-1)))
                      (pane-2 (second (nerimux/window:window-panes window-1))))
                  (setf (nerimux/pane:pane-last-output-time pane-1) 10
                        (nerimux/pane:pane-last-focused-time pane-2) 20)
                  (expect
                   (= 20
                      (nerimux/renderer::%worktree-last-activity-time worktree))))))
          (it "renders behind-only repository information"
              (let ((worktree
                     (nerimux/workspace-model:make-worktree :id "wt" :behind 2)))
                (multiple-value-bind (plain styled) 
                    (nerimux/renderer::%worktree-tree-info-suffix worktree 80)
                  (declare (ignore styled))
                  (expect (search "-2" plain))))))

(describe "renderer-suite/workspace-tree-view-rows"

  (it "reserves 6 rows around the tree below the key-panel height threshold"
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 7)))
    (expect (= 5 (nerimux/renderer:workspace-tree-view-rows 11))))

  (it "reserves 8 rows around the tree at and above the key-panel height threshold"
    (expect (= 4 (nerimux/renderer:workspace-tree-view-rows 12)))
    (expect (= 22 (nerimux/renderer:workspace-tree-view-rows 30))))

  (it "floors at 1 row for a terminal shorter than the reserved rows"
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 6)))
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 1)))
    (expect (= 1 (nerimux/renderer:workspace-tree-view-rows 0)))))

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
      (let ((collapsed-entries
              (nerimux/renderer::%workspace-flat-tree-entries
               (list organization) nil)))
        (expect (equal '(:section :worktree :section :repository)
                       (%tree-entry-kinds collapsed-entries))))
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
