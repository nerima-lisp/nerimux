(in-package #:nerimux)

(defun %client-enter-input-mode (conn)
  (%transition-client-ui-mode conn :enter-input)
  (%mark-dirty)
  t)

(defun %client-enter-command-mode (conn &optional (initial-buffer ""))
  (setf (client-conn-command-return-view conn)
        (client-conn-view conn))
  (%transition-client-ui-mode conn :enter-command)
  (setf (client-conn-command-buffer conn)
        (if (stringp initial-buffer) initial-buffer ""))
  (%mark-dirty)
  t)

(defun %client-restore-command-view (conn)
  (let ((view (client-conn-command-return-view conn)))
    (when (member view '(:overview :detail) :test #'eq)
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
       (%set-client-view conn :detail)
       (%mark-dirty)
       t)
      ((typep object 'nerimux/model:window)
       (let ((pane (nerimux/model:window-active-pane object)))
         (when pane
           (%set-client-focus conn pane)
           (%set-client-view conn :detail)))
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

(defun %client-tree-collapsible-repository (object)
  "The repository whose collapse state H (below) affects when the selected
   row is OBJECT: OBJECT itself when it already is a repository, else the
   repository owning it. Worktree/window/pane rows carry no collapse state
   of their own -- only organization/repository rows do (R6.3) -- so H on
   one of those has to act on its owning repository instead."
  (typecase object
    (nerimux/model:repository object)
    (nerimux/model:worktree (nerimux/model:worktree-repository object))
    (nerimux/model:window
     (let ((pane (or (nerimux/model:window-active-pane object)
                     (first (nerimux/model:window-panes object)))))
       (and pane (nerimux/model:pane-worktree pane)
            (nerimux/model:worktree-repository
             (nerimux/model:pane-worktree pane)))))
    (nerimux/model:pane
     (and (nerimux/model:pane-worktree object)
          (nerimux/model:worktree-repository
           (nerimux/model:pane-worktree object))))))

(defun %client-tree-collapse-selected (conn)
  "H (item 3): collapse the selected row. An organization or repository row
   collapses directly; a worktree/window/pane row has no collapse state of
   its own, so this collapses its owning repository instead and moves the
   selection up to that repository -- otherwise the cursor would be left on
   a row the collapse itself just removed from the tree."
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/model:organization)
       (setf (gethash (list :organization
                            (nerimux/model:organization-id object))
                      (%workspace-collapsed-nodes))
             t)
       (%mark-dirty)
       t)
      ((typep object 'nerimux/model:repository)
       (setf (gethash (list :repository (nerimux/model:repository-id object))
                      (%workspace-collapsed-nodes))
             t)
       (%mark-dirty)
       t)
      (t
       (let ((repository (%client-tree-collapsible-repository object)))
         (when repository
           (setf (gethash (list :repository
                                (nerimux/model:repository-id repository))
                          (%workspace-collapsed-nodes))
                 t)
           (%set-client-selected-tree-object conn repository)
           (%mark-dirty))
         (not (null repository)))))))

(defun %client-tree-expand-selected (conn)
  "L (item 3): expand the selected row. Only an organization or repository
   row carries collapse state; any other row is visible in the first place
   only because both its ancestors are already expanded, so L on one of
   those is a no-op."
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/model:organization)
       (remhash (list :organization (nerimux/model:organization-id object))
                (%workspace-collapsed-nodes))
       (%mark-dirty)
       t)
      ((typep object 'nerimux/model:repository)
       (remhash (list :repository (nerimux/model:repository-id object))
                (%workspace-collapsed-nodes))
       (%mark-dirty)
       t)
      (t nil))))

(defun %client-enter-tree-filter-mode (conn)
  "`/` always starts from an empty query (vim's `/` semantics), even when a
   previous filter session ended with Enter and left CONN-TREE-FILTER set
   (%TRANSITION-CLIENT-UI-MODE's :ACCEPT path keeps it on exit, precisely so
   the filtered view survives into :normal navigation) -- without resetting
   it here, the next `/` silently prepended new keystrokes onto that old
   query instead of starting fresh."
  (setf (client-conn-tree-filter conn) nil
        (client-conn-tree-scroll conn) 0)
  (%transition-client-ui-mode conn :enter-tree-filter)
  (%mark-dirty)
  t)

