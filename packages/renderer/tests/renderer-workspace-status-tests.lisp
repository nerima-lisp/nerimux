(in-package #:nerimux/test/renderer)

;;;; Unit tests for WORKSPACE-STATUS-ENTRIES / WORKSPACE-STATUS-OBJECTS /
;;;; RENDER-WORKSPACE-STATUS-TO-TUI-STRING (renderer-workspace-status.lisp,
;;;; magit alignment contract §3 Unit STATUS-VIEW).
;;;;
;;;; %EXPECTED-SGR-PARAMS (renderer-tui-kit-tests.lisp) derives the SGR
;;;; assertion from the real CL-TUI-KIT style object rather than a
;;;; hand-computed code string, the same honesty principle
;;;; renderer-tui-kit-help-tests.lisp already applies to the sibling
;;;; full-screen help view -- this file's ASDF registration must load after
;;;; both of those (see the orchestrator report).
(defun %build-status-fixture (&key (branch "feature/status")
                                   head
                                   ahead
                                   behind
                                   unmerged
                                   untracked
                                   unstaged
                                   staged
                                   stashes
                                   stashes-state
                                   commits
                                   commits-state
                                   panes
                                   sibling-p)
  "One worktree under one repository, optionally with a sibling worktree
   (SIBLING-P) -- REPOSITORY-ADD-WORKTREE, not a bare MAKE-REPOSITORY
   :WORKTREES list, so WORKTREE-REPOSITORY is actually wired (Unit
   STATUS-VIEW reads it for the Worktrees section and the frame header;
   MAKE-REPOSITORY alone never sets a worktree's back-pointer). Returns
   (VALUES WORKTREE REPOSITORY SIBLING-OR-NIL)."
  (let* ((worktree
          (nerimux/workspace-model:make-worktree :id
                                                 "wt-status"
                                                 :path
                                                 "/repo/wt"
                                                 :branch
                                                 branch
                                                 :head
                                                 head
                                                 :ahead
                                                 (or ahead 0)
                                                 :behind
                                                 (or behind 0)
                                                 :unmerged-files
                                                 unmerged
                                                 :untracked-files
                                                 untracked
                                                 :unstaged-files
                                                 unstaged
                                                 :staged-files
                                                 staged
                                                 :stashes
                                                 stashes
                                                 :stashes-state
                                                 stashes-state
                                                 :recent-commits
                                                 commits
                                                 :commits-state
                                                 commits-state
                                                 :panes
                                                 panes))
         (repository
          (nerimux/workspace-model:make-repository :id
                                                   "repo-status"
                                                   :specification
                                                   "github.com/team/status"
                                                   :local-path
                                                   "/repo"))
         (sibling
          (and sibling-p
               (nerimux/workspace-model:make-worktree :id
                                                      "wt-sibling"
                                                      :path
                                                      "/repo/other"
                                                      :branch
                                                      "main"))))
    (nerimux/workspace-model:repository-add-worktree repository worktree)
    (when sibling
      (nerimux/workspace-model:repository-add-worktree repository sibling))
    (values worktree repository sibling)))

(defun %status-entry-kinds (entries)
  (mapcar #'fourth entries))

(defun %status-section-keys (entries)
  "The OBJECT of every :SECTION-kind entry, in order -- the section identity
   contract §3 fixes: :UNMERGED :UNTRACKED :UNSTAGED :STAGED :STASHES
   :COMMITS :PANES :WORKTREES."
  (mapcar #'third
          (remove-if-not
           (lambda (e)
             (eq (fourth e) :section))
           entries)))

(describe "renderer-suite/workspace-status-entries"

  (it "orders every section Head, Unmerged, Untracked, Unstaged, Staged, Stashes, Commits, Panes, Worktrees"
    (multiple-value-bind (worktree)
        (%build-status-fixture
         :unmerged '(("UU" . "conflict.txt"))
         :untracked '(("??" . "new.txt"))
         :unstaged '(("M" . "unstaged.txt"))
         :staged '(("M" . "staged.txt"))
         :stashes '(("stash@{0}" . "WIP on main"))
         :stashes-state :ready
         :commits '(("abc1234" . "a commit"))
         :commits-state :ready
         :panes (list (nerimux/pane:make-pane :id 1 :fd -1 :title "shell"))
         :sibling-p t)
      (let ((entries (nerimux/renderer:workspace-status-entries worktree)))
        (expect (eq :head (fourth (first entries))))
        (expect (equal '(:unmerged :untracked :unstaged :staged
                          :stashes :commits :panes :worktrees)
                       (%status-section-keys entries))))))

  (it "omits every optional section for a clean worktree but keeps Head"
    (multiple-value-bind (worktree) (%build-status-fixture)
      (let ((entries (nerimux/renderer:workspace-status-entries worktree)))
        (expect (equal '(:head) (%status-entry-kinds entries))))))

  (it "drops Head entirely for a worktree with neither a branch nor a HEAD"
    (multiple-value-bind (worktree) (%build-status-fixture :branch nil)
      (expect (null (nerimux/renderer:workspace-status-entries worktree)))))

  (it "carries a live count in each section header, including a pending placeholder"
    (multiple-value-bind (worktree)
        (%build-status-fixture
         :unstaged '(("M" . "a.txt") ("M" . "b.txt"))
         :staged '(("A" . "c.txt"))
         :stashes-state :pending)
      (let* ((entries (nerimux/renderer:workspace-status-entries worktree))
             (headers (remove-if-not (lambda (e) (eq (fourth e) :section)) entries)))
        (expect (find-if (lambda (e) (search "Unstaged changes (2)" (second e))) headers))
        (expect (find-if (lambda (e) (search "Staged changes (1)" (second e))) headers))
        ;; A :PENDING stash group has no STASHES entries yet, but still shows
        ;; one placeholder row -- so its header counts 1, not 0, and the
        ;; section is not omitted (contract's own commits/stash convention,
        ;; renderer-workspace-tree.lisp).
        (expect (find-if (lambda (e) (search "Stashes (1)" (second e))) headers))
        (expect (find-if (lambda (e) (search "stashes: refreshing..." (second e))) entries)))))

  (it "keeps WORKSPACE-STATUS-OBJECTS in lockstep with WORKSPACE-STATUS-ENTRIES"
    (multiple-value-bind (worktree)
        (%build-status-fixture
         :unstaged '(("M" . "a.txt"))
         :staged '(("A" . "b.txt"))
         :commits '(("abc1234" . "one") ("def5678" . "two"))
         :commits-state :ready
         :sibling-p t)
      (let ((entries (nerimux/renderer:workspace-status-entries worktree)))
        (expect (equal (mapcar #'third entries)
                       (nerimux/renderer:workspace-status-objects worktree)))))))

(describe "renderer-suite/workspace-status-visibility-levels"

  (it "shows section headings only at level 1"
    (multiple-value-bind (worktree)
        (%build-status-fixture :unstaged '(("M" . "a.txt")))
      (let ((entries (nerimux/renderer:workspace-status-entries
                      worktree :visibility-level 1)))
        (expect (equal '(:head :section) (%status-entry-kinds entries))))))

  (it "shows section contents but not file diffs at level 2"
    (multiple-value-bind (worktree)
        (%build-status-fixture :unstaged '(("M" . "a.txt")))
      (let ((entries (nerimux/renderer:workspace-status-entries
                      worktree :visibility-level 2)))
        (expect (equal '(:head :section :file) (%status-entry-kinds entries))))))

  (it "also expands file diffs at level 3 and 4"
    (multiple-value-bind (worktree)
        (%build-status-fixture :unstaged '(("M" . "a.txt")))
      (let ((file-diffs (make-hash-table :test #'equal)))
        (setf (gethash (list "wt-status" "a.txt") file-diffs)
              (list :ready 2 (list "+added" "-removed")))
        (dolist (level '(3 4))
          (let ((entries (nerimux/renderer:workspace-status-entries
                          worktree :visibility-level level :file-diffs file-diffs)))
            (expect (equal '(:head :section :file :diff-line :diff-line)
                           (%status-entry-kinds entries))))))))

  (it "shows an untracked file's diff placeholder without a file-diffs cache entry"
    (multiple-value-bind (worktree)
        (%build-status-fixture :untracked '(("??" . "new.txt")))
      (let ((entries (nerimux/renderer:workspace-status-entries
                      worktree :visibility-level 3)))
        (expect (equal '(:head :section :file :diff-line) (%status-entry-kinds entries)))
        (expect (search "(untracked file)" (second (fourth entries)))))))

  (it "does not destroy an explicit per-row override when the level changes (a lens, not a write)"
    (multiple-value-bind (worktree)
        (%build-status-fixture :unstaged '(("M" . "a.txt")))
      (let ((expanded (make-hash-table :test #'equal)))
        ;; Explicitly COLLAPSE the Unstaged section (a TAB toggle), overriding
        ;; level 2's own "sections expanded" default.
        (setf (gethash (list :status-section :unstaged) expanded) nil)
        (let ((at-level-2 (nerimux/renderer:workspace-status-entries
                           worktree :visibility-level 2 :expanded-node-ids expanded)))
          (expect (equal '(:head :section) (%status-entry-kinds at-level-2))))
        ;; Level 4 never touches EXPANDED -- the explicit override still wins.
        (let ((at-level-4 (nerimux/renderer:workspace-status-entries
                           worktree :visibility-level 4 :expanded-node-ids expanded)))
          (expect (equal '(:head :section) (%status-entry-kinds at-level-4))))
        ;; Pressing 4 then 2 again reproduces exactly the level-2 rows.
        (let ((at-level-2-again (nerimux/renderer:workspace-status-entries
                                 worktree :visibility-level 2 :expanded-node-ids expanded)))
          (expect (equal '(:head :section) (%status-entry-kinds at-level-2-again))))))))

(describe "renderer-suite/workspace-status-render"

  (it "renders the header, branch, section headings, and status codes"
    (multiple-value-bind (worktree)
        (%build-status-fixture
         :head "abc1234" :ahead 2 :behind 1
         :unstaged '(("M" . "unstaged.txt"))
         :staged '(("A" . "staged.txt")))
      (let* ((output (nerimux/renderer:render-workspace-status-to-tui-string
                      worktree 24 80))
             (visible (strip-sgr output)))
        (expect (search "STATUS" visible))
        (expect (search "feature/status" visible))
        (expect (search "Unstaged changes (1)" visible))
        (expect (search "Staged changes (1)" visible))
        (expect (search "unstaged.txt" visible))
        (expect (search "staged.txt" visible))
        ;; Section headings carry the Dracula-purple heading style, derived
        ;; from the real style object (see file header comment).
        (expect output :to-contain-sgr
                (%expected-sgr-params (nerimux/renderer::%workspace-status-style-heading))))))

  (it "still renders a complete frame on a short terminal (no key panel, no message row)"
    (multiple-value-bind (worktree) (%build-status-fixture :unstaged '(("M" . "a.txt")))
      (let ((output (nerimux/renderer:render-workspace-status-to-tui-string worktree 8 40)))
        (expect (stringp output))
        (expect (search "STATUS" (strip-sgr output))))))

  (it "falls back to a full-screen transient when it is taller than the key panel"
    (multiple-value-bind (worktree) (%build-status-fixture)
      (let ((transient
              (nerimux/renderer:make-transient-view
               :title "Push" :subtitle nil :arguments nil
               :actions (list (list #\p "push")))))
        ;; A transient panel only ever gets 1-2 rows in this view
        ;; (%WORKSPACE-STATUS-PANEL-ROWS-AVAILABLE); TRANSIENT-VIEW-HEIGHT
        ;; for a titled panel with one action already exceeds that, so this
        ;; exercises the full-screen fallback without needing to fabricate
        ;; an artificially tall TRANSIENT-VIEW.
        (let ((output (nerimux/renderer:render-workspace-status-to-tui-string
                       worktree 24 80 :transient transient)))
          (expect (search "Push" (strip-sgr output))))))))
