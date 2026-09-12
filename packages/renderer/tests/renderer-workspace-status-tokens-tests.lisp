(in-package #:nerimux/test/renderer)

(describe "renderer-suite/workspace-status-tokens"

  (it "distinguishes an unfetched worktree (UNKNOWN) from a fetched clean one (CLEAN)"
    (let ((never-fetched
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"))
          (fetched-clean
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :status :fetched)))
      (expect (equal '("UNKNOWN")
                     (nerimux/renderer::%worktree-status-tokens never-fetched)))
      (expect (equal '("CLEAN")
                     (nerimux/renderer::%worktree-status-tokens fetched-clean)))
      (expect (string= "UNKNOWN"
                       (nerimux/renderer::%worktree-status-label never-fetched)))
      (expect (string= "CLEAN"
                       (nerimux/renderer::%worktree-status-label fetched-clean)))))

  (it "ignores stale health flags when status was never fetched"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :dirty-p t :ahead 5)))
      (expect (equal '("UNKNOWN")
                     (nerimux/renderer::%worktree-status-tokens worktree)))))

  (it "keeps the AHEAD/BEHIND counts instead of collapsing to a boolean"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :status :fetched :ahead 12 :behind 3)))
      (expect (equal '("AHEAD 12" "BEHIND 3")
                     (nerimux/renderer::%worktree-status-tokens worktree)))
      (expect (string= "AHEAD 12 BEHIND 3"
                       (nerimux/renderer::%worktree-status-label worktree)))))

  (it "shows non-zero diff line counts after the dirty/conflict tokens"
    (let ((worktree
            (nerimux/workspace-model:make-worktree
             :path "/repo/wt" :branch "main" :status :fetched
             :dirty-p t :additions 8 :deletions 3 :ahead 2)))
      (expect (equal '("DIRTY" "+8 -3" "AHEAD 2")
                     (nerimux/renderer::%worktree-status-tokens worktree)))
      (expect (string= "DIRTY +8 -3 AHEAD 2"
                       (nerimux/renderer::%worktree-status-label worktree)))))

  (it "omits the zero side of a one-sided diff line count"
    (let ((added-only
            (nerimux/workspace-model:make-worktree
             :path "/repo/wt" :branch "main" :status :fetched
             :dirty-p t :additions 1 :deletions 0))
          (deleted-only
            (nerimux/workspace-model:make-worktree
             :path "/repo/wt" :branch "main" :status :fetched
             :dirty-p t :additions 0 :deletions 4)))
      (expect (equal '("DIRTY" "+1")
                     (nerimux/renderer::%worktree-status-tokens added-only)))
      (expect (equal '("DIRTY" "-4")
                     (nerimux/renderer::%worktree-status-tokens deleted-only)))))

  (it "reads ahead/behind as arrows for the pane status line only"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :status :fetched :ahead 2 :behind 7)))
      (expect (equal '("AHEAD 2" "BEHIND 7")
                     (nerimux/renderer::%worktree-status-tokens worktree)))
      (expect (equal (list (format nil "~C2" (code-char #x2191))
                           (format nil "~C7" (code-char #x2193)))
                     (nerimux/renderer::%worktree-status-tokens
                      worktree :ahead-behind :arrows)))))

  (it "omits a zero diff line count token"
    (let ((worktree
            (nerimux/workspace-model:make-worktree
             :path "/repo/wt" :branch "main" :status :fetched
             :additions 0 :deletions 0)))
      (expect (equal '("CLEAN")
                     (nerimux/renderer::%worktree-status-tokens worktree)))))

  (it "omits AHEAD 0 / BEHIND 0 rather than showing a zero count"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :status :fetched :ahead 0 :behind 0)))
      (expect (equal '("CLEAN")
                     (nerimux/renderer::%worktree-status-tokens worktree)))))

  (it "lists every applicable token together, in the documented order"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :status :fetched
                                         :missing-p t :locked-p t
                                         :prunable-p t :dirty-p t :conflict-p t
                                         :ahead 2 :behind 7)))
      (expect (equal '("MISSING" "LOCKED" "PRUNABLE"
                       "DIRTY" "CONFLICT" "AHEAD 2" "BEHIND 7")
                     (nerimux/renderer::%worktree-status-tokens worktree)))))

  (it "reports structural tokens even without a fetched status, appending UNKNOWN"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :locked-p t :prunable-p t)))
      (expect (equal '("LOCKED" "PRUNABLE" "UNKNOWN")
                     (nerimux/renderer::%worktree-status-tokens worktree))))))

