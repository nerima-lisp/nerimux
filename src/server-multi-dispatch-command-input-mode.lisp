(in-package #:nerimux)

;; %client-enter-input-mode retired with the `i` key it existed to implement
;; (magit alignment, FR-007): its only production caller was the old
;; %handle-client-normal-key-payload's `#\i` clause, and with :pane keys now
;; going straight to the shell (%client-ui-keys-p), there is no mode left to
;; enter -- grepping the bare identifier turned up no other call site.

(defun %client-enter-command-mode (conn &optional (initial-buffer ""))
  (setf (client-conn-command-return-view conn)
        (client-conn-view conn))
  (%set-client-modal conn :command)
  (setf (client-conn-command-buffer conn)
        (if (stringp initial-buffer) initial-buffer ""))
  (%mark-dirty)
  t)

(defun %client-restore-command-view (conn)
  (let ((view (client-conn-command-return-view conn)))
    (when (member view '(:repolist :status :pane) :test #'eq)
      (setf (client-conn-view conn) view))
    (setf (client-conn-command-return-view conn) nil)))

(defun %client-select-pane-direction (session conn direction)
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (window (and pane (nerimux/pane:pane-window pane))))
    ;; R5.6: a zoomed window has no neighbours (pane-neighbor returns NIL by
    ;; design), so un-zoom before looking one up rather than reporting "no
    ;; pane <direction>" for a move that would otherwise have succeeded.
    (%workspace-prefix-unzoom window)
    (let ((neighbor (and window (pane-neighbor window pane direction))))
      (if neighbor
          (progn
            (%set-client-focus conn neighbor)
            (%mark-dirty)
            t)
          (progn
            (%client-notify conn (format nil "no pane ~A" direction))
            t)))))

(defun %client-worktree-create-branch-name ()
  "An auto-generated branch name for `n` (item 5): wt-<YYYYmmddTHHMMSS>, built
   from DECODE-UNIVERSAL-TIME rather than a date-formatting library -- this
   codebase has no such dependency, and adding one for a single timestamp
   string would be disproportionate."
  (multiple-value-bind (second minute hour date month year)
      (decode-universal-time (get-universal-time))
    (format nil "wt-~4,'0D~2,'0D~2,'0DT~2,'0D~2,'0D~2,'0D"
            year month date hour minute second)))

(defun %client-start-worktree-create (session conn)
  "n (item 5, user decision): create a worktree immediately, with an
   auto-generated branch name, for the selected repository, and jump straight
   into its shell -- no branch prompt in between. This replaces the old
   behaviour of pre-filling `:` command mode with \"wt-create --branch \";
   `:wt-create --branch <name> --confirm` still exists for a user-chosen
   branch name and still requires --confirm (%CLIENT-CREATE-WORKTREE)."
  (let ((repository (%client-selected-repository conn)))
    (if repository
        (%client-create-worktree-now
         repository (%client-worktree-create-branch-name) conn session)
        (%client-notify conn "select a repository first")))
  t)

(define-worktree-command-entry %client-start-worktree-delete
  "wt-delete --confirm"
  "delete")

(define-worktree-command-entry %client-start-worktree-lock
  "wt-lock --confirm"
  "lock")

(define-worktree-command-entry %client-start-worktree-unlock
  "wt-unlock --confirm"
  "unlock")

