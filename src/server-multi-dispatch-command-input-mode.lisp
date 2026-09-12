(in-package #:nerimux)

(defun %client-start-worktree-create (session conn &key (mode :assign))
  (let ((repository (%client-selected-repository conn)))
    (if repository
        (%client-create-detached-worktree repository conn session :mode mode)
        (%client-notify conn "select a repository first")))
  t)

(define-worktree-command-entry %client-start-worktree-delete
                               "wt-delete --confirm"
                               "delete")

(define-worktree-command-entry %client-start-worktree-lock
                               "wt-lock"
                               "lock")

(define-worktree-command-entry %client-start-worktree-unlock
                               "wt-unlock"
                               "unlock")

(defun %focus-selected-client-worktree (session conn &key direct-shell-p)
  "Enter on the selected tree row (R6.3).

   What Enter means depends on the level, and the two upper levels mean
   something the tree had no way to express before: organization, repository,
   and section rows toggle open and closed, so a workspace of a thousand
   repositories opens showing organizations rather than everything at once.
   Enter on a repository used to jump straight into its main or first
   worktree's pane; now it shows the worktrees so the user picks one, since a
   repository can hold several and the one that happened to be first or main
   is not necessarily the one Enter was meant to reach."
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
       (%client-toggle-selected-tree-row conn))
      ((typep object 'nerimux/workspace-model:repository)
       (if (or (nerimux/workspace-model:repository-main-worktree object)
               (nerimux/workspace-model:repository-worktrees object))
           (%client-toggle-selected-tree-row conn)
           (progn
             (setf (gethash (list :repository
                                  (nerimux/workspace-model:repository-id object))
                            (%workspace-expanded-nodes))
                   t)
             (%client-notify conn "no worktree yet: w c creates one")
             (%mark-dirty)
             t)))
      ((typep object 'nerimux/pane:pane)
       (when (%reject-pending-worktree-attachment conn :pane object)
         (return-from %focus-selected-client-worktree nil))
       (%select-client-pane-window session object)
       (%set-client-focus conn object session)
       (worktree-resume (pane-worktree object) object)
       (%remember-worktree-pane (pane-worktree object) object)
       (%set-client-view conn :pane)
       (%mark-dirty)
       t)
      ((and (consp object) (member (first object) '(:file :commit :diff-line :diff-more)))
       t)
      ((typep object 'nerimux/window:window)
       (let ((pane (nerimux/window:window-active-pane object)))
         (when (%reject-pending-worktree-attachment conn :pane pane :window object)
           (return-from %focus-selected-client-worktree nil))
         (when pane
           (%select-client-pane-window session pane)
           (%set-client-focus conn pane session)
           (worktree-resume (pane-worktree pane) pane)
           (%set-client-view conn :pane)))
       (%mark-dirty)
       t)
      (t
       (unless (client-conn-selected-worktree conn)
         (%select-client-tree-worktree conn nil))
       (%open-client-tree-worktree
        session conn
        (if (typep object 'nerimux/workspace-model:worktree)
            object
            (client-conn-selected-worktree conn))
        direct-shell-p)))))

(defun %worktree-enter-pane (worktree)
  "The pane Enter on WORKTREE's tree row lands on (R6.3): the one the user was
   last on there, else the running agent, else any live terminal, else a pane
   that has exited but still has a screen.

   The remembered pane comes first because that is what the requirement asks
   for; it is skipped once it has exited so a live sibling still wins. The
   exited pane is the last resort rather than no pane at all: a failed agent's
   `exited 127' line is exactly what Enter on a flagged row was pressed to
   read, and Assign instead of it hides the failure (NMX-PANES-2/4)."
  (when worktree
    (let ((remembered (%worktree-remembered-pane worktree))
          (panes (worktree-panes worktree)))
      (or (and remembered (pane-live-p remembered) remembered)
          (and (worktree-running-agent-p worktree)
               (nerimux/workspace-model:worktree-agent-pane worktree))
          (find-if (lambda (candidate)
                     (and (pane-live-p candidate)
                          (null (pane-agent-kind candidate))))
                   panes)
          (and remembered (pane-screen remembered) remembered)
          (find-if #'pane-screen panes)))))

(defun %open-client-tree-worktree (session conn worktree direct-shell-p)
  "Enter on WORKTREE: return to its running pane, or open one.

WORKTREE is the row Enter was struck on, not CLIENT-CONN-SELECTED-WORKTREE:
the two drift apart (a pane row selects no worktree, and the prefix keys set
one without moving the tree cursor), and acting on the wrong one drops the
user into another repository's live shell with nothing on screen saying so."
  (let ((pane (%worktree-enter-pane worktree)))
    (when (%reject-pending-worktree-attachment conn :worktree worktree :pane pane)
      (return-from %open-client-tree-worktree nil))
    (cond
      (pane
       (%set-client-selected-tree-object conn worktree)
       (%select-client-pane-window session pane)
       (%set-client-focus conn pane session)
       (worktree-resume worktree pane)
       (%remember-worktree-pane worktree pane)
       (%mark-dirty)
       t)
      (worktree
       (%set-client-selected-tree-object conn worktree)
       (if direct-shell-p
           (when (%open-client-worktree-pane session conn worktree)
             (%set-client-view conn :pane))
           (%client-assign-worktree session conn worktree)))
      (t
       (%client-notify conn "no worktree selected")
       t))))

(defun %select-client-pane-window (session pane)
  "Make PANE's window the session's active one.

Focus alone leaves the session pointing at whichever window was opened last,
so the prefix keys would keep acting on that one while this pane is on screen."
  (let ((window (and pane (nerimux/pane:pane-window pane))))
    (when (and session window)
      (nerimux/session:session-select-window session window)
      (nerimux/window:window-select-pane window pane))))

(defun %client-toggle-selected-file-diff (worktree-id path code)
  "Tab on a :FILE row toggles that file's own inline-diff expansion
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
                    (%client-start-worktree-file-diff-refresh worktree path)))))))))
  (%mark-dirty)
  t)

(defun %client-toggle-selected-tree-row (conn)
  "Toggle expansion for the selected section, repository, worktree, or file.
   Expansion state is stored in the corresponding workspace node table.  A
   worktree without cached commits starts an asynchronous commit refresh, and
   a file delegates to %CLIENT-TOGGLE-SELECTED-FILE-DIFF.  No selection is a
   no-op."
  (let ((object (%client-tree-object conn)))
    (cond
      ((keywordp object)
        (let ((key (list :section object))
              (table (%workspace-collapsed-nodes)))
          (if (gethash key table)
              (remhash key table)
              (setf (gethash key table) t)))
        (%mark-dirty)
        t)
      ((typep object 'nerimux/workspace-model:repository)
        (let ((key
               (list :repository (nerimux/workspace-model:repository-id object)))
              (table (%workspace-expanded-nodes)))
          (if (gethash key table)
              (remhash key table)
              (setf (gethash key table) t)))
        (%mark-dirty)
        t)
      ((typep object 'nerimux/workspace-model:worktree)
        (let ((key
               (list :worktree (nerimux/workspace-model:worktree-id object)))
              (table (%workspace-expanded-nodes)))
          (if (gethash key table)
              (remhash key table)
              (progn
                (setf (gethash key table) t)
                (when 
                    (member
                     (nerimux/workspace-model:worktree-commits-state object)
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
  "Collapse the selected organization, section, or repository row."
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/workspace-model:organization)
        (setf (gethash
               (list :organization
                     (nerimux/workspace-model:organization-id object))
               (%workspace-collapsed-nodes)) t)
        (%mark-dirty)
        t)
      ((keywordp object)
        (setf (gethash (list :section object) (%workspace-collapsed-nodes)) t)
        (%mark-dirty)
        t)
      ((typep object 'nerimux/workspace-model:repository)
        (remhash
         (list :repository (nerimux/workspace-model:repository-id object))
         (%workspace-expanded-nodes))
        (%mark-dirty)
        t)
      (t nil))))

(defun %client-tree-expand-selected (conn)
  "Expand the selected organization, section, or repository row."
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/workspace-model:organization)
        (remhash
         (list :organization (nerimux/workspace-model:organization-id object))
         (%workspace-collapsed-nodes))
        (%mark-dirty)
        t)
      ((keywordp object)
        (remhash (list :section object) (%workspace-collapsed-nodes))
        (%mark-dirty)
        t)
      ((typep object 'nerimux/workspace-model:repository)
        (setf (gethash
               (list :repository (nerimux/workspace-model:repository-id object))
               (%workspace-expanded-nodes)) t)
        (%mark-dirty)
        t)
      (t nil))))

(defun %handle-client-input-key-payload (session conn payload)
  "Every byte, ESC included, is forwarded to the focused pane: VIEW :pane has
   no keyboard exit of its own (that returns with the C-q prefix, R4.4)."
  (%client-clear-pending-close-pane conn)
  (let ((pane
         (or (client-conn-stdin-target conn)
             (%resolve-client-focus-pane session nil conn))))
    (cond
      ((null pane) (%client-notify conn "no focused pane"))
      ((%client-write-pane-payload conn pane payload) nil)
      (t (%client-notify conn "focused pane is unavailable")))
    (%mark-dirty)
    t))


(defun %client-show-selected-status (conn)
  (unless (%client-tree-object conn)
    (%select-client-tree-worktree conn nil))
  (let* ((object (%client-tree-object conn))
         (worktree
           (typecase object
             (nerimux/workspace-model:worktree object)
             (nerimux/workspace-model:repository
              (or (nerimux/workspace-model:repository-main-worktree object)
                  (first (nerimux/workspace-model:repository-worktrees object))))
             (nerimux/pane:pane (nerimux/pane:pane-worktree object)))))
    (if worktree
        (progn
          (%set-client-selected-worktree conn worktree)
          (%set-client-view conn :status)
          ;; F26: the view renders a `loading…` row until a status pass has
          ;; landed, and nothing else asks for one, so `v` waited for whatever
          ;; refresh happened next. This is the refresh `g` runs.
          (unless (nerimux/workspace-model:worktree-status worktree)
            (%client-refresh-workspace conn))
          t)
        (progn
          (%client-notify conn "select a worktree first")
          t))))
