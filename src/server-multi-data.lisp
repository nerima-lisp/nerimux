(in-package #:nerimux)

(defconstant +max-clients+ 32)

(defparameter +client-ui-modes+
  '(:normal :input :copy :command :picker :tree-filter))

(defparameter +workspace-claude-command+
  "claude --dangerously-skip-permissions")

(defparameter +workspace-codex-command+
  "codex --dangerously-bypass-approvals-and-sandbox")

(defparameter +default-workspace-prefix-key-code+
  #x11
  "Control-Q, the workspace UI prefix used by the multi-client overview.")

;;;; Shared multi-client connection data.
(defstruct (client-conn (:constructor %make-client-conn))
  "One attached client: its socket, a cached binary STREAM and FD, a private
   keystroke STATE (so each client has independent prefix/copy-mode state), the
   ROWS×COLS geometry it last reported, an optional command-stdin target pane,
   its private UI state, cached frame, and private message log."
  socket
  stream
  fd
  stdin-target
  (message-log nil)
  (rows 24 :type fixnum)
  (cols 80 :type fixnum)
  (focus nil)
  (selected-tree-object nil)
  (selected-worktree nil)
  (tree-scroll 0 :type fixnum)
  ;; The in-flight `/` overview tree-filter query (:tree-filter mode), or NIL
  ;; when no filter is active (cleared by ESC, kept by Enter -- see
  ;; %transition-client-ui-mode). NIL rather than "": an empty string is a
  ;; filter box the user has entered but not typed into yet, still a real
  ;; per-frame state the renderer draws differently from no filter at all.
  (tree-filter nil)
  (workspace-prefix-code +default-workspace-prefix-key-code+ :type fixnum)
  (ui-prefix-p nil :type boolean)
  (viewport 0 :type fixnum)
  ;; The two axes that replaced the old MODE x VIEW product (magit alignment,
  ;; FR-001/FR-007). VIEW says which screen is up; MODAL says what, if anything,
  ;; has taken the keyboard away from that screen.
  ;;
  ;; The product used to have unreachable cells -- (:detail . :normal) meant "a
  ;; pane is focused but keystrokes go to the UI", which is precisely the state
  ;; pressing `i` existed to leave. With panes now taking input directly, where
  ;; a key goes is DERIVED from VIEW whenever MODAL is NIL (%CLIENT-UI-KEYS-P),
  ;; so no such cell exists to be constructed, asserted about, or drifted into.
  ;;
  ;; MODAL is one slot rather than a flag per state on purpose: two flags set at
  ;; once is exactly the unreachable-combination problem this change removes.
  (view :repolist)
  (modal nil)
  ;; Per-client, per-session argument toggles for the transient menus (FR-010),
  ;; as an alist of TRANSIENT-KEY -> list of active flag strings. Kept when the
  ;; transient closes: magit remembers a `--force-with-lease` you set earlier in
  ;; the session, and losing it every close would make the toggle useless.
  (transient-arguments nil)
  (transient-view nil)
  ;; magit's 1/2/3/4 global visibility level (FR-005). 4 = everything expanded,
  ;; 1 = section headings only. Per client rather than per section table: the
  ;; level is a lens over whatever the per-row expand state says, so pressing 4
  ;; then 2 returns to the same rows rather than to a flattened remembering of
  ;; them.
  (visibility-level 2 :type (integer 1 4))
  (command-buffer "" :type string)
  (command-return-view nil)
  (attach-target nil)
  (attach-cwd nil)
  (picker-items nil)
  (picker-query "" :type string)
  (picker-regex-p nil :type boolean)
  (picker-index 0 :type fixnum)
  ;; Set to the REPOSITORY-ID of the repository a dry-run prune preview was
  ;; just shown for; a confirm (dry-run nil) prune must match it, so
  ;; wt-prune-confirm --confirm cannot skip straight past the preview a user
  ;; is meant to review first. Cleared once a confirmed prune completes.
  (pending-prune-preview-repository-id nil)
  ;; The full-screen confirmation (R6.4) this client is currently looking at, or
  ;; NIL. Per client, not per server: two attached clients can be mid-answer on
  ;; different questions, and a confirmation one of them never saw must not
  ;; capture the other's keystrokes.
  (confirm-view nil)
  ;; What to run when the user answers y to CONFIRM-VIEW. A closure of no
  ;; arguments; NIL when no confirmation is up. Kept beside the view rather than
  ;; encoded in it so the renderer keeps taking plain data.
  (confirm-action nil)
  ;; The `$` process log (FR-011): executed git command, exit status, output.
  ;; Most recent first, capped -- see +MAX-PROCESS-LOG-ENTRIES+.
  (process-log nil)
  (process-log-scroll 0 :type fixnum)
  ;; No HELP-VIEW-P flag: the help view carries no per-client data, so MODAL
  ;; :help IS its whole state. A boolean beside MODAL would be a second place
  ;; to say the same thing, and the two could disagree.
  (frame nil))
(declaim (special *clients*))
(defvar *last-selected-worktree-token* nil)
(defvar *client-esc-swallow-counts*
  (make-hash-table :test #'eq :weakness :key))
(defparameter +keyboard-owning-modals+
  '(:confirm :help :process-log :transient))
