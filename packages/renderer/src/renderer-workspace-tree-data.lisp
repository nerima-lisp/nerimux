(in-package #:nerimux/renderer)

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

(defun %repository-tree-label (repository)
  "Repository row label: the repository name from the final segment of
   SPECIFICATION, with a trailing `.git' removed. When SPECIFICATION is
   empty, use LOCAL-PATH or ID. The organization row supplies the host and
   organization context."
  (let ((specification (repository-specification repository)))
    (if (plusp (length specification))
        (let ((slash (position #\/ specification :from-end t)))
          (nerimux/text:strip-dot-git-suffix
           (if slash
               (subseq specification (1+ slash))
               specification)))
        (or
         (and (plusp (length (repository-local-path repository)))
              (repository-local-path repository))
         (repository-id repository)))))

(defun %worktree-short-head (worktree)
  "WORKTREE-HEAD's 7-character commit id, or NIL when HEAD holds something
   else -- a status refresh replaces the id read from `worktree list' with
   the branch name, or with \"(detached)\" when there is none."
  (let ((head (worktree-head worktree)))
    (when (and head
               (>= (length head) 7)
               (every (lambda (character) (digit-char-p character 16)) head))
      (subseq head 0 7))))

(defun %path-last-component (path)
  "The final component of PATH, or NIL when PATH names nothing."
  (let* ((trimmed (string-right-trim "/" (or path "")))
         (slash (position #\/ trimmed :from-end t)))
    (when (plusp (length trimmed))
      (if slash
          (subseq trimmed (1+ slash))
          trimmed))))

(defun %worktree-tree-label (worktree)
  "WORKTREE's tree-row label: BRANCH when set; otherwise, for a detached
   HEAD, the word `detached' with its short commit id when HEAD still
   carries one and the worktree's own directory name (unless that name is
   the word itself) -- never the absolute PATH, which overflows the row,
   pushes the status cluster off a 120-column screen and puts the user's
   home directory on it; then ID."
  (let ((branch (worktree-branch worktree))
        (path (worktree-path worktree)))
    (cond
      ((and branch (plusp (length branch))) branch)
      ((plusp (length path))
       (let ((name (%path-last-component path)))
         (format nil "detached~@[ @ ~A~]~@[ ~A~]"
                 (%worktree-short-head worktree)
                 (and name (not (string-equal name "detached")) name))))
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

(defun %pane-command-name (pane)
  "What PANE runs, as a word: the agent it hosts, else its title, else its
   start command, else \"shell\". An agent row names the sandbox it was
   launched without (+WORKSPACE-CLAUDE-COMMAND+ /
   +WORKSPACE-CODEX-COMMAND+, server-multi-data.lisp, are the only commands
   either agent kind is ever started with), because `claude' alone does not
   say that this pane skips the permission prompts."
  (case (pane-agent-kind pane)
    (:codex "codex (bypass sandbox)")
    (:claude "claude (skip permissions)")
    (t (or (and (plusp (length (pane-title pane))) (pane-title pane))
           (and (plusp (length (pane-start-command pane)))
                (pane-start-command pane))
           "shell"))))

(defun %pane-tree-label (pane)
  "PANE's tree-row label: what it runs, plus its pane id for a terminal (two
   shells under one worktree are otherwise the same row), its window number
   when the worktree spans more than one window, and `exited' once the
   process is gone -- a dead pane read exactly like a live one before."
  (let* ((worktree (pane-worktree pane))
         (window (pane-window pane))
         (multi-window-p
          (and worktree
               window
               (cdr (remove-duplicates
                     (remove nil (mapcar #'pane-window (worktree-panes worktree)))
                     :test #'eq)))))
    (format nil "~@[w~D ~]~A~@[ ~D~]~@[ ~A~]~@[ ~A~]"
            (and multi-window-p (window-id window))
            (%pane-command-name pane)
            (and (null (pane-agent-kind pane)) (pane-id pane))
            (and (pane-process-exited-p pane) "exited")
            (and (string= (pane-notification pane) "restored") "restored"))))

(defun %workspace-tree-node-attention-p (object kind)
  "T when OBJECT (a KIND tree node) should carry the `!` attention mark."
  (case kind
    (:organization (or (plusp (organization-attention-count object))
                        (organization-attention-worktrees object)))
    (:repository (repository-attention-p object))
    (:worktree (worktree-attention-p object))
    (:pane (pane-attention-p object))
    (:section nil)
    (t nil)))

(defun %changed-file-state-text (code)
  "The porcelain XY status CODE as the word a user reads. \".M\" and \"??\"
   are git's own internals and were showing through on every expanded file
   row."
  (let* ((index (and (plusp (length code)) (char code 0)))
         (worktree (and (> (length code) 1) (char code 1)))
         (significant (if (and index (not (find index ". "))) index worktree)))
    (cond
      ((string= code "??") "untracked")
      ((string= code "!!") "ignored")
      ((or (eql index #\U) (eql worktree #\U)) "conflict")
      ((eql significant #\M) "modified")
      ((eql significant #\A) "added")
      ((eql significant #\D) "deleted")
      ((eql significant #\R) "renamed")
      ((eql significant #\C) "copied")
      ((eql significant #\T) "typechange")
      (t "changed"))))

(defun %workspace-tree-node-unreadable-p (object kind)
  "T when a KIND row's checkout could not be read."
  (case kind
    (:organization (organization-missing-p object))
    (:repository (repository-missing-p object))
    (:worktree (worktree-missing-p object))
    (t nil)))

(defun %workspace-tree-node-mark (object kind)
  "The one-character row flag: `✗' for a checkout that could not be read,
   `!' for a row needing attention, else a space. The two were one glyph
   before, so a healthy but dirty repository read as a broken one."
  (cond
    ((%workspace-tree-node-unreadable-p object kind) "✗")
    ((%workspace-tree-node-attention-p object kind) "!")
    (t " ")))

(defun %workspace-tree-row-children-p (object kind)
  "T when a KIND row has rows of its own to fold away. Section and
   repository rows know their own children from the rows they just built, so
   they pass their fold state in directly."
  (case kind
    (:worktree
     (and (or (worktree-panes object)
              (worktree-changed-files object)
              (worktree-commits-state object))
          t))
    (:file t)
    (t nil)))

(defun %workspace-tree-fold-glyph (fold)
  "The disclosure glyph for a row's FOLD state (:EXPANDED, :COLLAPSED or NIL
   for a leaf), so a folded row is distinguishable from an empty one."
  (case fold
    (:expanded "▾")
    (:collapsed "▸")
    (t " ")))

(defun %workspace-tree-row-fold (object kind expanded-p)
  "A row's fold state for %WORKSPACE-TREE-FOLD-GLYPH: NIL for a leaf,
   otherwise :EXPANDED or :COLLAPSED from EXPANDED-P."
  (when (%workspace-tree-row-children-p object kind)
    (if expanded-p :expanded :collapsed)))

(defun %workspace-node-refresh-tag (kind id refreshing-ids stale-ids)
  "Return the refresh-state suffix for an organization, repository, or worktree."
  (let ((key (list kind id)))
    (cond
      ((and refreshing-ids (gethash key refreshing-ids)) " refreshing")
      ((and stale-ids (gethash key stale-ids)) " stale")
      (t ""))))

(defun %worktree-relative-time-text (universal-time)
  "Return an ASCII relative-time label for UNIVERSAL-TIME.
   Use \"now\" under a minute, then Nm/Nh/Nd; arrow glyphs are disallowed
   because the UI reserves ambiguous-width characters."
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
   ahead first -- \"↑N\"/\"↓N\", so a commit count cannot be read as the
   changed-line count beside it. Both arrows are East-Asian Ambiguous, which
   CHAR-WIDTH and the terminal agree is one column."
  (append
   (when (plusp (worktree-ahead worktree))
     (list (cons (format nil "↑~D" (worktree-ahead worktree)) +sgr-ahead+)))
   (when (plusp (worktree-behind worktree))
     (list (cons (format nil "↓~D" (worktree-behind worktree)) +sgr-behind+)))))

(defun %worktree-change-count-parts (worktree)
  "WORKTREE's added/deleted line counts as one plain and styled token, each
   half omitted when it is zero -- \"-0\" said nothing and read as a behind
   count."
  (let* ((additions (nerimux/workspace-model:worktree-additions worktree))
         (deletions (nerimux/workspace-model:worktree-deletions worktree))
         (parts
          (append
           (when (plusp additions)
             (list (cons (format nil "+~D" additions) +sgr-ok+)))
           (when (plusp deletions)
             (list (cons (format nil "−~D" deletions) +sgr-alert+))))))
    (when parts
      (cons (format nil "~{~A~^ ~}" (mapcar #'car parts))
            (format nil "~{~A~^ ~}"
                    (mapcar (lambda (part) (%sgr-wrap (car part) (cdr part)))
                            parts))))))

(defun %worktree-shell-count-text (worktree)
  "\"1 shell\"/\"N shells\" for WORKTREE's non-agent panes, NIL when it holds
   none -- an absent terminal is not news."
  (let ((count
         (count-if-not #'nerimux/pane:pane-agent-kind (worktree-panes worktree))))
    (when (plusp count)
      (format nil "~D shell~P" count count))))

(defun %worktree-exited-pane-text (worktree)
  "\"exited\" when one of WORKTREE's panes has lost its process."
  (when (some #'pane-process-exited-p (worktree-panes worktree))
    "exited"))

(defun %worktree-agent-text (worktree)
  "\"agent RUNNING/WAITING/EXITED\" for WORKTREE's agent lifecycle, or NIL
   when no agent has ever run here."
  (let ((state (nerimux/pane:worktree-agent-state worktree)))
    (cond
      ((nerimux/workspace-model:worktree-waiting-p worktree) "agent WAITING")
      ((eq state :none) nil)
      (t (format nil "agent ~A" state)))))

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
           (and (>= (length token) 6) (string= (subseq token 0 6) "BEHIND"))
           (and (plusp (length token)) (char= (char token 0) #\+)))))
    (%worktree-status-tokens worktree))
   "CLEAN"))

(defun %worktree-git-state-text (worktree)
  "WORKTREE's Git state as a lowercase word, or NIL when it is clean -- the
   resting state needs no token of its own."
  (let ((tag (%worktree-state-tag worktree)))
    (unless (string= tag "CLEAN")
      (string-downcase tag))))

(defun %worktree-tree-info-tokens (worktree)
  "Ordered (PLAIN STYLED PRIORITY) token triples for WORKTREE's tree-row
   info cluster, in display order. PRIORITY is the narrow-row omission
   order %WORKTREE-TREE-INFO-SUFFIX drops from, lowest first: changed lines,
   relative time, ahead/behind, shell count, then the pane and agent
   lifecycle words; the agent state and the Git state go last so a narrow row
   cannot drop RUNNING while keeping a count."
  (flet ((faint (text priority)
           (list text (%sgr-wrap text +sgr-faint+) priority)))
    (let* ((time
            (%worktree-relative-time-text (%worktree-last-activity-time worktree)))
           (change-counts (%worktree-change-count-parts worktree))
           (ahead-behind (%worktree-ahead-behind-parts worktree))
           (shells (%worktree-shell-count-text worktree))
           (exited (%worktree-exited-pane-text worktree))
           (completed (and (worktree-completed-p worktree) "completed"))
           (agent (%worktree-agent-text worktree))
           (state (%worktree-git-state-text worktree))
           (state-sgr (and state (%worktree-state-token-sgr (string-upcase state)))))
      (remove nil
              (list (and time (faint time 1))
                    (and change-counts
                         (list (car change-counts) (cdr change-counts) 0))
                    (and ahead-behind
                         (list
                          (format nil "~{~A~^ ~}" (mapcar #'car ahead-behind))
                          (format nil "~{~A~^ ~}"
                                  (mapcar (lambda (part)
                                            (%sgr-wrap (car part) (cdr part)))
                                          ahead-behind))
                          2))
                    (and shells (faint shells 3))
                    (and exited
                         (list exited (%sgr-wrap exited +sgr-alert+) 4))
                    (and completed (faint completed 4))
                    (and agent
                         (list agent
                               (%sgr-wrap agent
                                          (if (eq (nerimux/pane:worktree-agent-state
                                                   worktree)
                                                  :running)
                                              +sgr-alert+
                                              +sgr-faint+))
                               5))
                    (and state
                         (list state
                               (if state-sgr (%sgr-wrap state state-sgr) state)
                               5)))))))

(defun %worktree-tree-info-drop-priority (token)
  "Return TOKEN's narrow-row omission priority, lower values first."
  (third token))

(defun %worktree-tree-info-suffix (worktree width)
  "Two values -- PLAIN and STYLED text for WORKTREE's tree-row info cluster
   (shell count, pane and agent lifecycle, Git state, ahead/behind, changed
   lines, activity time), space-joined. Tokens remain in display order, while
   narrow-row omission follows %WORKTREE-TREE-INFO-TOKENS's own priorities
   until the plain form fits WIDTH display columns. %DISPLAY-CLIP's own
   truncate-with-ellipsis contract is the safety net for the case where even
   the last token alone overflows WIDTH."
  (loop with remaining = (%worktree-tree-info-tokens worktree)
        for plain = (format nil "~{~A~^ ~}" (mapcar #'first remaining))
        for styled = (format nil "~{~A~^ ~}" (mapcar #'second remaining))
        when (or (null (cdr remaining)) (<= (%display-width plain) width))
          return (values (%display-clip plain width) styled)
        do (let ((drop (reduce
                        (lambda (left right)
                          (if (< (%worktree-tree-info-drop-priority left)
                                 (%worktree-tree-info-drop-priority right))
                              left
                              right))
                        remaining)))
             (setf remaining (delete drop remaining :count 1 :test #'eq)))))

(defun %repository-tree-info-tokens (repository)
  "Ordered (PLAIN STYLED PRIORITY) token triples for REPOSITORY's tree-row
   info cluster: its total worktree count, how many of those hold at least
   one pane (active), and how many need attention
   (NERIMUX/WORKSPACE-MODEL:WORKTREE-ATTENTION-P) -- the counts a collapsed
   repository row would otherwise hide entirely. PRIORITY follows
   %WORKTREE-TREE-INFO-DROP-PRIORITY's own convention: lower drops first, so
   a narrow row loses the worktree count before the active count, and loses
   the attention count last."
  (let* ((worktrees (repository-worktrees repository))
         (total (length worktrees))
         (active (count-if #'worktree-panes worktrees))
         (attention
           (count-if #'nerimux/workspace-model:worktree-attention-p worktrees)))
    (remove nil
            (list (and (plusp total)
                       (let ((text (format nil "~D worktree~:P" total)))
                         (list text (%sgr-wrap text +sgr-faint+) 1)))
                  (and (plusp active)
                       (let ((text (format nil "~D active" active)))
                         (list text (%sgr-wrap text +sgr-faint+) 2)))
                  (and (plusp attention)
                       (let ((text (format nil "~D !" attention)))
                         (list text (%sgr-wrap text +sgr-alert+) 3)))))))

(defun %repository-tree-info-suffix (repository width)
  "Two values -- PLAIN and STYLED text for REPOSITORY's tree-row info
   cluster, built from %REPOSITORY-TREE-INFO-TOKENS with the same contract
   as %WORKTREE-TREE-INFO-SUFFIX: space-joined tokens, dropped by priority
   (lowest first) until the plain form fits WIDTH, with %DISPLAY-CLIP as the
   safety net for a single token that alone overflows WIDTH."
  (loop with remaining = (%repository-tree-info-tokens repository)
        for plain = (format nil "~{~A~^ ~}" (mapcar #'first remaining))
        for styled = (format nil "~{~A~^ ~}" (mapcar #'second remaining))
        when (or (null (cdr remaining)) (<= (%display-width plain) width))
          return (values (%display-clip plain width) styled)
        do (let ((drop (reduce
                        (lambda (left right)
                          (if (< (%worktree-tree-info-drop-priority left)
                                 (%worktree-tree-info-drop-priority right))
                              left
                              right))
                        remaining)))
             (setf remaining (delete drop remaining :count 1 :test #'eq)))))
