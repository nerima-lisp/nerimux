(in-package #:nerimux)

;;;; Multi-client server: a single select(2)-multiplexed event loop that serves
;;;; MANY attached clients at once, instead of the one-client-at-a-time model in
;;;; server.lisp (accept → serve-one-until-detach → accept-next).
;;;;
;;;; The loop owns a registry of connected clients (*clients*).  Each iteration:
;;;;   1. renders and sends a client-specific frame when *dirty*;
;;;;   2. select()s on the listener fd + every client fd together;
;;;;   3. accepts a new connection when the listener is readable;
;;;;   4. dispatches a message from each readable client (keys/resize/detach/cmd).
;;;;
;;;; The session, PTYs, and per-pane reader threads are unchanged — the reader
;;;; threads still set *dirty* when pane output arrives.  The shared session
;;;; layout continues to use %effective-client-size for PTY compatibility, but
;;;; the presentation frame is rendered independently for each client.
;;;;
;;;; Reuses the shared pieces from server.lisp / protocol / transport:
;;;;   process-client-keys, decode-size, decode-command-payload, render-…,
;;;;   send-frame/read-frame, msg-frame/msg-bye, socket-fd/-stream/close-socket.

;;; ── Client connection registry ──────────────────────────────────────────────

;;; ── Workspace tree UI state (R6.2/R6.3) ─────────────────────────────────────
;;;
;;; Global, not per-CLIENT-CONN: R6.3 requires collapse state, and R6.2 the
;;; refreshing/stale markers, to survive detach/attach for as long as the
;;; server is alive, and %ADD-CLIENT below builds a brand-new CLIENT-CONN on
;;; every attach -- anything stored on that struct would silently reset on
;;; reconnect, which is exactly the requirement this state must not violate.
;;; None of it is persisted to disk (R6.3: "永続化はしない").
;;;
;;; Ownership split: this file defines and mutates the tables; the render
;;; call in %RENDER-CLIENT-FRAME below reads them into the R6 renderer
;;; entry points (nerimux/renderer:render-workspace-overview-to-tui-string).
;;; The mutators are for the multi-dispatch key handlers to call
;;; (Enter on an org/repo row, a VCS fetch/refresh starting and settling, a
;;; pane gaining focus within a worktree) -- see the R6 report for exactly
;;; which handler calls which function.

(defun %workspace-collapsed-nodes ()
  "The collapsed-row set, for callers that load before its DEFVAR.

   the multi-dispatch files are compiled before this file, so naming the
   variable there would compile as an undeclared free reference. A function is
   only a forward reference, which resolves at call time."
  *workspace-collapsed-node-ids*)

(defun %workspace-expanded-nodes ()
  "The expanded-row set for Repositories-section repository rows (default
   COLLAPSED; see *WORKSPACE-EXPANDED-NODE-IDS*), for callers that load
   before its DEFVAR -- same forward-reference rationale as
   %WORKSPACE-COLLAPSED-NODES above."
  *workspace-expanded-node-ids*)

(defun %workspace-file-diffs ()
  "The per-file diff cache (Wave C; see *WORKSPACE-FILE-DIFFS*), for callers
   that load before its DEFVAR -- same forward-reference rationale as
   %WORKSPACE-COLLAPSED-NODES/%WORKSPACE-EXPANDED-NODES above."
  *workspace-file-diffs*)

(defun %set-workspace-file-diff (key value)
  "Write VALUE into *WORKSPACE-FILE-DIFFS* under KEY, the only path any
   caller should use (F4, CWE-400): a genuinely new KEY that would push the
   cache past *WORKSPACE-FILE-DIFFS-CACHE-LIMIT* evicts the oldest entry
   first (*WORKSPACE-FILE-DIFFS-ORDER*, insertion order). Updating an
   already-cached key -- the common :PENDING settling to :READY/:FAILED --
   never evicts, since it does not grow the table."
  (let* ((table (%workspace-file-diffs))
         (new-key-p (not (nth-value 1 (gethash key table)))))
    (when (and new-key-p
               (>= (hash-table-count table) *workspace-file-diffs-cache-limit*))
      (let ((oldest (pop *workspace-file-diffs-order*)))
        (when oldest (remhash oldest table))))
    (setf (gethash key table) value)
    (when new-key-p
      (setf *workspace-file-diffs-order*
            (nconc *workspace-file-diffs-order* (list key))))
    value))

