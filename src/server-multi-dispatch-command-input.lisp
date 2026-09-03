(in-package #:nerimux)

(defun %copy-mode-half-page-delta (pane)
  "Rows for C-u/C-d (contract SS2): half PANE's screen height, at least one
   line so a one-row pane still moves. copy-mode-scroll's sign convention
   (positive = older/up) makes C-u this value and C-d its negation."
  (let ((screen (and pane (pane-screen pane))))
    (max 1
         (floor
          (if screen
              (screen-height screen)
              24)
          2))))

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
      (setf (client-conn-command-buffer conn) (subseq buffer
                                                      0
                                                      (1- (length buffer))))
      (%mark-dirty)
      t)))

(defun %client-command-buffer-append (conn payload)
  (let ((text (%client-payload-text payload)))
    (when 
        (and text
             (every
              (lambda (character)
                (>= (char-code character) 32))
              text))
      (setf (client-conn-command-buffer conn) (concatenate 'string
                                                           (client-conn-command-buffer
                                                            conn)
                                                           text))
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
  (string-trim '(#\Space #\Tab) (format nil "~{~A~^ ~}" args)))

(defun %submit-client-search (session conn direction args)
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (screen (and pane (pane-screen pane)))
         (term (%client-search-term args)))
    (cond
      ((null screen) (%client-notify conn "no focused pane"))
      ((zerop (length term)) (%client-notify conn "search term is empty"))
      ((eq direction :forward) (copy-mode-search-forward screen term))
      ((eq direction :backward) (copy-mode-search-backward screen term)))
    (%client-restore-command-view conn)
    (%set-client-modal conn
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
                               (format nil "unknown command: ~(~A~)" cmd)))))
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
  "S-TAB: advance CONN's visibility level 1->2->3->4->1."
  (%client-set-visibility-level conn
                                (1+ (mod (client-conn-visibility-level conn) 4))))

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

