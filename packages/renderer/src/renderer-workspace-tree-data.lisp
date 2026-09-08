(in-package #:nerimux/renderer)

(defun %repository-attention-p (repository)
  "T when REPOSITORY itself, or any worktree under it, needs attention."
  (or (repository-dirty-p repository)
      (repository-conflict-p repository)
      (plusp (repository-ahead repository))
      (plusp (repository-behind repository))
      (repository-missing-p repository)
      (some #'worktree-attention-p (repository-worktrees repository))))

(defun %worktree-tree-windows (worktree)
  "Distinct windows holding at least one of WORKTREE's panes, ordered by
   window id -- the order the tree and status line show them in (R5.8)."
  (sort
   (remove-duplicates (mapcar #'pane-window (worktree-panes worktree))
                      :test
                      #'eq)
   #'<
   :key
   #'window-id))

(defun %workspace-tree-node-key (node)
  "Stable, EQUAL-comparable identity for a tree row. Covers a struct-backed
   organization/repository/worktree/window/pane row, a cons-keyed :FILE/
   :COMMIT/:DIFF-LINE/:DIFF-MORE inline-expansion row, and a
   :SECTION row keyed by its own keyword (:ATTENTION/:ACTIVE/:REPOSITORIES)
   via the fallback branch below. Used both for tree-widget selection and,
   at the section and repository levels, as the collapse/expand-state
   table's key."
  (typecase node
    (organization (list :organization (organization-id node)))
    (repository (list :repository (repository-id node)))
    (worktree (list :worktree (worktree-id node)))
    (window (list :window (window-id node)))
    (pane (list :pane (window-id (pane-window node)) (pane-id node)))
    (cons node)
    (t (list :workspace-object node))))

(defun %workspace-node-expanded-p (kind id collapsed-node-ids)
  "T unless the (KIND ID) organization/repository row is marked collapsed in
   COLLAPSED-NODE-IDS (a hash-table of tree-node keys -> T, or NIL). Rows
   absent from the table are expanded. Worktree/window/pane rows have no
   collapse state of their own; once both ancestors are not collapsed,
   everything under a worktree shows."
  (not (and collapsed-node-ids (gethash (list kind id) collapsed-node-ids))))

(defun %organization-tree-label (organization)
  (let ((host (organization-host organization))
        (name (organization-name organization)))
    (cond
      ((and (plusp (length host)) (plusp (length name)))
       (format nil "~A/~A" host name))
      ((plusp (length host)) host)
      ((plusp (length name)) name)
      (t (organization-id organization)))))

(defun %strip-dot-git-suffix (name)
  "NAME with a trailing \".git\" removed (case-insensitively), unless NAME
   is nothing but \".git\" itself -- in which case stripping it would leave
   an empty label, so NAME is returned unchanged."
  (if (and (> (length name) 4)
           (string-equal name ".git" :start1 (- (length name) 4)))
      (subseq name 0 (- (length name) 4))
      name))

(defun %repository-tree-label (repository)
  "Repository row label: the repository name from the final segment of
   SPECIFICATION, with a trailing `.git' removed. When SPECIFICATION is
   empty, use LOCAL-PATH or ID. The organization row supplies the host and
   organization context."
  (let ((specification (repository-specification repository)))
    (if (plusp (length specification))
        (let ((slash (position #\/ specification :from-end t)))
          (%strip-dot-git-suffix
           (if slash
               (subseq specification (1+ slash))
               specification)))
        (or
         (and (plusp (length (repository-local-path repository)))
              (repository-local-path repository))
         (repository-id repository)))))

(defun %worktree-tree-label (worktree)
  "WORKTREE's tree-row label: BRANCH when set; otherwise \"(bare)\" for a
   bare worktree (WORKTREE-BARE-P) rather than its full PATH, which read as
   noise on a bare root row in real-terminal smoke testing -- a bare
   worktree's path is rarely meaningful to look at and every row already
   crowds a full path into a single line; otherwise PATH, then ID, exactly
   as before."
  (let ((branch (worktree-branch worktree))
        (path (worktree-path worktree)))
    (cond
      ((and branch (plusp (length branch))) branch)
      ((worktree-bare-p worktree) "(bare)")
      ((plusp (length path)) path)
      (t (worktree-id worktree)))))

(defun worktree-notification-label (worktree)
  "Return the compact workspace label used for an agent notification."
  (let* ((repository (worktree-repository worktree))
         (organization (and repository (repository-organization repository))))
    (if (and organization repository)
        (format nil
                "~A/~A · ~A"
                (%organization-tree-label organization)
                (%repository-tree-label repository)
                (%worktree-tree-label worktree))
        (%worktree-tree-label worktree))))

(defun %window-tree-label (window)
  "WINDOW's tree-row label: id + name. NAME is already branch + sequence
   number (R5.8, computed once at window-creation time in
   workspace-window.lisp) -- this only formats it, it does not recompute it."
  (format nil "win ~D:~A" (window-id window) (window-name window)))

(defun %pane-tree-label (pane)
  (format nil
          "pane/~D ~A"
          (pane-id pane)
          (or (and (plusp (length (pane-title pane))) (pane-title pane))
              (and (plusp (length (pane-start-command pane)))
                   (pane-start-command pane))
              "shell")))

(defun %workspace-tree-node-attention-p (object kind)
  "T when OBJECT (a KIND tree node) should carry the `!` attention mark."
  (case kind
    (:organization (or (plusp (organization-attention-count object))
                        (organization-attention-worktrees object)))
    (:repository (%repository-attention-p object))
    (:worktree (worktree-attention-p object))
    (:pane (pane-attention-p object))
    (:section nil)
    (t nil)))

(defun %workspace-node-refresh-tag (kind id refreshing-ids stale-ids)
  "Return the refresh-state suffix for an organization, repository, or worktree."
  (let ((key (list kind id)))
    (cond
      ((and refreshing-ids (gethash key refreshing-ids)) " refreshing")
      ((and stale-ids (gethash key stale-ids)) " stale")
      (t ""))))

(defun %worktree-relative-time-text (universal-time)
  "ASCII relative-time label for UNIVERSAL-TIME (a GET-UNIVERSAL-TIME
   integer, or NIL for \"never\"): \"now\" under a minute, then Nm/Nh/Nd.
   Plain ASCII, never an arrow glyph -- the UI theme convention bans
   ambiguous-width characters, which is exactly the class the obvious
   compact alternatives (arrows, clock glyphs) fall into."
  (when universal-time
    (let ((delta (max 0 (- (get-universal-time) universal-time))))
      (cond
        ((< delta 60) "now")
        ((< delta 3600) (format nil "~Dm" (floor delta 60)))
        ((< delta 86400) (format nil "~Dh" (floor delta 3600)))
        (t (format nil "~Dd" (floor delta 86400)))))))

(defun %worktree-last-activity-time (worktree)
  "The most recent of every pane's LAST-OUTPUT-TIME/LAST-FOCUSED-TIME under
   WORKTREE (both GET-UNIVERSAL-TIME integers or NIL, set by
   PANE-MARK-OUTPUT/PANE-MARK-FOCUSED in pane-core.lisp), or NIL when none
   of them has ever fired."
  (let (latest)
    (dolist (pane (worktree-panes worktree) latest)
      (dolist
          (time
           (list (pane-last-output-time pane) (pane-last-focused-time pane)))
        (when (and time (or (null latest) (> time latest)))
          (setf latest time))))))

(defun %worktree-ahead-behind-parts (worktree)
  "List of (TEXT . SGR) pairs for WORKTREE's nonzero ahead/behind counts,
   ahead first -- \"+N\"/\"-N\" (ASCII, never the ambiguous-width arrow
   glyphs)."
  (append
   (when (plusp (worktree-ahead worktree))
     (list (cons (format nil "+~D" (worktree-ahead worktree)) +sgr-ahead+)))
   (when (plusp (worktree-behind worktree))
     (list (cons (format nil "-~D" (worktree-behind worktree)) +sgr-behind+)))))

(defun %worktree-pane-count-text (worktree)
  (format nil "terminal:~D"
          (count-if-not #'nerimux/pane:pane-agent-kind (worktree-panes worktree))))

(defun %worktree-agent-text (worktree)
  (let* ((state (nerimux/pane:worktree-agent-state worktree))
         (completed (nerimux/workspace-model:worktree-completed-p worktree))
         (agent (nerimux/workspace-model:worktree-agent-pane worktree))
         (kind (and agent (nerimux/pane:pane-agent-kind agent))))
    (if (nerimux/workspace-model:worktree-waiting-p worktree)
        "agent:WAITING"
        (format nil "agent:~A~A~A"
                (if (and completed (not (eq state :running))) "COMPLETED" state)
                (if (and completed (eq state :running)) "+COMPLETED" "")
                (case kind (:codex "/Codex") (:claude "/Claude") (t ""))))))

(defun %worktree-state-tag (worktree)
  "The single most salient %WORKTREE-STATUS-TOKENS entry for the info
   cluster, excluding AHEAD/BEHIND (those get their own cluster field so
   would otherwise show twice). Falls back to \"CLEAN\" when every token
   present is an AHEAD/BEHIND count, matching %WORKTREE-STATUS-TOKENS'S own
   CLEAN-when-nothing-else-applies default."
  (or
   (find-if
    (lambda (token)
      (not
       (or (and (>= (length token) 5) (string= (subseq token 0 5) "AHEAD"))
           (and (>= (length token) 6) (string= (subseq token 0 6) "BEHIND")))))
    (%worktree-status-tokens worktree))
   "CLEAN"))

(defun %worktree-tree-info-tokens (worktree)
  "Ordered (PLAIN . STYLED) token pairs for WORKTREE's tree-row info
   cluster, lowest priority first -- the order %WORKTREE-TREE-INFO-SUFFIX
   drops from when the row does not fit: relative time, then ahead/behind,
   then terminal count; agent lifecycle and Git state stay together so a
   narrow row cannot show CLEAN while silently dropping RUNNING."
  (let* ((time
         (%worktree-relative-time-text (%worktree-last-activity-time worktree)))
         (ahead-behind (%worktree-ahead-behind-parts worktree))
         (pane-count (%worktree-pane-count-text worktree))
         (agent (%worktree-agent-text worktree))
         (state (%worktree-state-tag worktree))
         (state-sgr (%worktree-state-token-sgr state)))
    (remove nil
            (list (and time (cons time (%sgr-wrap time +sgr-faint+)))
                  (and ahead-behind
                       (cons
                        (format nil "~{~A~^/~}" (mapcar #'car ahead-behind))
                        (format nil
                                "~{~A~^/~}"
                                (mapcar
                                 (lambda (part)
                                   (%sgr-wrap (car part) (cdr part)))
                                 ahead-behind))))
                  (cons pane-count (%sgr-wrap pane-count +sgr-faint+))
                  (cons (format nil "~A git:~A" agent state)
                        (format nil "~A git:~A"
                                (%sgr-wrap agent
                                           (if (eq (nerimux/pane:worktree-agent-state worktree)
                                                   :running)
                                               +sgr-alert+
                                               +sgr-faint+))
                                (if state-sgr
                                    (%sgr-wrap state state-sgr)
                                    state)))))))

(defun %worktree-tree-info-suffix (worktree width)
  "Two values -- PLAIN and STYLED text for WORKTREE's tree-row info cluster
   (agent lifecycle, Git state, ahead/behind, terminal count, activity time),
   space-joined. Tokens drop from the front (lowest priority: relative time,
   then ahead/behind, then terminal count; lifecycle and Git stay) until the
   plain form fits WIDTH display columns. %DISPLAY-CLIP's own
   truncate-with-ellipsis contract is the safety net for the case where even
   lifecycle and Git pair alone overflows WIDTH."
  (let ((tokens (%worktree-tree-info-tokens worktree)))
    (loop for remaining on tokens
          for plain = (format nil "~{~A~^ ~}" (mapcar #'car remaining))
          for styled = (format nil "~{~A~^ ~}" (mapcar #'cdr remaining))
          when (or (null (cdr remaining)) (<= (%display-width plain) width))
            return (values (%display-clip plain width) styled))))
