(in-package #:nerimux/test/renderer)

;;;; Direct unit tests for %DISPLAY-WIDTH / %DISPLAY-CLIP (renderer-format.lisp),
;;;; the R6.9 fix: renderer-workspace.lisp's tree/status-line/confirm-view clip
;;;; used to measure text by (LENGTH TEXT), desyncing by one column per
;;;; full-width character (CJK, kana, hangul) in a branch name or path -- the
;;;; emulator side already treats those as 2 cells (char-width,
;;;; src/domain/terminal/cell.lisp:149). %DISPLAY-CLIP/%DISPLAY-WIDTH are the
;;;; fix: every non-SGR clip site in renderer-workspace.lisp routes through
;;;; them.
;;;;
;;;; NERIMUX/TERMINAL/TYPES:CHAR-WIDTH (imported into NERIMUX/TEST via
;;;; tests/package.lisp) returns 2 for CJK/kana/hangul, so "日本語" (3 characters)
;;;; is 6 display columns, not 3 -- every expectation below is computed from
;;;; that fact plus %DISPLAY-CLIP's own documented contract (renderer-
;;;; format.lisp:228-252): a width >= 4 keeps a 3-column "..." suffix, a
;;;; character that would straddle the WIDTH boundary is dropped whole rather
;;;; than split, and the result is padded to exactly WIDTH.

(describe "renderer-suite/workspace-clip-display-width"

  ;; %DISPLAY-WIDTH itself: the basic desync %WORKTREE-STATUS-TOKENS'
  ;; sibling functions rely on -- 3 full-width characters cost 6 columns, not
  ;; 3 ((LENGTH "日本語") would say 3).
  (it "counts a full-width Japanese branch name as 2 columns per character"
    (expect (= 6 (nerimux/renderer::%display-width "日本語")))
    (expect (= 3 (length "日本語"))))

  ;; A mixed ASCII + Japanese path: 4 ASCII columns + 6 Japanese columns.
  (it "sums ASCII and full-width columns in a mixed path"
    (expect (= 10 (nerimux/renderer::%display-width "工事中/tmp")))))