(defun %scroll-client-process-log (conn delta)
  (let* ((entries (client-conn-process-log conn))
         (max-scroll (max 0 (1- (length entries)))))
    (setf (client-conn-process-log-scroll conn) (max 0
                                                     (min max-scroll
                                                          (+
                                                           (client-conn-process-log-scroll
                                                            conn)
                                                           delta))))
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
    ((%client-key-p payload #\q) (%set-client-modal conn nil))
    ((%client-key-p payload #\n) (%scroll-client-process-log conn 1))
    ((%client-key-p payload #\p) (%scroll-client-process-log conn -1)))
  nil)

(defun %client-selected-status-file (conn)
  "The (WORKTREE PATH) pair for CONN's selected status-view row, or NIL when
   there is no selection, the selection is not a :FILE row (its OBJECT is
   (:FILE WORKTREE-ID PATH CODE) -- see WORKSPACE-STATUS-ENTRIES /
   %WORKSPACE-STATUS-FILE-ENTRIES, renderer-workspace-status.lisp, and the
   existing :FILE handling in %CLIENT-TOGGLE-SELECTED-TREE-ROW above), or the
   row's own WORKTREE-ID no longer resolves in the live catalog. Resolving
   the worktree from the row's OWN embedded id, rather than from CLIENT-CONN-
   SELECTED-WORKTREE, keeps this correct even for a :FILE row reached via the
   repolist tree's inline expansion (Wave B/C), which need not agree with
   whichever worktree CLIENT-CONN-SELECTED-WORKTREE currently names."
  (let ((object (%client-tree-object conn)))
    (when (and (consp object) (eq (first object) :file))
      (destructuring-bind (worktree-id path code) (rest object)
        (declare (ignore code))
        (let ((worktree (%workspace-find-worktree worktree-id)))
          (and worktree (list worktree path)))))))

(defun %client-run-status-write (conn repository operation args)
  "Run one stage/unstage/discard write through the same async path and
   process log the transient menu's own writes use (%RUN-TRANSIENT-GIT-
   WRITE) -- not the synchronous GIT-WRITE-OPERATION, both for consistency
   with every other write this server issues and so a slow `git add` on a
   large index cannot stall the one event loop every attached client shares.
   REPOSITORY nil (no repository resolved for the selected worktree) is
   reported rather than attempted. HANDLER-CASE is the actual crash fix this
   whole section exists for -- see the header comment above."
  (if (null repository)
      (%client-notify conn "no repository selected")
      (handler-case (%run-transient-git-write conn repository operation args)
        (error (condition)
          (%client-notify conn
                          (format nil
                                  "git ~(~A~): failed: ~A"
                                  operation
                                  condition)))))
  t)

(defun %client-stage-selection (conn)
  "s (contract SS3): `git add -- PATH` for the selected :FILE row."
  (let ((selection (%client-selected-status-file conn)))
    (if selection
        (destructuring-bind (worktree path) selection
          (%client-run-status-write conn
                                    (nerimux/workspace-model:worktree-repository
                                     worktree)
                                    :add
                                    (list "--" path)))
        (progn
          (%client-notify conn "select a file first")
          t))))

(defun %client-stage-all (conn)
  "S (contract SS3): `git add -A` for the status view's own worktree
   (CLIENT-CONN-SELECTED-WORKTREE, the worktree %RENDER-STATUS-FRAME is
   currently drawing -- there is no per-file selection to key this one off
   of)."
  (let ((worktree (client-conn-selected-worktree conn)))
    (if worktree
        (%client-run-status-write conn
                                  (nerimux/workspace-model:worktree-repository
                                   worktree)
                                  :add
                                  (list "-A"))
        (progn
          (%client-notify conn "no worktree selected")
          t))))

(defun %client-unstage-selection (conn)
  "u (contract SS3): `git restore --staged -- PATH` for the selected :FILE
   row."
  (let ((selection (%client-selected-status-file conn)))
    (if selection
        (destructuring-bind (worktree path) selection
          (%client-run-status-write conn
                                    (nerimux/workspace-model:worktree-repository
                                     worktree)
                                    :restore
                                    (list "--staged" "--" path)))
        (progn
          (%client-notify conn "select a file first")
          t))))

(defun %client-unstage-all (conn)
  "U (contract SS3): `git restore --staged -- .` for the status view's own
   worktree, mirroring %CLIENT-STAGE-ALL's worktree resolution."
  (let ((worktree (client-conn-selected-worktree conn)))
    (if worktree
        (%client-run-status-write conn
                                  (nerimux/workspace-model:worktree-repository
                                   worktree)
                                  :restore
                                  (list "--staged" "--" "."))
        (progn
          (%client-notify conn "no worktree selected")
          t))))

(defun %client-start-discard-selection (conn)
  "k (contract SS3): `git restore -- PATH` for the selected :FILE row --
   destructive (it throws away uncommitted worktree changes with no undo),
   so unlike stage/unstage above it never runs immediately: it always
   confirms first via %OPEN-CONFIRM-VIEW, the same gate %RUN-TRANSIENT-GIT-
   ACTION's own CONFIRM-P branch uses for force-push/reset --hard/branch
   -D/clean (server-multi-dispatch-transient.lisp)."
  (let ((selection (%client-selected-status-file conn)))
    (if selection
        (destructuring-bind (worktree path) selection
          (let ((repository
                 (nerimux/workspace-model:worktree-repository worktree)))
            (%open-confirm-view conn
                                (format nil "git restore -- ~A" path)
                                (list
                                 (cons "worktree"
                                       (nerimux/workspace-model:worktree-path
                                        worktree))
                                 (cons "path" path))
                                (lambda ()
                                  (%client-run-status-write conn
                                                            repository
                                                            :restore
                                                            (list "--" path))))
            t))
        (progn
          (%client-notify conn "select a file first")
          t))))

(defun %client-open-selected-worktree-command (session conn command)
  "Open a new pane for the selected worktree running COMMAND.
   A NIL command deliberately starts the user's ordinary shell."
  (let ((worktree (client-conn-selected-worktree conn)))
    (unless worktree
      (%select-client-tree-worktree conn nil)
      (setf worktree (client-conn-selected-worktree conn)))
    (if (and worktree
             (%open-client-worktree-pane session
                                         conn
                                         worktree
                                         :default-command
                                         command))
        t
        (%client-notify conn "no worktree selected"))))
