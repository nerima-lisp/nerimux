(in-package #:nerimux/test/renderer)

(describe "renderer-suite/workspace-clip-display-width"

  (it "counts a full-width Japanese branch name as 2 columns per character"
    (expect (= 6 (nerimux/renderer::%display-width "日本語")))
    (expect (= 3 (length "日本語"))))

  (it "sums ASCII and full-width columns in a mixed path"
    (expect (= 10 (nerimux/renderer::%display-width "工事中/tmp")))))

(describe "renderer-suite/workspace-clip-japanese-branch"

  (it "clips a Japanese branch name to the requested display width, not character count"
    (let ((clipped (nerimux/renderer::%display-clip "機能/検証チーム" 7)))
      (expect (string= "機能..." clipped))
      (expect (= 7 (nerimux/renderer::%display-width clipped)))))

  (it "drops a full-width character whole at the clip boundary rather than splitting it"
    (let ((clipped (nerimux/renderer::%display-clip "検証チーム" 5)))
      (expect (string= "検..." clipped))
      (expect (= 5 (nerimux/renderer::%display-width clipped)))
      (expect (or (find (char clipped 0) "検証チーム") (char= (char clipped 0) #\.)))))

  (it "truncates without an ellipsis below the 4-column floor, still on a character boundary"
    (let ((clipped (nerimux/renderer::%display-clip "検証チーム" 3)))
      (expect (string= "検 " clipped))
      (expect (= 3 (nerimux/renderer::%display-width clipped))))))

(describe "renderer-suite/workspace-clip-ascii-regression"

  (it "preserves ASCII clipping with an ellipsis"
    (let ((clipped (nerimux/renderer::%display-clip "abcdefgh" 5)))
      (expect (string= "ab..." clipped))
      (expect (= 5 (length clipped)))
      (expect (= 5 (nerimux/renderer::%display-width clipped)))))

  (it "coerces non-string values before clipping"
    (expect (string= "1..." (nerimux/renderer::%display-clip 12345 4))))

  (it "returns text unchanged when it already fits, ASCII or Japanese"
    (expect (string= "short" (nerimux/renderer::%display-clip "short" 10)))
    (expect (string= "短い" (nerimux/renderer::%display-clip "短い" 10)))))

(describe "renderer-suite/workspace-clip-tree-integration"

  (it "renders the tree row with the same visible-truncated text %visible-truncate itself produces"
    (let* ((cols 20)
           (branch (make-string 20 :initial-element #\a))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-clip" :path "/repo/work" :branch branch))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-clip" :specification "github.com/team/clip"
              :local-path "/repo" :worktrees (list worktree)))
           (organization
             (nerimux/workspace-model:make-organization
              :id "github.com/team-clip" :host "github.com" :name "team-clip"
              :repositories (list repository)))
           (expanded-node-ids
             (let ((table (make-hash-table :test #'equal)))
               (setf (gethash (list :repository "repo-clip") table) t)
               table)))
      (let* ((frame
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization) 24 cols :expanded-node-ids expanded-node-ids))
             (base (format nil "~A~A" (make-string 7 :initial-element #\Space) branch))
             (suffix
               (nth-value 1
                (nerimux/renderer::%worktree-tree-info-suffix
                 worktree
                 (max 0 (- cols (nerimux/renderer::%display-width base) 2)))))
             (row-value
               (if (plusp (length suffix))
                   (format nil "~A  ~A" base suffix)
                   base))
             (expected-truncated
               (nerimux/renderer::%visible-truncate row-value cols)))
        (expect (> (nerimux/renderer::%display-width row-value) cols))
        (expect (search expected-truncated frame))
        (expect (not (search branch frame)))))))