(defun %handle-client-input-key-payload (session conn payload)
  "Every byte, ESC included, is forwarded to the focused pane: :input mode has
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

(define-key-rules %copy-key-dispatch (session conn payload)
  (:let ((pane (%resolve-client-focus-pane session nil conn))
         (screen (and pane (pane-screen pane)))))
  ((null screen)
   (%client-notify conn "no focused pane")
   (%transition-client-ui-mode conn :enter-normal))
  (#\k (copy-mode-move-cursor screen :up))
  (#\j (copy-mode-move-cursor screen :down))
  (#\h (copy-mode-move-cursor screen :left))
  (#\l (copy-mode-move-cursor screen :right))
  (#\g (copy-mode-scroll screen most-positive-fixnum))
  (#\G (copy-mode-scroll screen (- most-positive-fixnum)))
  (#\Space (copy-mode-begin-selection screen))
  (#\y (copy-mode-yank screen))
  (#\n (copy-mode-search-next screen))
  (#\N (copy-mode-search-prev screen))
  (#\/ (%client-enter-command-mode conn "search-forward "))
  (#\? (%client-enter-command-mode conn "search-backward "))
  (#\q (%client-exit-copy-mode session conn)))

(defun %handle-client-copy-key-payload (session conn payload)
  "Copy-mode exit is bound to q only; ESC is a plain, unbound byte here (it no
   longer doubles as an exit key -- see R4.2)."
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
    (%transition-client-ui-mode
     conn
     (if (and screen (screen-copy-mode-p screen))
         :enter-copy
         :enter-normal))
    (%mark-dirty)))

(defun %submit-client-command (session conn)
  (let ((input (string-trim '(#\Space #\Tab)
                            (client-conn-command-buffer conn))))
    (setf (client-conn-command-buffer conn) "")
    (if (zerop (length input))
        (progn
          (%client-restore-command-view conn)
          (%transition-client-ui-mode conn :enter-normal)
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
                    (%transition-client-ui-mode conn :enter-normal)
                    (%mark-dirty))))
          (error (condition)
            (%client-notify
             conn
             (format nil "command failed: ~A" condition))
            (%client-restore-command-view conn)
            (%transition-client-ui-mode conn :enter-normal)
            (%mark-dirty)))))
  t)

(define-key-rules %handle-client-command-key-payload (session conn payload)
  (27
   ;; R4.3: see the matching comment in %handle-client-picker-key-payload.
   (%client-esc-swallow-start conn)
   (setf (client-conn-command-buffer conn) "")
   (%client-restore-command-view conn)
   (%transition-client-ui-mode conn :enter-normal)
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

(define-key-rules %handle-client-normal-key-payload (session conn payload)
  (:let ((view (client-conn-view conn))))
  (#\k
   (case view
     (:overview (%select-client-tree-relative conn -1) t)
     (:detail (%client-select-pane-direction session conn :up))
     (otherwise nil)))
  (#\j
   (case view
     (:overview (%select-client-tree-relative conn 1) t)
     (:detail (%client-select-pane-direction session conn :down))
     (otherwise nil)))
  (#\l
   (if (eq view :detail)
       (%client-select-pane-direction session conn :right)
       (%client-tree-expand-selected conn)))
  (#\h
   (if (eq view :detail)
       (%client-select-pane-direction session conn :left)
       (%client-tree-collapse-selected conn)))
  ((and (eq view :overview) (%client-key-p payload #\J))
   (%select-client-tree-repository-relative conn 1))
  ((and (eq view :overview) (%client-key-p payload #\K))
   (%select-client-tree-repository-relative conn -1))
  ((and (eq view :overview) (%client-key-p payload #\/))
   (%client-enter-tree-filter-mode conn))
  ((or (%client-byte-p payload 13) (%client-byte-p payload 10))
   (cond
     ((eq view :overview)
      (%focus-selected-client-worktree session conn))
     (t t)))
  ((and (eq view :overview) (%client-key-p payload #\n))
   (%client-start-worktree-create session conn))
  ((and (eq view :overview) (%client-key-p payload #\X))
   (%client-start-worktree-delete conn))
  ((and (eq view :overview) (%client-key-p payload #\L))
   (%client-start-worktree-lock conn))
  ((and (eq view :overview) (%client-key-p payload #\U))
   (%client-start-worktree-unlock conn))
  (#\d (%set-client-view conn :detail) t)
  (#\o (%set-client-view conn :overview) t)
  (#\r (%client-refresh-workspace conn) t)
  (#\i (%client-enter-input-mode conn))
  (#\c (%client-enter-copy-mode session conn) t)
  (#\: (%client-enter-command-mode conn))
  (t nil))
