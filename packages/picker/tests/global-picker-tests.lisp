(in-package #:nerimux/test/picker)

(describe "global picker"
  (it "builds a deterministic organization repository worktree hierarchy"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org"
              :host "github.com"
              :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo"
              :organization organization
              :specification "github.com/team/repo"))
           (clean
             (nerimux/workspace-model:make-worktree
              :id "clean"
              :repository repository
              :path "/tmp/clean"
              :branch "main"))
           (attention
             (nerimux/workspace-model:make-worktree
              :id "attention"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker"
              :dirty-p t)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository clean)
      (nerimux/workspace-model:repository-add-worktree repository attention)
      (let* ((items (nerimux/picker:build-global-picker-items
                     (list organization)))
             (attention-item
               (find attention items
                     :key #'nerimux/picker:picker-item-worktree
                     :test #'eq)))
        (expect (= 4 (length items)))
        (expect (eq organization
                    (nerimux/picker:picker-item-organization (first items))))
        (expect (= 1
                   (length
                    (nerimux/picker:filter-global-picker-items
                     items "feature"))))
        (expect (nerimux/picker:picker-item-attention-p attention-item))
        (expect (eq organization
                    (nerimux/picker:picker-item-organization
                     (nerimux/picker:select-global-picker-item items 1))))
        (expect (eq attention-item
                    (nerimux/picker:select-global-picker-item
                     items (nerimux/picker:picker-item-id attention-item)))))))

  (it "supports case-insensitive regex filtering across picker fields"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org"
              :host "github.com"
              :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo"
              :organization organization
              :specification "github.com/team/repo"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "feature"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker")))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (let ((items (nerimux/picker:build-global-picker-items
                    (list organization))))
        (expect (= 1
                   (length
                    (nerimux/picker:filter-global-picker-items
                     items "FEATURE/.*" :regex-p t))))
        (expect (null
                 (nerimux/picker:filter-global-picker-items
                 items "[" :regex-p t))))))

  (it "uses fallback labels for incomplete hierarchy data"
    (let* ((host-only
             (nerimux/workspace-model:make-organization
              :id "host-only"
              :host "github.com"))
           (name-only
             (nerimux/workspace-model:make-organization
              :id "name-only"
              :name "team"))
           (id-only
             (nerimux/workspace-model:make-organization :id "id-only"))
           (specification-repository
             (nerimux/workspace-model:make-repository
              :id "specification-repository"
              :specification "github.com/team/repository"))
           (local-path-repository
             (nerimux/workspace-model:make-repository
              :id "local-path-repository"
              :local-path #P"local/repository"))
           (id-repository
             (nerimux/workspace-model:make-repository :id "id-repository"))
           (branch-worktree
             (nerimux/workspace-model:make-worktree
              :id "branch-worktree"
              :branch "feature"))
           (path-worktree
             (nerimux/workspace-model:make-worktree
              :id "path-worktree"
              :path #P"worktree"))
           (id-worktree
             (nerimux/workspace-model:make-worktree :id "id-worktree"))
           (pane
             (nerimux/pane:make-pane :id 8)))
      (expect (string= "" (nerimux/picker::%picker-string nil)))
      (expect (string= "text" (nerimux/picker::%picker-string "text")))
      (let ((pathname #P"picker-path"))
        (expect (string= (namestring pathname)
                         (nerimux/picker::%picker-string pathname))))
      (expect (string= "42" (nerimux/picker::%picker-string 42)))
      (expect (string= (namestring #P"picker-path")
                       (nerimux/picker::%first-picker-string
                        "" nil #P"picker-path")))
      (expect (string= ""
                       (nerimux/picker::%first-picker-string
                        "" nil nil)))
      (expect (string= "github.com"
                       (nerimux/picker::%organization-label host-only)))
      (expect (string= "team"
                       (nerimux/picker::%organization-label name-only)))
      (expect (string= "id-only"
                       (nerimux/picker::%organization-label id-only)))
      (expect (string= "github.com/team/repository"
                       (nerimux/picker::%repository-label
                        specification-repository)))
      (expect (string= (namestring #P"local/repository")
                       (nerimux/picker::%repository-label
                        local-path-repository)))
      (expect (string= "id-repository"
                       (nerimux/picker::%repository-label id-repository)))
      (expect (string= "feature"
                       (nerimux/picker::%worktree-label branch-worktree)))
      (expect (string= (namestring #P"worktree")
                       (nerimux/picker::%worktree-label path-worktree)))
      (expect (string= "id-worktree"
                       (nerimux/picker::%worktree-label id-worktree)))
      (expect (string= "pane/8 shell"
                       (nerimux/picker::%pane-label pane)))
      (let* ((items (nerimux/picker:build-global-picker-items
                     (list host-only)))
             (copy (nerimux/picker:filter-global-picker-items items "")))
        (expect (equal items copy))
        (expect (not (eq items copy)))
        (expect (eq (first items)
                    (nerimux/picker:select-global-picker-item
                     items (nerimux/picker:picker-item-label (first items)))))
        (expect (null (nerimux/picker:select-global-picker-item items 0)))
        (expect (null (nerimux/picker:select-global-picker-item items -1)))
        (expect (null (nerimux/picker:select-global-picker-item items 99)))
        (expect (null (nerimux/picker:select-global-picker-item
                       items "unknown")))
        (expect (null (nerimux/picker:select-global-picker-item items nil))))))

  (it "propagates repository, organization, worktree, and pane attention"
    (let* ((clean-repository
             (nerimux/workspace-model:make-repository :id "clean"))
           (conflict-repository
             (nerimux/workspace-model:make-repository
              :id "conflict"
              :conflict-p t))
           (ahead-repository
             (nerimux/workspace-model:make-repository :id "ahead" :ahead 1))
           (behind-repository
             (nerimux/workspace-model:make-repository :id "behind" :behind 1))
           (missing-repository
             (nerimux/workspace-model:make-repository :id "missing" :missing-p t))
           (worktree-repository
             (nerimux/workspace-model:make-repository
              :id "worktree-attention"
              :worktrees
              (list (nerimux/workspace-model:make-worktree
                     :id "dirty"
                     :dirty-p t))))
           (missing-organization
             (nerimux/workspace-model:make-organization
              :id "missing-organization"
              :missing-p t))
           (counted-organization
             (nerimux/workspace-model:make-organization
              :id "counted-organization"
              :attention-count 1))
           (repository-organization
             (nerimux/workspace-model:make-organization
              :id "repository-organization"
              :repositories (list worktree-repository)))
           (clean-organization
             (nerimux/workspace-model:make-organization :id "clean-organization"))
           (clean-worktree
             (nerimux/workspace-model:make-worktree :id "clean-worktree"))
           (attention-worktree
             (nerimux/workspace-model:make-worktree
              :id "attention-worktree"
              :conflict-p t
              :ahead 1
              :behind 1
              :missing-p t))
           (clean-pane (nerimux/pane:make-pane :id 1))
           (attention-pane (nerimux/pane:make-pane :id 2)))
      (nerimux/pane:pane-mark-bell attention-pane)
      (dolist (repository (list conflict-repository
                                 ahead-repository
                                 behind-repository
                                 missing-repository
                                 worktree-repository))
        (expect
         (nerimux/picker:picker-item-attention-p
          (nerimux/picker::%make-picker-item
           :id (nerimux/workspace-model:repository-id repository)
           :kind :repository
           :repository repository))))
      (expect (not
               (nerimux/picker:picker-item-attention-p
                (nerimux/picker::%make-picker-item
                 :id "clean"
                 :kind :repository
                 :repository clean-repository))))
      (dolist (organization (list missing-organization
                                   counted-organization
                                   repository-organization))
        (expect
         (nerimux/picker:picker-item-attention-p
          (nerimux/picker::%make-picker-item
           :id (nerimux/workspace-model:organization-id organization)
           :kind :organization
           :organization organization))))
      (expect (not
               (nerimux/picker:picker-item-attention-p
                (nerimux/picker::%make-picker-item
                 :id "clean"
                 :kind :organization
                 :organization clean-organization))))
      (expect
       (nerimux/picker:picker-item-attention-p
        (nerimux/picker::%make-picker-item
         :id "attention-worktree"
         :kind :worktree
         :worktree attention-worktree)))
      (expect (not
               (nerimux/picker:picker-item-attention-p
                (nerimux/picker::%make-picker-item
                 :id "clean-worktree"
                 :kind :worktree
                 :worktree clean-worktree))))
      (expect
       (nerimux/picker:picker-item-attention-p
        (nerimux/picker::%make-picker-item
         :id "attention-pane"
         :kind :pane
         :pane attention-pane)))
      (expect (not
               (nerimux/picker:picker-item-attention-p
                (nerimux/picker::%make-picker-item
                 :id "clean-pane"
                 :kind :pane
                 :pane clean-pane))))
      (expect (not
               (nerimux/picker:picker-item-attention-p
                (nerimux/picker::%make-picker-item
                 :id "unknown"
                 :kind :unknown))))))

  (it "indexes transient metadata in picker searches"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "metadata-organization"
              :host "github.com"
              :name "metadata"
              :active-worktree-count 1
              :attention-count 3
              :missing-p t))
           (repository
             (nerimux/workspace-model:make-repository
              :id "metadata-repository"
              :organization organization
              :specification "github.com/metadata/repository"
              :remote "origin"
              :local-path #P"metadata/repository"
              :conflict-p t))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "metadata-worktree"
              :repository repository
              :path #P"metadata/worktree"
              :branch "metadata-branch"
              :head "metadata-head"))
           (pane
             (nerimux/pane:make-pane
              :id 3
              :title "metadata-pane"
              :start-command "metadata-command"
              :start-path "metadata/worktree")))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (nerimux/pane:pane-mark-focused pane)
      (nerimux/pane:pane-mark-output pane #(111 107))
      (nerimux/pane:pane-mark-bell pane)
      (nerimux/pane:pane-mark-process-exit pane :status 1)
      (nerimux/pane:pane-mark-startup-failure pane)
      (nerimux/pane:pane-notify pane "metadata-notification")
      (nerimux/pane:worktree-add-pane worktree pane)
      (let* ((items (nerimux/picker:build-global-picker-items
                     (list organization)))
             (focused-time
               (nerimux/pane:pane-last-focused-time pane))
             (output-time
               (nerimux/pane:pane-last-output-time pane)))
        (dolist (query '("missing" "attention 3" "repositories 1 worktrees 1"
                         "origin" "metadata-notification" "unread-output"
                         "bell" "process-exited" "non-zero-exit"
                         "startup-failed"))
          (expect (not (null
                        (nerimux/picker:filter-global-picker-items
                         items query)))))
        (expect (not (null
                      (nerimux/picker:filter-global-picker-items
                       items (princ-to-string focused-time)))))
        (expect (not (null
                      (nerimux/picker:filter-global-picker-items
                       items (princ-to-string output-time))))))))

  (it "validates benchmark distributions and accepts empty scales"
    (signals error
      (nerimux/picker:benchmark-global-picker
       :organization-count -1))
    (signals error
      (nerimux/picker:benchmark-global-picker
       :repository-count -1))
    (signals error
      (nerimux/picker:benchmark-global-picker
       :pane-count -1))
    (signals error
      (nerimux/picker:benchmark-global-picker
       :worktree-count -1))
    (signals error
      (nerimux/picker:benchmark-global-picker
       :query nil))
    (signals error
      (nerimux/picker:benchmark-global-picker
       :organization-count 0
       :repository-count 1
       :worktree-count 0
       :pane-count 0))
    (signals error
      (nerimux/picker:benchmark-global-picker
       :organization-count 1
       :repository-count 0
       :worktree-count 1
       :pane-count 0))
    (signals error
      (nerimux/picker:benchmark-global-picker
       :organization-count 1
       :repository-count 1
       :worktree-count 0
       :pane-count 1))
    (let ((result
            (nerimux/picker:benchmark-global-picker
             :organization-count 0
             :repository-count 0
             :worktree-count 0
             :pane-count 0)))
      (expect (= 0 (getf result :item-count)))
      (expect (= 0 (getf result :match-count))))
    (let ((result
            (nerimux/picker:benchmark-global-picker
             :organization-count 1
             :repository-count 1)))
      (expect (= 1 (getf result :organization-count)))
      (expect (= 1 (getf result :repository-count)))
      (expect (plusp (getf result :item-count)))))

  (it "includes pane metadata and propagates pane attention"
    (let* ((organization
             (nerimux/workspace-model:make-organization :id "org" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo"
              :organization organization
              :specification "github.com/team/repo"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "feature"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker"))
           (pane
             (nerimux/pane:make-pane
              :id 7
              :title "editor"
              :start-command "nvim"
              :start-path "/tmp/feature")))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (nerimux/pane:worktree-add-pane worktree pane)
      (let* ((items (nerimux/picker:build-global-picker-items
                     (list organization)))
             (pane-item
               (find pane items
                     :key #'nerimux/picker:picker-item-pane
                     :test #'eq)))
        (expect (= 4 (length items)))
        (expect (= 1
                   (length
                    (nerimux/picker:filter-global-picker-items
                     items "editor"))))
        (nerimux/pane:pane-mark-output pane #(111 107))
        (expect (nerimux/picker:picker-item-attention-p pane-item)))))

  (it "searches repository and worktree state fields"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org"
              :name "team"
              :attention-count 7))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo"
              :organization organization
              :specification "host/team/repo"
              :backend :mercurial
              :dirty-p t
              :ahead 2
              :behind 3
              :conflict-p t
              :missing-p t))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "feature"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker"
              :head "deadbeef"
              :bare-p t
              :locked-p t
              :prunable-p t
              :missing-p t
              :conflict-p t
              :ahead 4
              :behind 5)))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (let ((items (nerimux/picker:build-global-picker-items
                    (list organization))))
        (dolist (query '("mercurial" "dirty" "ahead 2" "behind 3"
                         "conflict" "missing"))
          (expect
           (find :repository
                 (nerimux/picker:filter-global-picker-items items query)
                 :key #'nerimux/picker:picker-item-kind
                 :test #'eq)))
        (dolist (query '("deadbeef" "bare" "locked" "prunable"
                         "ahead 4" "behind 5"))
          (expect
           (= 1
              (length
               (nerimux/picker:filter-global-picker-items items query)))))
        (dolist (query '("missing" "conflict"))
          (expect
           (find :worktree
                 (nerimux/picker:filter-global-picker-items items query)
                 :key #'nerimux/picker:picker-item-kind
                 :test #'eq)))
        (expect
         (find :organization
               (nerimux/picker:filter-global-picker-items
                items "attention 7")
               :key #'nerimux/picker:picker-item-kind
               :test #'eq)))))

  (it "distributes remainder worktrees across repositories"
    (let ((result
            (nerimux/picker:benchmark-global-picker
             :organization-count 2
             :repository-count 3
             :worktree-count 4
             :pane-count 0
             :query "repo-")))
      (expect (= 2 (getf result :organization-count)))
      (expect (= 3 (getf result :repository-count)))
      (expect (= 4 (getf result :worktree-count)))
      (expect (= 0 (getf result :pane-count)))
      (expect (= 9 (getf result :item-count)))))

  (it "measures the default hierarchy shape at a bounded scale"
    (let ((result
            (nerimux/picker:benchmark-global-picker
             :organization-count 4
             :worktree-count 12
             :query "repo-")))
      (expect (= 4 (getf result :organization-count)))
      (expect (= 4 (getf result :repository-count)))
      (expect (= 12 (getf result :pane-count)))
      (expect (= 12 (getf result :worktree-count)))
      (expect (= 32 (getf result :item-count)))
      (expect (>= (getf result :match-count) 4))
      (expect (integerp (getf result :elapsed-ms)))))

  (it "keeps the mandatory picker scale within the initial-render budget"
    (let ((result
            (nerimux/picker:benchmark-global-picker
             :organization-count 1000
             :repository-count 1000
             :pane-count 5000)))
      (expect (= 1000 (getf result :organization-count)))
      (expect (= 1000 (getf result :repository-count)))
      (expect (= 5000 (getf result :pane-count)))
      (expect (= 5000 (getf result :worktree-count)))
      (expect (= 12000 (getf result :item-count)))
      (expect (= 12000 (getf result :match-count)))
      (expect (<= (getf result :elapsed-ms) 100))))

  (it "derives stable selection tokens from fallback model fields"
    (let ((organization
            (nerimux/workspace-model:make-organization
             :host "github.com"
             :name "team"))
          (repository
            (nerimux/workspace-model:make-repository
             :specification "github.com/team/repo"))
          (worktree
            (nerimux/workspace-model:make-worktree
             :path "/tmp/worktree"))
          (branch-worktree
            (nerimux/workspace-model:make-worktree :branch "feature")))
      (expect (equal "github.com/team"
                     (nerimux::%organization-selection-token organization)))
      (expect (equal "github.com/team/repo"
                     (nerimux::%repository-selection-token repository)))
      (expect (equal "/tmp/worktree||"
                     (nerimux::%worktree-selection-token worktree)))
      (expect (equal "|feature|"
                     (nerimux::%worktree-selection-token branch-worktree)))
      (expect (equal '(:organization "github.com/team")
                     (nerimux::%tree-object-selection-token organization)))
      (expect (null (nerimux::%tree-object-selection-token nil))))))
