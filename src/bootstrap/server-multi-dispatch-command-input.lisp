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
         (window (and pane (nerimux/model:pane-window pane))))
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

(defun %client-start-worktree-delete (conn)
  (if (%client-operation-worktree conn)
      (%client-enter-command-mode conn "wt-delete --confirm")
      (%client-notify conn "select a worktree to delete"))
  t)

(defun %client-start-worktree-lock (conn)
  (if (%client-operation-worktree conn)
      (%client-enter-command-mode conn "wt-lock --confirm")
      (%client-notify conn "select a worktree to lock"))
  t)

(defun %client-start-worktree-unlock (conn)
  (if (%client-operation-worktree conn)
      (%client-enter-command-mode conn "wt-unlock --confirm")
      (%client-notify conn "select a worktree to unlock"))
  t)

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
      ((typep object 'nerimux/model:organization)
       (%toggle-workspace-node-collapsed
        :organization (nerimux/model:organization-id object))
       (%mark-dirty)
       t)
      ((keywordp object)
       ;; A :SECTION row (its OBJECT is the section keyword itself --
       ;; :ATTENTION/:ACTIVE/:REPOSITORIES): Enter toggles it exactly like
       ;; Tab (%CLIENT-TOGGLE-SELECTED-TREE-ROW).
       (%client-toggle-selected-tree-row conn))
      ((typep object 'nerimux/model:repository)
       ;; Enter no longer toggles a repository row open/closed (user
       ;; decision, R6.3 pivot): it dives straight into the repository's
       ;; main worktree (or its first one, when there is no main) via the
       ;; SAME open/attach corridor as the (t) worktree branch below --
       ;; recursing after selecting the worktree reuses that branch instead
       ;; of duplicating its remembered-pane/open-pane logic here.
       (let ((worktree (or (nerimux/model:repository-main-worktree object)
                            (first (nerimux/model:repository-worktrees
                                    object)))))
         (if worktree
             (progn
               (%set-client-selected-tree-object conn worktree)
               (%focus-selected-client-worktree session conn))
             (progn
               (%client-notify conn "repository has no worktrees")
               t))))
      ((typep object 'nerimux/model:pane)
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
      ((typep object 'nerimux/model:window)
       (let ((pane (nerimux/model:window-active-pane object)))
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
           ((and pane (nerimux/model:pane-live-p pane))
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
       (nerimux/model:worktree-repository worktree) worktree
       :callback-dispatch #'%enqueue-main-thread-callback
       :on-complete (lambda (result) (declare (ignore result)) (%mark-dirty))
       :on-error (lambda (condition) (declare (ignore condition)) (%mark-dirty)))
    ;; Kicking the async refresh off itself failed synchronously (e.g.
    ;; thread creation) -- same shape as %ADD-CLIENT's catalog-refresh
    ;; launch: no callback is ever coming, so COMMITS-STATE must settle to
    ;; :FAILED here rather than being stuck at :PENDING forever.
    (error ()
      (setf (nerimux/model:worktree-commits-state worktree) :failed)
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
  (let ((key (list (nerimux/model:worktree-id worktree) path)))
    (flet ((%on-error (condition)
             (declare (ignore condition))
             (%set-workspace-file-diff key (list :failed 0 nil))
             (%mark-dirty)))
      (handler-case
          (nerimux/vcs:refresh-worktree-file-diff-async
           (nerimux/model:worktree-repository worktree) worktree path
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
      ((typep object 'nerimux/model:repository)
       (let ((key (list :repository (nerimux/model:repository-id object)))
             (table (%workspace-expanded-nodes)))
         (if (gethash key table) (remhash key table) (setf (gethash key table) t)))
       (%mark-dirty)
       t)
      ((typep object 'nerimux/model:worktree)
       (let ((key (list :worktree (nerimux/model:worktree-id object)))
             (table (%workspace-expanded-nodes)))
         (if (gethash key table)
             (remhash key table)
             (progn
               (setf (gethash key table) t)
               (when (member (nerimux/model:worktree-commits-state object)
                             '(nil :failed))
                 (setf (nerimux/model:worktree-commits-state object) :pending)
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
      ((typep object 'nerimux/model:organization)
       (setf (gethash (list :organization
                            (nerimux/model:organization-id object))
                      (%workspace-collapsed-nodes))
             t)
       (%mark-dirty)
       t)
      ((keywordp object)
       (setf (gethash (list :section object) (%workspace-collapsed-nodes)) t)
       (%mark-dirty)
       t)
      ((typep object 'nerimux/model:repository)
       (remhash (list :repository (nerimux/model:repository-id object))
                (%workspace-expanded-nodes))
       (%mark-dirty)
       t)
      (t nil))))

(defun %client-tree-expand-selected (conn)
  "L (item 3): expand the selected row -- the inverse of H above."
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/model:organization)
       (remhash (list :organization (nerimux/model:organization-id object))
                (%workspace-collapsed-nodes))
       (%mark-dirty)
       t)
      ((keywordp object)
       (remhash (list :section object) (%workspace-collapsed-nodes))
       (%mark-dirty)
       t)
      ((typep object 'nerimux/model:repository)
       (setf (gethash (list :repository (nerimux/model:repository-id object))
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

(defun %copy-mode-half-page-delta (pane)
  "Rows for C-u/C-d (contract SS2): half PANE's screen height, at least one
   line so a one-row pane still moves. copy-mode-scroll's sign convention
   (positive = older/up) makes C-u this value and C-d its negation."
  (let ((screen (and pane (pane-screen pane))))
    (max 1 (floor (if screen (screen-height screen) 24) 2))))

(define-key-rules %copy-key-dispatch (session conn payload)
  (:let ((pane (%resolve-client-focus-pane session nil conn))
         (screen (and pane (pane-screen pane)))))
  ((null screen)
   (%client-notify conn "no focused pane")
   (%set-client-modal conn nil))
  (#\k (copy-mode-move-cursor screen :up))
  (#\j (copy-mode-move-cursor screen :down))
  (21 (copy-mode-scroll screen (%copy-mode-half-page-delta pane)))
  (4 (copy-mode-scroll screen (- (%copy-mode-half-page-delta pane))))
  (#\g (copy-mode-scroll screen most-positive-fixnum))
  (#\G (copy-mode-scroll screen (- most-positive-fixnum)))
  (#\Space (copy-mode-begin-selection screen))
  (#\y (copy-mode-yank screen) (%set-client-modal conn nil))
  (#\n (copy-mode-search-next screen))
  (#\N (copy-mode-search-prev screen))
  (#\/ (%client-enter-command-mode conn "search-forward "))
  (#\? (%client-enter-command-mode conn "search-backward "))
  (#\q
   ;; Mirrors what %client-exit-copy-mode used to do to SCREEN before this
   ;; unit was told (contract SS0) to stop calling it: q must still unfreeze
   ;; the viewport, or live PTY output keeps appending underneath a frame
   ;; anchored at the old scroll offset while the keyboard has already moved
   ;; on to the view underneath.
   (when (screen-copy-mode-p screen) (copy-mode-exit screen))
   (%set-client-modal conn nil)))

(defun %handle-client-copy-key-payload (session conn payload)
  "Scrollback (contract SS2/FR-008) exit is bound to q, which clears MODAL
   directly -- there is no %client-exit-copy-mode transition to call anymore,
   just a modal to drop, so a caller cannot land back in an unreachable
   (view, modal) pair. ESC is a plain, unbound byte here (it never doubled as
   an exit key -- see R4.2), and h/l horizontal cursor movement is dropped:
   SS2's scrollback table has no horizontal keys, and grep across src/ for
   COPY-MODE-MOVE-CURSOR turns up only the :up/:down call sites left above --
   no :left/:right caller survives removing these two clauses."
  (%copy-key-dispatch session conn payload)
  (%mark-dirty)
  t)

(defun %client-command-buffer-delete-character (conn)
  (let ((buffer (client-conn-command-buffer conn)))
    (when (plusp (length buffer))
      (setf (client-conn-command-buffer conn)
            (subseq buffer 0 (1- (length buffer))))
      (%mark-dirty)
      t)))

(defun %client-command-buffer-append (conn payload)
  (let ((text (%client-payload-text payload)))
    (when (and text
               (every (lambda (character)
                        (>= (char-code character) 32))
                      text))
      (setf (client-conn-command-buffer conn)
            (concatenate 'string (client-conn-command-buffer conn) text))
      (%mark-dirty)
      t)))

(defun %client-command-target-and-args (args)
  (if (and (stringp (first args))
           (member (first args) '("-t" "--target") :test #'string=))
      (values (second args) (cddr args))
      (values nil args)))

(defun %client-search-direction (name)
  (cond
    ((member name '("search-forward" "/") :test #'string-equal) :forward)
    ((member name '("search-backward" "?") :test #'string-equal) :backward)))

(defun %client-search-term (args)
  (string-trim '(#\Space #\Tab)
               (format nil "~{~A~^ ~}" args)))

(defun %submit-client-search (session conn direction args)
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (screen (and pane (pane-screen pane)))
         (term (%client-search-term args)))
    (cond
      ((null screen)
       (%client-notify conn "no focused pane"))
      ((zerop (length term))
       (%client-notify conn "search term is empty"))
      ((eq direction :forward)
       (copy-mode-search-forward screen term))
      ((eq direction :backward)
       (copy-mode-search-backward screen term)))
    (%client-restore-command-view conn)
    (%set-client-modal
     conn
     (if (and screen (screen-copy-mode-p screen))
         :scrollback
         nil))
    (%mark-dirty)))

(defun %submit-client-command (session conn)
  (let ((input (string-trim '(#\Space #\Tab)
                            (client-conn-command-buffer conn))))
    (setf (client-conn-command-buffer conn) "")
    (if (zerop (length input))
        (progn
          (%client-restore-command-view conn)
          (%set-client-modal conn nil)
          (%mark-dirty))
        (handler-case
            (let* ((tokens (tokenize-command-string input))
                   (name (first tokens))
                   ;; FIND-SYMBOL, never INTERN: NAME comes from
                   ;; CLIENT-CONN-COMMAND-BUFFER, which is filled one keystroke
                   ;; at a time by %CLIENT-COMMAND-BUFFER-APPEND with no length
                   ;; cap, straight from the wire.  INTERN here let any peer
                   ;; grow the KEYWORD package without bound -- CL never
                   ;; releases interned symbols -- simply by typing a fresh
                   ;; garbage name and pressing Enter, repeatedly, for the life
                   ;; of the server.
                   ;;
                   ;; Falling back to the raw string rather than NIL keeps the
                   ;; "unknown command" report: DEFINE-COMMAND-RULES compares
                   ;; with EQ/MEMBER against keyword literals, so a string
                   ;; matches nothing and falls through exactly as an
                   ;; unrecognised keyword did, while NIL would instead read as
                   ;; "no command at all" and report nothing.  Same shape as
                   ;; DECODE-COMMAND-PAYLOAD (infrastructure/net/protocol-command.lisp)
                   ;; and %CLIENT-UI-MODE-VALUE.
                   (cmd (and name
                             (or (find-symbol (string-upcase name) :keyword)
                                 name)))
                   (search-direction (%client-search-direction name)))
              (if search-direction
                  (multiple-value-bind (target args)
                      (%client-command-target-and-args (rest tokens))
                    (declare (ignore target))
                    (%submit-client-search session conn search-direction args))
                  (progn
                    (let ((handled-p nil))
                      (if cmd
                          (multiple-value-bind (target args)
                              (%client-command-target-and-args (rest tokens))
                            (setf handled-p
                                  (%handle-client-ui-command
                                   session conn cmd target args))
                            (unless handled-p
                              (%client-notify
                               conn
                               (format nil "unknown command: ~(~A~)" cmd))))
                          (%client-notify conn "empty command"))
                      (unless handled-p
                        (%client-restore-command-view conn)))
                    (%set-client-modal conn nil)
                    (%mark-dirty))))
          (error (condition)
            (%client-notify
             conn
             (format nil "command failed: ~A" condition))
            (%client-restore-command-view conn)
            (%set-client-modal conn nil)
            (%mark-dirty)))))
  t)

(define-key-rules %handle-client-command-key-payload (session conn payload)
  (27
   ;; R4.3: see the matching comment in %handle-client-picker-key-payload.
   (%client-esc-swallow-start conn)
   (setf (client-conn-command-buffer conn) "")
   (%client-restore-command-view conn)
   (%set-client-modal conn nil)
   (%mark-dirty)
   t)
  ((or (%client-byte-p payload 13) (%client-byte-p payload 10))
   (%submit-client-command session conn))
  ((or (%client-byte-p payload 8) (%client-byte-p payload 127))
   (%client-command-buffer-delete-character conn)
   t)
  (t
   (%client-command-buffer-append conn payload)
   t))

;;; ── ESC-prefixed multi-byte keys (M-n, M-p, S-TAB) ──────────────────────────
;;;
;;; The client forwards stdin one byte at a time (see *CLIENT-ESC-SWALLOW-
;;; COUNTS* above), so Alt/Meta and shifted-function keys still arrive as a
;;; multi-byte escape sequence split across separate key messages: M-n/M-p is
;;; ESC then the letter (2 bytes), S-TAB is ESC [ Z (3 bytes), and a real
;;; arrow key is ESC [ A/B/C/D (3 bytes, same CSI introducer as S-TAB).
;;;
;;; *CLIENT-ESC-SWALLOW-COUNTS* is the wrong tool here: it discards a fixed,
;;; already-known number of trailing bytes after something else has already
;;; acted on the ESC. Here nothing may act until the byte AFTER the ESC is
;;; known, so this needs the opposite shape -- remember that an ESC is
;;; in-flight and route only the byte(s) that follow it, keyed by CONN so one
;;; client's pending sequence can never resolve against another's byte.

(defvar *client-meta-pending* (make-hash-table :test #'eq :weakness :key)
  "CONN -> :SECOND (just saw ESC, waiting for the byte that disambiguates
   M-n/M-p from a CSI introducer) or :CSI-THIRD (that byte was `[`, waiting
   for the third byte that disambiguates S-TAB's `Z` from an arrow key's
   A/B/C/D). Absent means no ESC is in flight for CONN. :weakness :key for
   the same reason as *CLIENT-ESC-SWALLOW-COUNTS*: a dropped connection's
   entry must not linger.")

(defun %client-meta-pending-consume (conn payload)
  "Resolve the byte following a pending ESC. `n`/`p` while :SECOND completes
   M-n/M-p (contract SS2's section jump); `[` while :SECOND is a CSI
   introducer and advances to :CSI-THIRD instead of acting; `Z` while
   :CSI-THIRD completes S-TAB (cycle visibility). Anything else -- most
   importantly an arrow key's A/B/C/D at :CSI-THIRD -- is an unrecognised
   sequence and is swallowed right here rather than replayed into
   %HANDLE-CLIENT-UI-KEY-PAYLOAD's own per-key table, which is exactly the
   'a sequence's trailing bytes must never land on the wrong handler' rule
   the ESC clause in %HANDLE-HELP-VIEW-KEY documents for the same hazard.
   This is also the reason an arrow key cannot mis-fire a bound letter: its
   third byte only ever reaches this COND, never the table below, and A/B/C/D
   match nothing in it."
  (let ((state (gethash conn *client-meta-pending*)))
    (remhash conn *client-meta-pending*)
    (case state
      (:second
       (cond
         ((%client-key-p payload #\n) (%select-client-tree-section-relative conn 1))
         ((%client-key-p payload #\p) (%select-client-tree-section-relative conn -1))
         ((%client-byte-p payload 91) ; `[`, the CSI introducer
          (setf (gethash conn *client-meta-pending*) :csi-third))))
      (:csi-third
       (when (%client-byte-p payload 90) ; `Z`
         (%client-cycle-visibility conn)))))
  t)

;;; ── FR-005 visibility levels ─────────────────────────────────────────────

(defun %client-set-visibility-level (conn level)
  "`1`-`4` (contract SS2): set CONN's global section-visibility preset.
   Out-of-range LEVEL is a no-op rather than storing an unrenderable value --
   defensive only, since every caller here already passes a literal 1-4 or a
   value %CLIENT-CYCLE-VISIBILITY has already reduced into that range."
  (when (<= 1 level 4)
    (setf (client-conn-visibility-level conn) level)
    (%mark-dirty))
  t)

(defun %client-cycle-visibility (conn)
  "S-TAB: advance CONN's visibility level 1->2->3->4->1. A never-yet-set
   level (NIL) is treated as 0 so the first press lands on 1 rather than
   erroring out of MOD."
  (%client-set-visibility-level
   conn
   (1+ (mod (or (client-conn-visibility-level conn) 0) 4))))

;;; ── FR-006 `q` step-back ladder ──────────────────────────────────────────

(defun %client-focused-live-pane (session conn)
  "CONN's own remembered focus, still live in SESSION -- deliberately NOT
   %RESOLVE-CLIENT-FOCUS-PANE's window-active-pane fallback, which always
   finds SOME pane once a window exists and would make %CLIENT-STEP-BACK's
   'if there is one' vacuously true, sending `q` into a pane the user never
   actually left."
  (and (client-conn-focus conn)
       (find (client-conn-focus conn) (all-panes session) :test #'eq)))

(defun %client-step-back (session conn)
  "FR-006: `q` retreats exactly one level, first match wins, so a transient
   sitting over a filtered status view backs out only the transient -- the
   filter and the pane behind it are left exactly where the user put them.
   The transient rung only fires when something else on this connection
   calls this directly with MODAL already :TRANSIENT (contract SS3's
   %HANDLE-CLIENT-TRANSIENT-KEY-PAYLOAD may delegate its own `q` here for
   this reason): %HANDLE-MULTI-KEY-MESSAGE routes a :TRANSIENT modal to that
   handler before this function is ever reached, so `q` on the UI keymap
   itself always has MODAL NIL by the time it gets here."
  (cond
    ((eq (client-conn-modal conn) :transient)
     (setf (client-conn-transient-view conn) nil)
     (%set-client-modal conn nil))
    ((client-conn-tree-filter conn)
     (setf (client-conn-tree-filter conn) nil)
     (%mark-dirty))
    ((eq (client-conn-view conn) :status)
     (if (%client-focused-live-pane session conn)
         (%set-client-view conn :pane)
         (%set-client-view conn :repolist)))
    ((eq (client-conn-view conn) :repolist)
     (when (%client-focused-live-pane session conn)
       (%set-client-view conn :pane))))
  t)

;;; ── FR-011 `$` process log ───────────────────────────────────────────────

(defun %scroll-client-process-log (conn delta)
  (let* ((entries (client-conn-process-log conn))
         (max-scroll (max 0 (1- (length entries)))))
    (setf (client-conn-process-log-scroll conn)
          (max 0 (min max-scroll (+ (client-conn-process-log-scroll conn) delta))))
    (%mark-dirty)))

(defun %handle-process-log-key (conn payload)
  "Answer the `$` process log CONN is looking at: q/ESC close it (dropping
   MODAL, the same shape %CLOSE-HELP-VIEW uses -- there is no separate
   'process log mode' to leave, only a modal to drop); n/p scroll;
   everything else is swallowed, mirroring %HANDLE-HELP-VIEW-KEY. ESC goes
   through %CLIENT-ESC-SWALLOW-START first (R4.3) for the identical reason
   documented there: a lone ESC byte here could be the first of a 3-byte
   arrow-key sequence, and closing the view immediately would hand its
   trailing 2 bytes to whatever key handler runs next as literal `[` and a
   letter."
  (cond
    ((%client-byte-p payload 27)
     (%client-esc-swallow-start conn)
     (%set-client-modal conn nil))
    ((%client-key-p payload #\q)
     (%set-client-modal conn nil))
    ((%client-key-p payload #\n)
     (%scroll-client-process-log conn 1))
    ((%client-key-p payload #\p)
     (%scroll-client-process-log conn -1)))
  nil)

;;; ── The repolist/status UI keymap (contract SS2, FR-004) ─────────────────
;;;
;;; Reached only when MODAL is NIL and VIEW is :repolist or :status
;;; (%CLIENT-UI-KEYS-P) -- every other modal has its own dispatcher in
;;; %HANDLE-MULTI-KEY-MESSAGE's ECASE, and VIEW :pane goes straight to the
;;; shell. A key this table does not bind is simply dropped by the caller;
;;; it must never fall through to %HANDLE-CLIENT-INPUT-KEY-PAYLOAD, which
;;; would hand a retired UI key like the old `j`/`c`/`i` to whatever program
;;; the focused pane happens to be running.

(define-key-rules %handle-client-ui-key-payload (session conn payload)
  (:let ((view (client-conn-view conn))))
  ;; A pending ESC sequence takes priority over every ordinary key below --
  ;; the byte that resolves it must never also be looked up in this table.
  ((gethash conn *client-meta-pending*)
   (%client-meta-pending-consume conn payload))
  (27
   (setf (gethash conn *client-meta-pending*) :second)
   t)
  (#\n (%select-client-tree-relative conn 1) t)
  (#\p (%select-client-tree-relative conn -1) t)
  (9 (%client-toggle-selected-tree-row conn))
  (#\1 (%client-set-visibility-level conn 1))
  (#\2 (%client-set-visibility-level conn 2))
  (#\3 (%client-set-visibility-level conn 3))
  (#\4 (%client-set-visibility-level conn 4))
  ((or (%client-byte-p payload 13) (%client-byte-p payload 10))
   (%focus-selected-client-worktree session conn))
  (#\g (%client-refresh-workspace conn))
  (#\q (%client-step-back session conn))
  (#\$ (%set-client-modal conn :process-log) t)
  (#\/ (%client-enter-tree-filter-mode conn))
  (#\: (%client-enter-command-mode conn))
  (#\? (%open-client-transient conn #\?))
  ;; ── status-only (contract SS2) ──────────────────────────────────────────
  ((and (eq view :status) (%client-key-p payload #\s)) (%client-stage-selection conn))
  ((and (eq view :status) (%client-key-p payload #\S)) (%client-stage-all conn))
  ((and (eq view :status) (%client-key-p payload #\u)) (%client-unstage-selection conn))
  ((and (eq view :status) (%client-key-p payload #\U)) (%client-unstage-all conn))
  ((and (eq view :status) (%client-key-p payload #\k)) (%client-start-discard-selection conn))
  ((and (eq view :status) (%client-key-p payload #\c)) (%open-client-transient conn #\c))
  ((and (eq view :status) (%client-key-p payload #\P)) (%open-client-transient conn #\P))
  ((and (eq view :status) (%client-key-p payload #\F)) (%open-client-transient conn #\F))
  ((and (eq view :status) (%client-key-p payload #\b)) (%open-client-transient conn #\b))
  ((and (eq view :status) (%client-key-p payload #\m)) (%open-client-transient conn #\m))
  ((and (eq view :status) (%client-key-p payload #\r)) (%open-client-transient conn #\r))
  ((and (eq view :status) (%client-key-p payload #\z)) (%open-client-transient conn #\z))
  ((and (eq view :status) (%client-key-p payload #\l)) (%open-client-transient conn #\l))
  ((and (eq view :status) (%client-key-p payload #\d)) (%open-client-transient conn #\d))
  ((and (eq view :status) (%client-key-p payload #\f)) (%open-client-transient conn #\f))
  ((and (eq view :status) (%client-key-p payload #\t)) (%open-client-transient conn #\t))
  ((and (eq view :status) (%client-key-p payload #\X)) (%open-client-transient conn #\X))
  ((and (eq view :status) (%client-key-p payload #\!)) (%open-client-transient conn #\!))
  ((and (eq view :status) (%client-key-p payload #\w)) (%open-client-transient conn #\w))
  (t nil))