(defun %toggle-workspace-node-collapsed (kind id)
  "Flip the KIND (:ORGANIZATION or :REPOSITORY) / ID row's collapse state
   (R6.3's Enter-toggles-collapse behaviour)."
  (let ((key (list kind id)))
    (if (gethash key *workspace-collapsed-node-ids*)
        (remhash key *workspace-collapsed-node-ids*)
        (setf (gethash key *workspace-collapsed-node-ids*) t))))

(defun %mark-workspace-refreshing (kind id)
  "Record that the KIND/ID node's data is being refreshed (R6.2), and clear
   any stale mark on it -- a fresh attempt in flight supersedes the last
   failure until this one, too, settles."
  (let ((key (list kind id)))
    (setf (gethash key *workspace-refreshing-ids*) t)
    (remhash key *workspace-stale-ids*)))

(defun %clear-workspace-refreshing (kind id &key stale-p)
  "Settle a refresh started with %MARK-WORKSPACE-REFRESHING: always clears
   the refreshing mark; sets the stale mark when STALE-P (the refresh
   failed), else clears it (the refresh succeeded)."
  (let ((key (list kind id)))
    (remhash key *workspace-refreshing-ids*)
    (if stale-p
        (setf (gethash key *workspace-stale-ids*) t)
        (remhash key *workspace-stale-ids*))))

(defun %set-workspace-catalog-refresh-state (organizations mode &key stale-p)
  "Mark or settle every visible node in ORGANIZATIONS in one pass, per MODE.

   Catalog refresh is a batch operation, so its callbacks carry the complete
   tree rather than one node at a time.  Keeping the traversal here makes the
   marker key contract identical to the renderer's tree-node keys.

   MODE is required and distinguishes the two calls a refresh needs: :MARK
   records that a refresh is now in flight for every node
   (%MARK-WORKSPACE-REFRESHING) -- what a refresh's start, and its
   in-progress on-catalog callback, both want; :SETTLE clears that in-flight
   mark (%CLEAR-WORKSPACE-REFRESHING), tagging every node stale when STALE-P
   and fresh otherwise -- what a refresh's terminal callback, on-complete or
   on-error, wants. The previous version had no MODE: it always marked
   unless STALE-P was already true, so a *successful* on-complete re-marked
   every node refreshing instead of settling it, and the tree-wide
   \"refreshing\" label never cleared after a scan that succeeded. MODE makes
   that choice explicit at every call site instead of leaving it to STALE-P,
   which never distinguished in-flight from finished in the first place."
  (labels ((visit (kind id)
             (ecase mode
               (:mark (%mark-workspace-refreshing kind id))
               (:settle (%clear-workspace-refreshing kind id :stale-p stale-p)))))
    (dolist (organization organizations)
      (visit :organization (nerimux/model:organization-id organization))
      (dolist (repository
                (nerimux/model:organization-repositories organization))
        (visit :repository (nerimux/model:repository-id repository))
        (dolist (worktree (nerimux/model:repository-worktrees repository))
          (visit :worktree (nerimux/model:worktree-id worktree)))))
    ;; Wave C: no per-worktree status-refresh settle site exists (both
    ;; callers of this function -- %ADD-CLIENT's initial scan and
    ;; %REFRESH-CLIENT-PICKER's `r` -- are whole-catalog operations), so a
    ;; cached diff is invalidated the coarse way, wholesale, at the same
    ;; :SETTLE this function already uses to close out a status refresh. A
    ;; :MARK call (a refresh only just starting) leaves the cache alone.
    (when (eq mode :settle)
      (clrhash *workspace-file-diffs*)
      ;; F4: the order list must be cleared alongside the table it indexes --
      ;; otherwise every entry CLRHASH just removed stays recorded in
      ;; *WORKSPACE-FILE-DIFFS-ORDER* forever, so the list itself grows
      ;; unbounded across catalog refreshes even though the table it backs
      ;; stays small.
      (setf *workspace-file-diffs-order* nil))
    nil))

(defun %mark-repository-node-stale (repository)
  "Immediately settle REPOSITORY's own tree row -- and each of its worktree
   rows -- to :stale-p t (R6.2/design §7.3: a FAILED object shows stale;
   other objects don't inherit it). Called from a catalog refresh's
   PER-REPOSITORY error channel (NERIMUX/VCS:REFRESH-WORKSPACE-
   ORGANIZATIONS-ASYNC's :ON-REPOSITORY-ERROR) as soon as that one
   repository's own failure is known, rather than waiting for the
   whole-catalog :ON-COMPLETE that follows once every other repository has
   also settled -- and again from %REAPPLY-STALE-REPOSITORY-MARKS below, to
   restore the mark after that :ON-COMPLETE settles the whole catalog fresh."
  (%clear-workspace-refreshing :repository (repository-id repository) :stale-p t)
  (dolist (worktree (repository-worktrees repository))
    (%clear-workspace-refreshing :worktree (worktree-id worktree) :stale-p t)))

(defun %reapply-stale-repository-marks (organizations failed-repository-ids)
  "After a whole-catalog :SETTLE (%SET-WORKSPACE-CATALOG-REFRESH-STATE ...
   :SETTLE :STALE-P NIL, which marks every visible node fresh), re-apply the
   stale mark to each repository in FAILED-REPOSITORY-IDS -- and its
   worktrees -- so a per-repository failure collected during the refresh
   survives that settle instead of being overwritten back to fresh. A
   failed id no longer present in ORGANIZATIONS (the repository vanished
   from the catalog between the failure and this settle) is simply
   skipped, matching %WORKSPACE-FIND-TREE-OBJECT's own not-found handling
   elsewhere in this file."
  (dolist (organization organizations)
    (dolist (repository (nerimux/model:organization-repositories organization))
      (when (member (repository-id repository) failed-repository-ids
                    :test #'equal)
        (%mark-repository-node-stale repository)))))

(defun %remember-worktree-pane (worktree pane)
  "Record PANE as the one to return to next time Enter lands on WORKTREE's
   tree row (R6.3). Call this on every focus change within a worktree, not
   only from the worktree-row Enter handler itself -- the requirement is to
   remember the last-focused pane, not just the last one opened via Enter."
  (when (and worktree pane)
    (setf (gethash (worktree-id worktree) *workspace-worktree-last-pane*) pane)))

(defun %worktree-remembered-pane (worktree)
  "The pane %REMEMBER-WORKTREE-PANE last recorded for WORKTREE, or NIL when
   there is none or it has since closed. Self-healing: a pane no longer
   among WORKTREE's own panes is treated as gone and its stale entry is
   dropped here, so a caller never has to remember to clear this table when
   it closes a pane."
  (when worktree
    (let ((pane (gethash (worktree-id worktree) *workspace-worktree-last-pane*)))
      (cond
        ((null pane) nil)
        ((member pane (worktree-panes worktree) :test #'eq) pane)
        (t (remhash (worktree-id worktree) *workspace-worktree-last-pane*)
           nil)))))

;;; with-loop-safe-error is defined in server-multi-dispatch.lisp (which loads
;;; first) so it is available at compile time to every user, including here.

(define-multi-msg-dispatch
  ;; EOF: peer closed the connection.
  ((null type) :drop)
  ;; Client requested clean detach.
  ((= type +msg-detach+) :drop)
  ;; Initial attach or resize: update CONN's geometry and re-apply effective size.
  ((or (= type +msg-attach+) (= type +msg-resize+))
   (%handle-multi-attach-or-resize session conn type payload))
  ;; Keystroke: feed to the pane's stdin-target (split-window -I) or run through
  ;; the shared prefix/copy-mode pipeline with CONN's private state.
  ((= type +msg-key+)
   (%handle-multi-key-message session conn payload))
  ;; Command forwarding: run-command from a CLI client or control-mode client.
  ((= type +msg-command+)
   (%handle-multi-command-message session conn payload))
  ;; Unknown message type: treat as disconnect.
  (t :drop))

;;; ── Connection lifecycle ────────────────────────────────────────────────────

(defconstant +max-clients+ 32
  "Hard cap on the number of simultaneously registered *CLIENTS* entries.

   Bounds *CLIENTS* growth against a same-uid runaway loop that opens
   connections and never closes them, so unbounded fd consumption cannot take
   down the shared select(2) serve loop.  %ADD-CLIENT refuses the newest
   connection at the cap rather than closing the eldest registered one:
   close-eldest could evict a live attached client to make room for a probe.

   Recovery is no longer partial the way it once was.  A connection that
   CLOSES -- with or without ever sending a byte first, e.g. %STALE-SOCKET-P's
   connect-then-close liveness probe (main-startup-socket.lisp) run on every
   `nerimux attach` -- is reclaimed promptly: either SELECT-FDS reports its fd
   ready (the peer's EOF is itself a readiness event) and READ-FRAME's EOF
   drops it, or the next dirty-frame broadcast's write to it fails and
   %DROP-CLIENT does.  %DROP-CLIENT now closes with :ABORT T
   (NERIMUX/NET:CLOSE-SOCKET), which matters here because a broadcast write
   failing mid-frame leaves the tail of that frame buffered in the fd-stream:
   an ordinary (non-abort) close tries to flush that tail before releasing the
   fd, hits BROKEN-PIPE a second time against the same dead peer, and --
   confirmed on SBCL 2.6.6 -- never reaches its own UNIX-CLOSE, so the fd
   leaked forever even though *CLIENTS* bookkeeping looked perfectly clean.
   :ABORT T skips that flush, so a peer that is already gone cannot make the
   close of THIS end's own fd fail.

   One narrower case still holds a slot past the cap's help: a connection
   that is accepted and then neither closes NOR ever sends anything AND is
   never written to, because *DIRTY* never turns true again (no keystroke, no
   pane output, on any client, session-wide) after it was registered.  With
   no EOF to make it SELECT-ready and no broadcast to time out against, its
   slot is held until either some other activity marks the session dirty
   (which then reclaims it exactly as above) or the server restarts.  Reaching
   that state needs a connection that is opened and then left hanging open on
   an otherwise completely idle session -- narrower than a client that simply
   disconnects, and not what %STALE-SOCKET-P or a normal attach/detach cycle
   does.  If that residual trade stops being acceptable, the fix is an
   idle-registration timer that drops a conn N seconds after %ADD-CLIENT
   unless a first frame completed.

   A `nerimux kill` arriving while capped is refused like any other
   connection -- it cannot be told apart at accept time -- and reports
   \"no reply from server\" promptly rather than hanging.")

(defun %add-client (socket)
  "Register SOCKET as a new client: build its CLIENT-CONN and mark
   the screen dirty so the new client gets an immediate paint.  Returns the
   conn, or NIL when +MAX-CLIENTS+ are already registered -- SOCKET is closed
   instead of registered in that case."
  (when (>= (length *clients*) +max-clients+)
    (close-socket socket)
    (return-from %add-client nil))
  (let ((conn (%make-client-conn :socket socket
                                 :stream (socket-stream socket)
                                 :fd     (socket-fd socket)
                                 :rows   *term-rows*
                                 :cols   *term-cols*
                                 :view   :repolist
                                 :modal  nil
                                 :viewport 0)))
    (push conn *clients*)
    (when (and (not *workspace-catalog-refresh-started-p*)
               (nerimux/vcs:vcs-package-available-p))
      (setf *workspace-catalog-refresh-started-p* t)
      ;; :MARK: this refresh is starting, so every currently-visible node
      ;; goes into the refreshing set (R6.2).
      (%set-workspace-catalog-refresh-state
       (nerimux/vcs:workspace-organizations) :mark)
      ;; handler-case rather than ignore-errors: a synchronous failure
      ;; kicking the async refresh off (e.g. thread creation) must still
      ;; flip *workspace-catalog-loaded-p*, or R6.2's scanning-p is stuck
      ;; true forever with no on-error callback ever going to run.
      (let ((failed-repository-ids nil))
        (handler-case
            (nerimux/vcs:refresh-workspace-organizations-async
             :callback-dispatch #'%enqueue-main-thread-callback
             ;; FR-004b: repository count as the scan discovers each entry,
             ;; well before on-catalog/on-complete -- the renderer's
             ;; "N found" while a large ghq root is still being walked.
             :on-progress
             (lambda (count)
               (setf *workspace-scan-progress* count)
               (%mark-dirty))
             ;; Paint the tree the moment the scan lands: the status refresh
             ;; behind it runs git across every repository and can take seconds
             ;; on a large root, and nothing else marks the screen dirty in the
             ;; meantime — clients would hold the "scanning..." placeholder (or
             ;; a stale empty tree) until every status arrived.
             ;;
             ;; :MARK, not :SETTLE: the status refresh this callback's
             ;; caller runs next (refresh-workspace-status-async) is still in
             ;; flight for every one of these nodes, so they stay marked
             ;; refreshing rather than being settled here only to be
             ;; re-marked moments later.
             :on-catalog
             (lambda (organizations)
               (%set-workspace-catalog-refresh-state organizations :mark)
               (%mark-dirty))
             ;; R6.2/design §7.3: a FAILED object shows stale; other objects
             ;; don't inherit it. One repository's `git status` failing must
             ;; not make every OTHER repository's already-successful row
             ;; look stale too -- mark only this one, immediately, rather
             ;; than waiting for the whole-catalog :ON-COMPLETE below.
             :on-repository-error
             (lambda (repository condition)
               (declare (ignore condition))
               (pushnew (repository-id repository) failed-repository-ids
                        :test #'equal)
               (%mark-repository-node-stale repository)
               (%mark-dirty))
             :on-complete
             (lambda (organizations)
               ;; R6.2: flips scanning-p false for every client from here on,
               ;; regardless of whether ORGANIZATIONS turned out empty.
               (setf *workspace-catalog-loaded-p* t
                     *workspace-scan-progress* nil)
               ;; :SETTLE :STALE-P NIL: this refresh has actually finished --
               ;; every visible node goes fresh, including any repository
               ;; whose own status fetch failed along the way; that failure
               ;; is re-applied immediately below rather than left to the
               ;; blanket STALE-P this whole-catalog settle used to take
               ;; (which is what made ANY per-repository failure mark the
               ;; ENTIRE catalog stale, not just the repository that failed).
               (%set-workspace-catalog-refresh-state
                organizations :settle :stale-p nil)
               (%reapply-stale-repository-marks organizations failed-repository-ids)
               (dolist (client (remove-duplicates
                                (remove-if-not #'%client-live-p
                                               (copy-list *clients*))
                                :test #'eq))
                 (%rebind-client-selection client organizations)
                 (setf (client-conn-picker-items client)
                       (nerimux/picker:build-global-picker-items organizations))
                 (%picker-clamp-index client
                                      (%client-picker-visible-items client)))
               (%mark-dirty))
             ;; :ON-ERROR now covers only a terminal scan failure (e.g. `ghq
             ;; list` itself failing) -- there is no catalog and no further
             ;; on-complete coming, unlike :ON-REPOSITORY-ERROR above, whose
             ;; failures are only ever ONE repository among many that still
             ;; settle normally.
             :on-error
             (lambda (condition)
               (declare (ignore condition))
               ;; R6.2: a failed initial scan must still stop showing
               ;; "scanning..." -- otherwise a client attached before the
               ;; error is stuck on the placeholder forever.
               (setf *workspace-catalog-loaded-p* t
                     *workspace-scan-progress* nil)
               ;; :SETTLE + stale: the refresh has terminated (in error), so
               ;; the in-flight mark must clear here too, not stay set --
               ;; there is no further on-complete coming to clear it.
               (%set-workspace-catalog-refresh-state
                (nerimux/vcs:workspace-organizations) :settle :stale-p t)
               (%mark-dirty)))
          (error (condition)
            (declare (ignore condition))
            (setf *workspace-catalog-loaded-p* t
                  *workspace-scan-progress* nil)
            ;; :SETTLE + stale: kicking the refresh off itself failed
            ;; synchronously, so no callback above will ever run to clear
            ;; the :mark this function set moments ago.
            (%set-workspace-catalog-refresh-state
             (nerimux/vcs:workspace-organizations) :settle :stale-p t)
            (%mark-dirty)))))
    (%mark-dirty)
    conn))

(defun %drop-client (conn &key bye)
  "Remove CONN, optionally send a bye frame, and close its socket.

   This cleanup is idempotent and never propagates I/O errors: it runs from
   error handlers and the server loop's unwind cleanup.  Unregister first,
   then close with ABORT so a broken peer cannot prevent local fd release."
  (when (member conn *clients*)
    (setf *clients* (remove conn *clients*))
    (setf (client-conn-ui-prefix-p conn) nil)
    (when (and bye (streamp (client-conn-stream conn)))
      (handler-case
          (send-frame (client-conn-stream conn) (msg-bye))
        (sb-ext:timeout () nil)
        (sb-bsd-sockets:socket-error () nil)
        (stream-error () nil)))
    (let ((socket (client-conn-socket conn)))
      (when socket
        (handler-case
            (close-socket socket :abort t)
          ;; No logging here: a dead peer already gone by the time we get to
          ;; close it is routine and expected on every drop, not a fault worth a line.
          (peer-io-failure () nil))))))
