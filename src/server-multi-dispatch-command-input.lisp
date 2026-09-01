(in-package #:nerimux)

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

;;; ── FR-003 stage/unstage/discard (magit-style status actions) ────────────
;;;
;;; s/S/u/U/k below are reached straight from %HANDLE-CLIENT-UI-KEY-PAYLOAD's
;;; NIL-modal keymap (see the status-only clauses further down), which has no
;;; error boundary of its own above it: %HANDLE-MULTI-KEY-MESSAGE's only
;;; handler-case is PEER-IO-FAILURE, not ERROR (server-multi-dispatch.lisp),
;;; so an unhandled condition from any of these five would propagate out of
;;; the single select(2) loop shared by every client and kill the server.
;;; Every path through these five functions must therefore end in either a
;;; %CLIENT-NOTIFY or a %RUN-TRANSIENT-GIT-WRITE dispatch, never a bare
;;; ERROR -- %CLIENT-RUN-STATUS-WRITE's HANDLER-CASE is the actual guard;
;;; the rest of this section is just making sure every branch reaches it or
;;; a no-op notify instead of a bare struct-slot access on NIL.

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
      (handler-case
          (%run-transient-git-write conn repository operation args)
        (error (condition)
          (%client-notify
           conn
           (format nil "git ~(~A~): failed: ~A" operation condition)))))
  t)

(defun %client-stage-selection (conn)
  "s (contract SS3): `git add -- PATH` for the selected :FILE row."
  (let ((selection (%client-selected-status-file conn)))
    (if selection
        (destructuring-bind (worktree path) selection
          (%client-run-status-write
           conn (nerimux/workspace-model:worktree-repository worktree)
           :add (list "--" path)))
        (progn (%client-notify conn "select a file first") t))))

(defun %client-stage-all (conn)
  "S (contract SS3): `git add -A` for the status view's own worktree
   (CLIENT-CONN-SELECTED-WORKTREE, the worktree %RENDER-STATUS-FRAME is
   currently drawing -- there is no per-file selection to key this one off
   of)."
  (let ((worktree (client-conn-selected-worktree conn)))
    (if worktree
        (%client-run-status-write
         conn (nerimux/workspace-model:worktree-repository worktree) :add (list "-A"))
        (progn (%client-notify conn "no worktree selected") t))))

(defun %client-unstage-selection (conn)
  "u (contract SS3): `git restore --staged -- PATH` for the selected :FILE
   row."
  (let ((selection (%client-selected-status-file conn)))
    (if selection
        (destructuring-bind (worktree path) selection
          (%client-run-status-write
           conn (nerimux/workspace-model:worktree-repository worktree)
           :restore (list "--staged" "--" path)))
        (progn (%client-notify conn "select a file first") t))))

(defun %client-unstage-all (conn)
  "U (contract SS3): `git restore --staged -- .` for the status view's own
   worktree, mirroring %CLIENT-STAGE-ALL's worktree resolution."
  (let ((worktree (client-conn-selected-worktree conn)))
    (if worktree
        (%client-run-status-write
         conn (nerimux/workspace-model:worktree-repository worktree)
         :restore (list "--staged" "--" "."))
        (progn (%client-notify conn "no worktree selected") t))))

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
          (let ((repository (nerimux/workspace-model:worktree-repository worktree)))
            (%open-confirm-view
             conn
             (format nil "git restore -- ~A" path)
             (list (cons "worktree" (nerimux/workspace-model:worktree-path worktree))
                   (cons "path" path))
             (lambda ()
               (%client-run-status-write
                conn repository :restore (list "--" path))))
            t))
        (progn (%client-notify conn "select a file first") t))))

(defun %client-open-selected-worktree-command (session conn command)
  "Open a new pane for the selected worktree running COMMAND.
   A NIL command deliberately starts the user's ordinary shell."
  (let ((worktree (client-conn-selected-worktree conn)))
    (unless worktree
      (%select-client-tree-worktree conn nil)
      (setf worktree (client-conn-selected-worktree conn)))
    (if (and worktree
             (%open-client-worktree-pane session conn worktree
                                         :default-command command))
        t
        (%client-notify conn "no worktree selected"))))

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
  ((and (eq view :repolist) (%client-key-p payload #\t))
   (%client-open-selected-worktree-command session conn nil))
  ((and (eq view :repolist) (%client-key-p payload #\c))
   (%client-open-selected-worktree-command
    session conn +workspace-claude-command+))
  ((and (eq view :repolist) (%client-key-p payload #\x))
   (%client-open-selected-worktree-command
    session conn +workspace-codex-command+))
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
