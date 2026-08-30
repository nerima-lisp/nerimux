(in-package #:nerimux/test/renderer)

;;;; Direct unit tests for %WORKTREE-STATUS-TOKENS / %WORKTREE-STATUS-LABEL
;;;; (renderer-workspace.lisp), the R6.1 status-token contract
;;;; (docs/notes/workspace-requirements.md §R6.1, design doc §6.1/§6.2):
;;;;
;;;;   MISSING / BARE / LOCKED / PRUNABLE / DIRTY / CONFLICT / AHEAD n /
;;;;   BEHIND n are all listed together when applicable, AHEAD/BEHIND keep
;;;;   their counts, no-match is CLEAN, and a worktree whose status was never
;;;;   fetched is UNKNOWN -- never assumed CLEAN.
;;;;
;;;; WORKTREE-STATUS (the NERIMUX/MODEL slot) is what distinguishes "never
;;;; fetched" from "fetched and clean": both start at the same false/0 values
;;;; for DIRTY-P/CONFLICT-P/AHEAD/BEHIND, so only the STATUS slot itself (set
;;;; by NERIMUX/VCS:WORKTREE-STATUS, see vcs-tests.lisp) tells them apart.
;;;; These tests build worktrees directly via NERIMUX/MODEL:MAKE-WORKTREE and
;;;; never touch the VCS adapter, so :status here is a bare truthy marker
;;;; (e.g. :fetched) standing in for whatever VCS-STATUS-STRUCTURED snapshot
;;;; a real fetch would store there.

(describe "renderer-suite/workspace-status-tokens"

  ;; The single most important case per the R6 report: a worktree whose
  ;; status was never fetched must read UNKNOWN, not CLEAN, even though every
  ;; individual health flag (dirty/conflict/ahead/behind) is at its default
  ;; false/0 value -- the same values a genuinely clean, fetched worktree has.
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

  ;; UNKNOWN is not merely "no health tokens" -- it wins over a stale health
  ;; flag left set on a worktree whose status was cleared (e.g. vcs.lisp's
  ;; missing-path branch resets status to NIL but, defensively, this checks
  ;; the case where a caller left DIRTY-P/AHEAD set without a fetched status).
  ;; The dirty/ahead flags must not leak into the token list when STATUS is
  ;; NIL, because %WORKTREE-STATUS-TOKENS only reads the health slots inside
  ;; the (if (worktree-status worktree) ...) branch.
  (it "ignores stale health flags when status was never fetched"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :dirty-p t :ahead 5)))
      (expect (equal '("UNKNOWN")
                     (nerimux/renderer::%worktree-status-tokens worktree)))))

  ;; AHEAD/BEHIND retain their exact counts -- no rounding to a boolean
  ;; CHANGED (design doc §6.2: "単なるCHANGEDへの丸めは行わない").
  (it "keeps the AHEAD/BEHIND counts instead of collapsing to a boolean"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :status :fetched :ahead 12 :behind 3)))
      (expect (equal '("AHEAD 12" "BEHIND 3")
                     (nerimux/renderer::%worktree-status-tokens worktree)))
      (expect (string= "AHEAD 12 BEHIND 3"
                       (nerimux/renderer::%worktree-status-label worktree)))))

  ;; AHEAD/BEHIND of exactly 0 are omitted (plusp guards both), so a fetched,
  ;; otherwise-clean worktree with ahead=0 behind=0 still reads CLEAN rather
  ;; than "AHEAD 0 BEHIND 0".
  (it "omits AHEAD 0 / BEHIND 0 rather than showing a zero count"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :status :fetched :ahead 0 :behind 0)))
      (expect (equal '("CLEAN")
                     (nerimux/renderer::%worktree-status-tokens worktree)))))

  ;; All applicable tokens are listed together (not just the first match, per
  ;; the R6 report's "以前は cond が 1 つだけ選んだ" regression), in the
  ;; documented order: structural (MISSING BARE LOCKED PRUNABLE) then health
  ;; (DIRTY CONFLICT AHEAD BEHIND).
  (it "lists every applicable token together, in the documented order"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :status :fetched
                                         :missing-p t :bare-p t :locked-p t
                                         :prunable-p t :dirty-p t :conflict-p t
                                         :ahead 2 :behind 7)))
      (expect (equal '("MISSING" "BARE" "LOCKED" "PRUNABLE"
                       "DIRTY" "CONFLICT" "AHEAD 2" "BEHIND 7")
                     (nerimux/renderer::%worktree-status-tokens worktree)))))

  ;; Structural tokens (MISSING/BARE/LOCKED/PRUNABLE) come from `git worktree
  ;; list --porcelain`, a different source from VCS-STATUS-STRUCTURED, so they
  ;; are reported even when status was never fetched -- UNKNOWN is appended
  ;; after them, not used in place of them.
  (it "reports structural tokens even without a fetched status, appending UNKNOWN"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :locked-p t :prunable-p t)))
      (expect (equal '("LOCKED" "PRUNABLE" "UNKNOWN")
                     (nerimux/renderer::%worktree-status-tokens worktree)))))

  ;; BARE is a type marker, not a health flag (design doc §6.2: "BAREは
  ;; repositoryの種別表示として使い、worktreeの健康状態と同列に扱わない"),
  ;; but %WORKTREE-STATUS-TOKENS still lists it alongside health tokens when
  ;; both apply to the same worktree row rather than suppressing one.
  (it "lists BARE alongside health tokens rather than replacing them"
    (let ((worktree
            (nerimux/workspace-model:make-worktree :path "/repo/wt" :branch "main"
                                         :status :fetched :bare-p t :dirty-p t)))
      (expect (equal '("BARE" "DIRTY")
                     (nerimux/renderer::%worktree-status-tokens worktree))))))