(defun %focus-selected-client-worktree (session conn)
  "Enter on the selected tree row (R6.3).

   What Enter means depends on the level, and the two upper levels mean
   something the tree had no way to express before: organization and repository
   rows toggle open and closed, so a workspace of a thousand repositories opens
   showing organizations rather than everything at once. Enter on those used to
   start a worktree-create prompt — which made the create flow reachable but
   left expansion with no key at all."
  ;; A fresh client has no selection, so %client-tree-object returns nil and
  ;; every typep below misses; the dispatch must not typecase a nil selection.
  ;; This fallback used to live inside the catch-all (t) branch, which made
  ;; the FIRST Enter a no-op "primer" that only set up state for the second.
  (unless (%client-tree-object conn)
    (%select-client-tree-worktree conn nil))
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/workspace-model:organization)
       (%toggle-workspace-node-collapsed
        :organization (nerimux/workspace-model:organization-id object))
       (%mark-dirty)
       t)
      ((keywordp object)
       ;; A :SECTION row (its OBJECT is the section keyword itself --
       ;; :ATTENTION/:ACTIVE/:REPOSITORIES): Enter toggles it exactly like
       ;; Tab (%CLIENT-TOGGLE-SELECTED-TREE-ROW).
       (%client-toggle-selected-tree-row conn))
      ((typep object 'nerimux/workspace-model:repository)
       ;; Enter no longer toggles a repository row open/closed (user
       ;; decision, R6.3 pivot): it dives straight into the repository's
       ;; main worktree (or its first one, when there is no main) via the
       ;; SAME open/attach corridor as the (t) worktree branch below --
       ;; recursing after selecting the worktree reuses that branch instead
       ;; of duplicating its remembered-pane/open-pane logic here.
       (let ((worktree (or (nerimux/workspace-model:repository-main-worktree object)
                            (first (nerimux/workspace-model:repository-worktrees
                                    object)))))
         (if worktree
             (progn
               (%set-client-selected-tree-object conn worktree)
               (%focus-selected-client-worktree session conn))
             (progn
               (%client-notify conn "repository has no worktrees")
               t))))
      ((typep object 'nerimux/pane:pane)
       (%set-client-focus conn object)
       (%set-client-view conn :pane)
       (%mark-dirty)
       t)
      ;; Inline worktree expansion (Wave B): a :FILE or :COMMIT row's OBJECT
      ;; is a plain (:FILE ...) / (:COMMIT ...) list (D3), never a model
      ;; struct or the section keyword handled above -- Enter on either is a
      ;; deliberate no-op this wave (no diff/log view exists yet), not a
      ;; fallthrough into the (T ...) worktree-open branch below, which
      ;; would otherwise open or create a pane the user never asked for.
      ;; :DIFF-LINE/:DIFF-MORE (Wave C, a :FILE row's own inline-diff child
      ;; rows) join the same no-op for the same reason -- Tab, not Enter, is
      ;; their only action.
      ((and (consp object) (member (first object) '(:file :commit :diff-line :diff-more)))
       t)
      ((typep object 'nerimux/window:window)
       (let ((pane (nerimux/window:window-active-pane object)))
         (when pane
           (%set-client-focus conn pane)
           (%set-client-view conn :pane)))
       (%mark-dirty)
       t)
      (t
       (unless (client-conn-selected-worktree conn)
         (%select-client-tree-worktree conn nil))
       (let* ((worktree (client-conn-selected-worktree conn))
              ;; The pane last focused in this worktree, so Enter returns to
              ;; where the user was rather than to whichever pane happens to be
              ;; first (R6.3).
              (pane (or (%worktree-remembered-pane worktree)
                        (%client-worktree-pane session worktree))))
         (cond
           ((and pane (nerimux/pane:pane-live-p pane))
            (%set-client-focus conn pane)
            (%remember-worktree-pane worktree pane)
            (%mark-dirty)
            t)
           (worktree
            (or (%open-client-worktree-pane session conn worktree) t))
           (t
            (%client-notify conn "no worktree selected")
            t)))))))

(defun %client-start-worktree-commits-refresh (worktree)
  "Launch an async recent-commit fetch for WORKTREE (D2/Wave B), mirroring
   %WORKSPACE-PREFIX-FETCH-REPOSITORY's dispatch wiring (server-multi-
   dispatch-prefix.lisp): CALLBACK-DISPATCH marshals the worker's completion
   back onto the main event loop, where both outcomes just need a redraw --
   REFRESH-WORKTREE-COMMITS-ASYNC has already written WORKTREE's two slots
   by the time either callback runs. The caller sets COMMITS-STATE :PENDING
   before calling this, which is also the dedup guard: this is only ever
   called when COMMITS-STATE was NIL or :FAILED."
  (handler-case
      (nerimux/vcs:refresh-worktree-commits-async
       (nerimux/workspace-model:worktree-repository worktree) worktree
       :callback-dispatch #'%enqueue-main-thread-callback
       :on-complete (lambda (result) (declare (ignore result)) (%mark-dirty))
       :on-error (lambda (condition) (declare (ignore condition)) (%mark-dirty)))
    ;; Kicking the async refresh off itself failed synchronously (e.g.
    ;; thread creation) -- same shape as %ADD-CLIENT's catalog-refresh
    ;; launch: no callback is ever coming, so COMMITS-STATE must settle to
    ;; :FAILED here rather than being stuck at :PENDING forever.
    (error ()
      (setf (nerimux/workspace-model:worktree-commits-state worktree) :failed)
      (%mark-dirty))))

(defun %client-start-worktree-file-diff-refresh (worktree path)
  "Launch an async `git diff -- PATH` fetch for WORKTREE (Wave C), mirroring
   %CLIENT-START-WORKTREE-COMMITS-REFRESH's wiring exactly: CALLBACK-
   DISPATCH marshals the worker's completion back onto the main event loop,
   where both outcomes write *WORKSPACE-FILE-DIFFS* and just need a redraw.
   Unlike the commits refresh, there is no domain-model slot to write --
   REFRESH-WORKTREE-FILE-DIFF-ASYNC's ON-COMPLETE hands back the raw worker
   result, so this closure is what turns it into the cache entry the
   renderer reads. The caller sets the cache entry to :PENDING before
   calling this, which is also the dedup guard: this is only ever called
   when the entry was absent or :FAILED."
  (let ((key (list (nerimux/workspace-model:worktree-id worktree) path)))
    (flet ((%on-error (condition)
             (declare (ignore condition))
             (%set-workspace-file-diff key (list :failed 0 nil))
             (%mark-dirty)))
      (handler-case
          (nerimux/vcs:refresh-worktree-file-diff-async
           (nerimux/workspace-model:worktree-repository worktree) worktree path
           :callback-dispatch #'%enqueue-main-thread-callback
           :on-complete
           (lambda (worker-result)
             (%set-workspace-file-diff
              key
              (if (eq (first worker-result) :ready)
                  (list :ready (second worker-result) (cddr worker-result))
                  (list :failed 0 nil)))
             (%mark-dirty))
           :on-error #'%on-error)
        ;; Kicking the async refresh off itself failed synchronously (e.g.
        ;; thread creation) -- same shape as %CLIENT-START-WORKTREE-COMMITS-
        ;; REFRESH's own guard: no callback is ever coming otherwise, so the
        ;; entry must settle to :FAILED here rather than being stuck at
        ;; :PENDING forever.
        (error (condition) (%on-error condition))))))

(defun %client-toggle-selected-file-diff (worktree-id path code)
  "Tab on a :FILE row (Wave C): toggle that file's own inline-diff expansion
   in *WORKSPACE-EXPANDED-NODE-IDS*, keyed (:FILE-DIFF WORKTREE-ID PATH) --
   deliberately NOT the row's own %WORKSPACE-TREE-NODE-KEY, which embeds
   CODE and would drift out of sync with the expansion table the moment the
   file's status changes between an expand and the next status refresh.
   An untracked file (CODE \"??\") has nothing to diff against HEAD --
   %WORKSPACE-WORKTREE-FILE-DIFF-ENTRIES renders its placeholder row from
   CODE alone, so expanding it here never touches the cache or launches a
   fetch. Otherwise, expanding with no cache entry yet (or the last fetch
   failed) launches the fetch; expanding again while :PENDING is a no-op
   dedup, and expanding a :READY entry just reveals the cached rows."
  (let ((key (list :file-diff worktree-id path))
        (table (%workspace-expanded-nodes)))
    (if (gethash key table)
        (remhash key table)
        (progn
          (setf (gethash key table) t)
          (unless (string= code "??")
            (let* ((cache-key (list worktree-id path))
                   (entry (gethash cache-key (%workspace-file-diffs))))
              (when (member (first entry) '(nil :failed))
                (let ((worktree (%workspace-find-worktree worktree-id)))
                  (when worktree
                    (%set-workspace-file-diff cache-key (list :pending 0 nil))
                    (%client-start-worktree-file-diff-refresh
                     worktree path)))))))))
  (%mark-dirty)
  t)

(defun %client-toggle-selected-tree-row (conn)
  "Tab, and Enter on a :SECTION row (section-based overview redesign): toggle
   the selected row's own expand/collapse state. A :SECTION row (its OBJECT
   is the section keyword) toggles that section in *WORKSPACE-COLLAPSED-
   NODE-IDS* (absent = expanded); a REPOSITORY row under Repositories
   toggles its worktrees in *WORKSPACE-EXPANDED-NODE-IDS* (absent =
   collapsed -- the opposite polarity, since repository rows default
   collapsed). A WORKTREE row (Wave B) toggles its own inline expansion in
   the SAME *WORKSPACE-EXPANDED-NODE-IDS* table, keyed (:WORKTREE ID); the
   first time it expands with no commit history fetched yet (or the last
   fetch failed), this also kicks off the async commit-log fetch. A :FILE
   row (Wave C) toggles its own inline diff the same way -- see
   %CLIENT-TOGGLE-SELECTED-FILE-DIFF. No selection has no expand state of
   its own and is a no-op."
  (let ((object (%client-tree-object conn)))
    (cond
      ((keywordp object)
       (let ((key (list :section object))
             (table (%workspace-collapsed-nodes)))
         (if (gethash key table) (remhash key table) (setf (gethash key table) t)))
       (%mark-dirty)
       t)
      ((typep object 'nerimux/workspace-model:repository)
       (let ((key (list :repository (nerimux/workspace-model:repository-id object)))
             (table (%workspace-expanded-nodes)))
         (if (gethash key table) (remhash key table) (setf (gethash key table) t)))
       (%mark-dirty)
       t)
      ((typep object 'nerimux/workspace-model:worktree)
       (let ((key (list :worktree (nerimux/workspace-model:worktree-id object)))
             (table (%workspace-expanded-nodes)))
         (if (gethash key table)
             (remhash key table)
             (progn
               (setf (gethash key table) t)
               (when (member (nerimux/workspace-model:worktree-commits-state object)
                             '(nil :failed))
                 (setf (nerimux/workspace-model:worktree-commits-state object) :pending)
                 (%client-start-worktree-commits-refresh object)))))
       (%mark-dirty)
       t)
      ((and (consp object) (eq (first object) :file))
       (destructuring-bind (worktree-id path code) (rest object)
         (%client-toggle-selected-file-diff worktree-id path code)))
      (t nil))))

(defun %client-tree-collapse-selected (conn)
  "H (item 3): collapse the selected row. An organization row (reachable
   only via direct selection now, never via tree navigation -- see the
   section-based redesign's header comment in renderer-workspace-tree.lisp)
   or a :SECTION row folds; a REPOSITORY row under Repositories folds its
   worktrees (*WORKSPACE-EXPANDED-NODE-IDS*, default-collapsed polarity).
   Any other row (a worktree; no selection) has no collapse state of its own
   in the section-based tree and is a no-op."
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/workspace-model:organization)
       (setf (gethash (list :organization
                            (nerimux/workspace-model:organization-id object))
                      (%workspace-collapsed-nodes))
             t)
       (%mark-dirty)
       t)
      ((keywordp object)
       (setf (gethash (list :section object) (%workspace-collapsed-nodes)) t)
       (%mark-dirty)
       t)
      ((typep object 'nerimux/workspace-model:repository)
       (remhash (list :repository (nerimux/workspace-model:repository-id object))
                (%workspace-expanded-nodes))
       (%mark-dirty)
       t)
      (t nil))))

(defun %client-tree-expand-selected (conn)
  "L (item 3): expand the selected row -- the inverse of H above."
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/workspace-model:organization)
       (remhash (list :organization (nerimux/workspace-model:organization-id object))
                (%workspace-collapsed-nodes))
       (%mark-dirty)
       t)
      ((keywordp object)
       (remhash (list :section object) (%workspace-collapsed-nodes))
       (%mark-dirty)
       t)
      ((typep object 'nerimux/workspace-model:repository)
       (setf (gethash (list :repository (nerimux/workspace-model:repository-id object))
                      (%workspace-expanded-nodes))
             t)
       (%mark-dirty)
       t)
      (t nil))))

