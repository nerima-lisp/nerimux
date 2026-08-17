(in-package #:cl-tmux/test)

(describe "global picker"
  (it "builds a deterministic organization repository worktree hierarchy"
    (let* ((organization
             (cl-tmux/model:make-organization
              :id "org"
              :host "github.com"
              :name "team"))
           (repository
             (cl-tmux/model:make-repository
              :id "repo"
              :organization organization
              :specification "github.com/team/repo"))
           (clean
             (cl-tmux/model:make-worktree
              :id "clean"
              :repository repository
              :path "/tmp/clean"
              :branch "main"))
           (attention
             (cl-tmux/model:make-worktree
              :id "attention"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker"
              :dirty-p t)))
      (cl-tmux/model:organization-add-repository organization repository)
      (cl-tmux/model:repository-add-worktree repository clean)
      (cl-tmux/model:repository-add-worktree repository attention)
      (let* ((items (cl-tmux/picker:build-global-picker-items
                     (list organization)))
             (attention-item
               (find attention items
                     :key #'cl-tmux/picker:picker-item-worktree
                     :test #'eq)))
        (expect (= 4 (length items)))
        (expect (eq organization
                    (cl-tmux/picker:picker-item-organization (first items))))
        (expect (= 1
                   (length
                    (cl-tmux/picker:filter-global-picker-items
                     items "feature"))))
        (expect (cl-tmux/picker:picker-item-attention-p attention-item))
        (expect (eq organization
                    (cl-tmux/picker:picker-item-organization
                     (cl-tmux/picker:select-global-picker-item items 1))))
        (expect (eq attention-item
                    (cl-tmux/picker:select-global-picker-item
                     items (cl-tmux/picker:picker-item-id attention-item)))))))

  (it "supports case-insensitive regex filtering across picker fields"
    (let* ((organization
             (cl-tmux/model:make-organization
              :id "org"
              :host "github.com"
              :name "team"))
           (repository
             (cl-tmux/model:make-repository
              :id "repo"
              :organization organization
              :specification "github.com/team/repo"))
           (worktree
             (cl-tmux/model:make-worktree
              :id "feature"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker")))
      (cl-tmux/model:organization-add-repository organization repository)
      (cl-tmux/model:repository-add-worktree repository worktree)
      (let ((items (cl-tmux/picker:build-global-picker-items
                    (list organization))))
        (expect (= 1
                   (length
                    (cl-tmux/picker:filter-global-picker-items
                     items "FEATURE/.*" :regex-p t))))
        (expect (null
                 (cl-tmux/picker:filter-global-picker-items
                  items "[" :regex-p t))))))

  (it "includes pane metadata and propagates pane attention"
    (let* ((organization
             (cl-tmux/model:make-organization :id "org" :name "team"))
           (repository
             (cl-tmux/model:make-repository
              :id "repo"
              :organization organization
              :specification "github.com/team/repo"))
           (worktree
             (cl-tmux/model:make-worktree
              :id "feature"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker"))
           (pane
             (cl-tmux/model:make-pane
              :id 7
              :title "editor"
              :start-command "nvim"
              :start-path "/tmp/feature")))
      (cl-tmux/model:organization-add-repository organization repository)
      (cl-tmux/model:repository-add-worktree repository worktree)
      (cl-tmux/model:worktree-add-pane worktree pane)
      (let* ((items (cl-tmux/picker:build-global-picker-items
                     (list organization)))
             (pane-item
               (find pane items
                     :key #'cl-tmux/picker:picker-item-pane
                     :test #'eq)))
        (expect (= 4 (length items)))
        (expect (= 1
                   (length
                    (cl-tmux/picker:filter-global-picker-items
                     items "editor"))))
        (cl-tmux/model:pane-mark-output pane #(111 107))
        (expect (cl-tmux/picker:picker-item-attention-p pane-item)))))

  (it "searches repository and worktree state fields"
    (let* ((organization
             (cl-tmux/model:make-organization
              :id "org"
              :name "team"
              :attention-count 7))
           (repository
             (cl-tmux/model:make-repository
              :id "repo"
              :organization organization
              :specification "host/team/repo"
              :backend :mercurial
              :dirty-p t
              :ahead 2))
           (worktree
             (cl-tmux/model:make-worktree
              :id "feature"
              :repository repository
              :path "/tmp/feature"
              :branch "feature/picker"
              :head "deadbeef"
              :bare-p t
              :locked-p t
              :prunable-p t
              :missing-p t)))
      (cl-tmux/model:organization-add-repository organization repository)
      (cl-tmux/model:repository-add-worktree repository worktree)
      (let ((items (cl-tmux/picker:build-global-picker-items
                    (list organization))))
        (dolist (query '("mercurial" "dirty" "ahead 2"))
          (expect
           (find :repository
                 (cl-tmux/picker:filter-global-picker-items items query)
                 :key #'cl-tmux/picker:picker-item-kind
                 :test #'eq)))
        (dolist (query '("deadbeef" "bare" "locked" "prunable" "missing"))
          (expect
           (= 1
              (length
               (cl-tmux/picker:filter-global-picker-items items query)))))
        (expect
         (find :organization
               (cl-tmux/picker:filter-global-picker-items
                items "attention 7")
               :key #'cl-tmux/picker:picker-item-kind
               :test #'eq)))))

  (it "measures the default hierarchy shape at a bounded scale"
    (let ((result
            (cl-tmux/picker:benchmark-global-picker
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
            (cl-tmux/picker:benchmark-global-picker
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
