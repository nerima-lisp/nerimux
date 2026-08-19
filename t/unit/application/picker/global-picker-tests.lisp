(in-package #:nerimux/test)

(describe "global picker"
  (it "builds a deterministic organization repository worktree hierarchy"
    (let* ((organization
             (nerimux/model:make-organization
              :id "org"
              :host "github.com"
              :name "team"))
           (repository
             (nerimux/model:make-repository
              :id "repo"
              :organization organization
              :specification "github.com/team/repo"))
           (clean
             (nerimux/model:make-worktree
              :id "clean"
              :repository repository
              :path "/tmp/clean"
              :branch "main"))
           (attention
             (nerimux/model:make-worktree
              :id "attention"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker"
              :dirty-p t)))
      (nerimux/model:organization-add-repository organization repository)
      (nerimux/model:repository-add-worktree repository clean)
      (nerimux/model:repository-add-worktree repository attention)
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
             (nerimux/model:make-organization
              :id "org"
              :host "github.com"
              :name "team"))
           (repository
             (nerimux/model:make-repository
              :id "repo"
              :organization organization
              :specification "github.com/team/repo"))
           (worktree
             (nerimux/model:make-worktree
              :id "feature"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker")))
      (nerimux/model:organization-add-repository organization repository)
      (nerimux/model:repository-add-worktree repository worktree)
      (let ((items (nerimux/picker:build-global-picker-items
                    (list organization))))
        (expect (= 1
                   (length
                    (nerimux/picker:filter-global-picker-items
                     items "FEATURE/.*" :regex-p t))))
        (expect (null
                 (nerimux/picker:filter-global-picker-items
                  items "[" :regex-p t))))))

  (it "includes pane metadata and propagates pane attention"
    (let* ((organization
             (nerimux/model:make-organization :id "org" :name "team"))
           (repository
             (nerimux/model:make-repository
              :id "repo"
              :organization organization
              :specification "github.com/team/repo"))
           (worktree
             (nerimux/model:make-worktree
              :id "feature"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker"))
           (pane
             (nerimux/model:make-pane
              :id 7
              :title "editor"
              :start-command "nvim"
              :start-path "/tmp/feature")))
      (nerimux/model:organization-add-repository organization repository)
      (nerimux/model:repository-add-worktree repository worktree)
      (nerimux/model:worktree-add-pane worktree pane)
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
        (nerimux/model:pane-mark-output pane #(111 107))
        (expect (nerimux/picker:picker-item-attention-p pane-item)))))

  (it "searches repository and worktree state fields"
    (let* ((organization
             (nerimux/model:make-organization
              :id "org"
              :name "team"
              :attention-count 7))
           (repository
             (nerimux/model:make-repository
              :id "repo"
              :organization organization
              :specification "host/team/repo"
              :backend :mercurial
              :dirty-p t
              :ahead 2))
           (worktree
             (nerimux/model:make-worktree
              :id "feature"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker"
              :head "deadbeef"
              :bare-p t
              :locked-p t
              :prunable-p t
              :missing-p t)))
      (nerimux/model:organization-add-repository organization repository)
      (nerimux/model:repository-add-worktree repository worktree)
      (let ((items (nerimux/picker:build-global-picker-items
                    (list organization))))
        (dolist (query '("mercurial" "dirty" "ahead 2"))
          (expect
           (find :repository
                 (nerimux/picker:filter-global-picker-items items query)
                 :key #'nerimux/picker:picker-item-kind
                 :test #'eq)))
        (dolist (query '("deadbeef" "bare" "locked" "prunable" "missing"))
          (expect
           (= 1
              (length
               (nerimux/picker:filter-global-picker-items items query)))))
        (expect
         (find :organization
               (nerimux/picker:filter-global-picker-items
                items "attention 7")
               :key #'nerimux/picker:picker-item-kind
               :test #'eq)))))

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
      (expect (<= (getf result :elapsed-ms) 100)))))