(defun %client-enter-tree-filter-mode (conn)
  "`/` always starts from an empty query (vim's `/` semantics), even when a
   previous filter session ended with Enter and left CONN-TREE-FILTER set
   (the tree-filter modal's ESC/Enter asymmetry, contract SS5, keeps it on
   exit, precisely so the filtered view survives into ordinary navigation)
   -- without resetting it here, the next `/` silently prepended new
   keystrokes onto that old query instead of starting fresh."
  (setf (client-conn-tree-filter conn) nil
        (client-conn-tree-scroll conn) 0)
  (%set-client-modal conn :filter)
  (%mark-dirty)
  t)

(defun %handle-client-input-key-payload (session conn payload)
  "Every byte, ESC included, is forwarded to the focused pane: VIEW :pane has
   no keyboard exit of its own (that returns with the C-q prefix, R4.4)."
  (let ((pane (or (client-conn-stdin-target conn)
                  (%resolve-client-focus-pane session nil conn))))
    (cond
      ((null pane)
       (%client-notify conn "no focused pane"))
      ((pane-live-p pane)
       (handler-case
           (nerimux/pty:pty-write (pane-fd pane) payload)
         (peer-io-failure (condition)
           (%client-notify
            conn
            (format nil "input failed: ~A" condition)))))
      ((pane-screen pane)
       (pane-feed pane payload))
      (t
       (%client-notify conn "focused pane is unavailable")))
    (%mark-dirty)
    t))