(describe "renderer-suite/workspace-status-title-selection"
          (it "uses stable repository and worktree title fallbacks"
              (let ((repository-cases
                     (list
                      (list
                       (nerimux/workspace-model:make-repository :id
                                                                "repo-spec"
                                                                :specification
                                                                "team/project"
                                                                :local-path
                                                                "/repo")
                       "team/project")
                      (list
                       (nerimux/workspace-model:make-repository :id
                                                                "repo-bare"
                                                                :specification
                                                                "github.com/acme/beta.git"
                                                                :local-path
                                                                "/repo")
                       "github.com/acme/beta")
                      (list
                       (nerimux/workspace-model:make-repository :id
                                                                "repo-path"
                                                                :specification
                                                                ""
                                                                :local-path
                                                                "/repo")
                       "/repo")
                      (list
                       (nerimux/workspace-model:make-repository :id
                                                                "repo-id"
                                                                :specification
                                                                ""
                                                                :local-path
                                                                "")
                       "repo-id")
                      (list nil "-")))
                    (worktree-cases
                     (list
                      (list
                       (nerimux/workspace-model:make-worktree :id
                                                              "wt-branch"
                                                              :path
                                                              "/repo/wt"
                                                              :branch
                                                              "feature/x")
                       "feature/x")
                      (list
                       (nerimux/workspace-model:make-worktree :id
                                                              "wt-path"
                                                              :path
                                                              "/repo/wt"
                                                              :branch
                                                              "")
                       "detached wt")
                      (list
                       (nerimux/workspace-model:make-worktree :id
                                                              "wt-id"
                                                              :path
                                                              ""
                                                              :branch
                                                              "")
                       "wt-id")
                      (list nil "-"))))
                (dolist 
                    (case repository-cases)
                  (expect
                   (string= (second case)
                            (nerimux/renderer::%repository-title-text
                             (first case)))))
                (dolist 
                    (case worktree-cases)
                  (expect
                   (string= (second case)
                            (nerimux/renderer::%worktree-title-text
                             (first case)))))))
          (it "selects repository directly or through the selected worktree"
              (let* ((repository
                      (nerimux/workspace-model:make-repository :id "repo"))
                     (worktree
                      (nerimux/workspace-model:make-worktree :id
                                                             "wt"
                                                             :path
                                                             "/wt"
                                                             :repository
                                                             repository)))
                (multiple-value-bind (selected-repository selected-worktree) 
                    (nerimux/renderer::%workspace-title-selection nil
                                                                  repository
                                                                  nil)
                  (expect (eq repository selected-repository))
                  (expect (null selected-worktree)))
                (multiple-value-bind (selected-repository selected-worktree) 
                    (nerimux/renderer::%workspace-title-selection nil
                                                                  nil
                                                                  worktree)
                  (expect (eq repository selected-repository))
                  (expect (eq worktree selected-worktree)))))
          (it "falls back to the focused pane's worktree"
              (let* ((repository
                      (nerimux/workspace-model:make-repository :id "repo"))
                     (worktree
                      (nerimux/workspace-model:make-worktree :id
                                                             "wt"
                                                             :path
                                                             "/wt"
                                                             :repository
                                                             repository))
                     (pane
                      (nerimux/pane:make-pane :id 1 :fd -1 :worktree worktree)))
                (multiple-value-bind (selected-repository selected-worktree) 
                    (nerimux/renderer::%workspace-title-selection pane nil nil)
                  (expect (eq repository selected-repository))
                  (expect (eq worktree selected-worktree)))))
          (it "builds the terminal title from the fields that exist, with no placeholder"
              (expect
               (search "nerimux: team/project · feature/x"
                       (nerimux/renderer::%client-title-osc
                        (nerimux/workspace-model:make-repository :specification
                                                                 "team/project")
                        (nerimux/workspace-model:make-worktree :path
                                                               "/wt"
                                                               :branch
                                                               "feature/x"))))
              (let ((empty (nerimux/renderer::%client-title-osc nil nil)))
                (expect (search "nerimux" empty))
                (expect (not (find (code-char #x2014) empty)))
                (expect (not (search "-" empty)))))

          (it "trims an overlong message from the front, keeping the tail that names it"
              (let ((message "worktree created: /home/u/ghq/github.com/acme/alpha"))
                (expect (string= message
                                 (nerimux/renderer::%message-strip-text message
                                                                        200)))
                (let ((strip (nerimux/renderer::%message-strip-text message 20)))
                  (expect (= 20 (nerimux/renderer::%display-width strip)))
                  (expect (char= #\… (char strip 0)))
                  (expect (search "acme/alpha" strip))
                  (expect (not (search "worktree created" strip)))))))