(describe "renderer-suite/workspace-clip-japanese-branch"

  ;; A branch name with Japanese characters, clipped to a width that must
  ;; cut mid-string: "機能/検証チーム" is 8 characters, all full-width
  ;; (including the ASCII slash, which is 1 column) except the slash --
  ;; "機能" (2 chars, 4 cols) + "/" (1 col) + "検証チーム" (5 chars, 10 cols)
  ;; = 15 display columns total, 8 characters by LENGTH.
  ;; Clipped to WIDTH=7 (>= 4, so a 3-column "..." suffix applies): budget =
  ;; 7 - 3 = 4 columns. The loop admits "機"(2) then "能"(2) = 4 columns
  ;; taken, end at character index 2 ("機能"), then the "/" would push to 5 >
  ;; budget so it stops there. Result: "機能" + no pad (4 == budget) + "..."
  ;; = "機能..." (2*2 + 3 = 7 columns).
  (it "clips a Japanese branch name to the requested display width, not character count"
    (let ((clipped (nerimux/renderer::%display-clip "機能/検証チーム" 7)))
      (expect (string= "機能..." clipped))
      (expect (= 7 (nerimux/renderer::%display-width clipped)))))

  ;; The boundary case the R6.9 fix exists for: a WIDTH that lands exactly
  ;; between two full-width characters must drop the second one whole, never
  ;; split it into a half-character. "検証チーム" is 5 full-width chars (10
  ;; columns). WIDTH=5 (< 4 is false, so ellipsis applies: budget = 5-3 = 2).
  ;; Only "検"(2) fits the 2-column budget; "証" would make 4 > 2. Result:
  ;; "検" + pad(2-2=0) + "..." = "検..." (2 + 0 + 3 = 5 columns) -- the
  ;; character boundary, never a torn half-cell.
  (it "drops a full-width character whole at the clip boundary rather than splitting it"
    (let ((clipped (nerimux/renderer::%display-clip "検証チーム" 5)))
      (expect (string= "検..." clipped))
      (expect (= 5 (nerimux/renderer::%display-width clipped)))
      ;; Every character in the result is either from the original string
      ;; intact, or the literal "..." suffix -- nothing partial.
      (expect (or (find (char clipped 0) "検証チーム") (char= (char clipped 0) #\.)))))

  ;; A WIDTH too narrow for the 3-column ellipsis (< 4) truncates without one
  ;; -- still never splitting a wide character. WIDTH=3: budget = 3 (no
  ;; ellipsis). "検"(2) fits; "証" would make 4 > 3. Result: "検" + pad(1) =
  ;; "検 " (2 + 1 = 3 columns, no "...").
  (it "truncates without an ellipsis below the 4-column floor, still on a character boundary"
    (let ((clipped (nerimux/renderer::%display-clip "検証チーム" 3)))
      (expect (string= "検 " clipped))
      (expect (= 3 (nerimux/renderer::%display-width clipped))))))

(describe "renderer-suite/workspace-clip-ascii-regression"

  ;; Regression guard: for ASCII-only text, %DISPLAY-CLIP's behaviour must be
  ;; identical to what the pre-R6.9 length-based clip produced, since every
  ;; character is 1 column either way. "abcdefgh" (8 cols) clipped to 5 (>= 4,
  ;; ellipsis applies): budget = 2, "ab" fits, "c" would make 3 > 2. Result:
  ;; "ab..." -- the same 2-visible-characters-plus-ellipsis shape a naive
  ;; (LENGTH TEXT) clip would have produced for pure ASCII.
  (it "matches the pre-R6.9 length-based clip result for ASCII-only text"
    (let ((clipped (nerimux/renderer::%display-clip "abcdefgh" 5)))
      (expect (string= "ab..." clipped))
      (expect (= 5 (length clipped)))
      (expect (= 5 (nerimux/renderer::%display-width clipped)))))

  (it "coerces non-string values before clipping"
    (expect (string= "1..." (nerimux/renderer::%display-clip 12345 4))))

  ;; Text already within WIDTH is returned unchanged (no padding, no
  ;; ellipsis), for both ASCII and Japanese input.
  (it "returns text unchanged when it already fits, ASCII or Japanese"
    (expect (string= "short" (nerimux/renderer::%display-clip "short" 10)))
    (expect (string= "短い" (nerimux/renderer::%display-clip "短い" 10)))))

(describe "renderer-suite/workspace-clip-tree-integration"

  ;; End to end through the actual overview call site: a tree row (the
  ;; Repositories section, one repository, its worktree expanded -- level 2,
  ;; full width) reaches the frame through %VISIBLE-TRUNCATE inside
  ;; %EMIT-STYLED-ROW (renderer-workspace.lisp), not through %DISPLAY-CLIP's
  ;; fixed-left-width column anymore -- render-workspace.lisp builds the
  ;; whole row (indent + markers + label [+ worktree info suffix]) and clips
  ;; THAT to the full terminal width. This computes the expected truncated
  ;; text with the SAME %WORKTREE-TREE-INFO-SUFFIX and %VISIBLE-TRUNCATE the
  ;; production code calls, rather than re-deriving the truncation
  ;; arithmetic by hand (already exercised directly above), and confirms
  ;; that exact truncated text -- not the unclipped original -- appears
  ;; verbatim in the rendered frame.
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
           ;; A repository row under Repositories defaults COLLAPSED (the
           ;; section-based redesign's decision) -- expand it explicitly so
           ;; WORKTREE's own row (level 2, branch-only label) is the one
           ;; under test here, not the Attention/Active "org/repo · branch"
           ;; row shape.
           (expanded-node-ids
             (let ((table (make-hash-table :test #'equal)))
               (setf (gethash (list :repository "repo-clip") table) t)
               table)))
      (let* ((frame
               (nerimux/renderer:render-workspace-overview-to-string
                (list organization) 24 cols :expanded-node-ids expanded-node-ids))
             ;; Level 2 (Repositories -> repository -> worktree): a 4-space
             ;; indent, then the selected-marker and attention-marker slots
             ;; (both a literal space here -- neither applies to this
             ;; worktree), then the branch label -- matching RENDER-WORKSPACE-
             ;; OVERVIEW-TO-STRING's TREE-ROW-TEXT closure exactly.
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
        ;; And the unclipped 20-column branch name must NOT appear whole --
        ;; otherwise this test would pass vacuously even with a broken clip.
        (expect (not (search branch frame)))))))