(describe "renderer-suite/workspace-status-title-selection"

  (it "uses stable repository and worktree title fallbacks"
    (let ((repository-cases
            (list (list (nerimux/workspace-model:make-repository
                         :id "repo-spec" :specification "team/project"
                         :local-path "/repo")
                        "team/project")
                  (list (nerimux/workspace-model:make-repository
                         :id "repo-path" :specification ""
                         :local-path "/repo")
                        "/repo")
                  (list (nerimux/workspace-model:make-repository
                         :id "repo-id" :specification "" :local-path "")
                        "repo-id")
                  (list nil "-")))
          (worktree-cases
            (list (list (nerimux/workspace-model:make-worktree
                         :id "wt-branch" :path "/repo/wt" :branch "feature/x")
                        "feature/x")
                  (list (nerimux/workspace-model:make-worktree
                         :id "wt-path" :path "/repo/wt" :branch "")
                        "/repo/wt")
                  (list (nerimux/workspace-model:make-worktree
                         :id "wt-id" :path "" :branch "")
                        "wt-id")
                  (list nil "-"))))
      (dolist (case repository-cases)
        (expect (string= (second case)
                         (nerimux/renderer::%repository-title-text
                          (first case)))))
      (dolist (case worktree-cases)
        (expect (string= (second case)
                         (nerimux/renderer::%worktree-title-text
                          (first case)))))))

  (it "selects repository directly or through the selected worktree"
    (let* ((repository (nerimux/workspace-model:make-repository :id "repo"))
           (worktree (nerimux/workspace-model:make-worktree :id "wt" :path "/wt"
                                                   :repository repository)))
      (multiple-value-bind (selected-repository selected-worktree)
          (nerimux/renderer::%workspace-title-selection nil repository nil)
        (expect (eq repository selected-repository))
        (expect (null selected-worktree)))
      (multiple-value-bind (selected-repository selected-worktree)
          (nerimux/renderer::%workspace-title-selection nil nil worktree)
        (expect (eq repository selected-repository))
        (expect (eq worktree selected-worktree)))))

  (it "falls back to the focused pane's worktree"
    (let* ((repository (nerimux/workspace-model:make-repository :id "repo"))
           (worktree (nerimux/workspace-model:make-worktree :id "wt" :path "/wt"
                                                   :repository repository))
           (pane (nerimux/pane:make-pane :id 1 :fd -1 :worktree worktree)))
      (multiple-value-bind (selected-repository selected-worktree)
          (nerimux/renderer::%workspace-title-selection pane nil nil)
        (expect (eq repository selected-repository))
        (expect (eq worktree selected-worktree)))))

  (it "builds the terminal title with the em-dash separator"
    (expect (string= (string (code-char #x2014))
                     (nerimux/renderer::%workspace-em-dash)))
    (expect (search "nerimux: team/project — feature/x"
                    (nerimux/renderer::%client-title-osc
                     (nerimux/workspace-model:make-repository
                      :specification "team/project")
                     (nerimux/workspace-model:make-worktree :path "/wt"
                                                  :branch "feature/x"))))))
