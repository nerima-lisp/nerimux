(in-package #:nerimux/test/renderer)

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
