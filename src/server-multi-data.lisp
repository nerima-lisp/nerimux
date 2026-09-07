(in-package #:nerimux)

(defconstant +kill-sighup-grace-seconds+ 3)

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

(defstruct workspace-assignment
  repository path head model-head worktree-id receipt
  (phase :creating)
  view)

(defvar *workspace-cancel-reservations* (make-hash-table :test #'equal))

(defstruct worktree-delete-reservation
  key worktree panes (phase :pending))

(defstruct workspace-prune-job
  conn queue current reservation directory-identities current-directory-identity
  (operation-jobs (make-hash-table :test #'equal))
  (state :queued) (results nil) cancelled-p)

(defvar *worktree-delete-reservations* (make-hash-table :test #'equal))

(defun %worktree-delete-key (worktree)
  (when worktree
    (let ((repository (nerimux/workspace-model:worktree-repository worktree)))
      (list (and repository
                 (copy-seq (nerimux/workspace-model:repository-id repository)))
            (copy-seq (nerimux/workspace-model:worktree-path worktree))))))

(defun %worktree-delete-pending-p (worktree)
  (let* ((key (%worktree-delete-key worktree))
         (reservation (and key (gethash key *worktree-delete-reservations*))))
    (when reservation
      (if (and (eq (worktree-delete-reservation-phase reservation) :removed)
               (uiop:directory-exists-p
                (nerimux/workspace-model:worktree-path worktree)))
          (progn (remhash key *worktree-delete-reservations*) nil)
          t))))

(defun %pane-delete-pending-p (pane)
  (and pane
       (or (%worktree-delete-pending-p (nerimux/pane:pane-worktree pane))
           (loop for reservation being the hash-values of *worktree-delete-reservations*
                 thereis (member pane (worktree-delete-reservation-panes reservation)
                                 :test #'eq)))))

(defun %window-delete-pending-p (window)
  (and window (some #'%pane-delete-pending-p (window-panes window))))

(defun %workspace-cancel-key (path)
  (or (ignore-errors (namestring (truename path))) path))

(defun %worktree-cancel-pending-p (worktree)
  (and worktree
       (gethash (%workspace-cancel-key
                 (nerimux/workspace-model:worktree-path worktree))
                *workspace-cancel-reservations*)))

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
  (tree-filter nil)
  (workspace-prefix-code +default-workspace-prefix-key-code+ :type fixnum)
  (ui-prefix-p nil :type boolean)
  (viewport 0 :type fixnum)
  (view :repolist)
  (modal nil)
  (transient-arguments nil)
  (transient-view nil)
  (workspace-assignment nil)
  (visibility-level 2 :type (integer 1 4))
  (command-buffer "" :type string)
  (command-return-view nil)
  (attach-target nil)
  (attach-cwd nil)
  (picker-items nil)
  (picker-query "" :type string)
  (picker-regex-p nil :type boolean)
  (picker-index 0 :type fixnum)
  (pending-prune-preview-repository-id nil)
  (confirm-view nil)
  (confirm-action nil)
  (confirm-cancel-action nil)
  (workspace-prune-job nil)
  (process-log nil)
  (process-log-scroll 0 :type fixnum)
  (frame nil)
  (row-frame-candidate nil)
  (sent-row-frame nil))
(declaim (special *clients*))
(defvar *last-selected-worktree-token* nil)
(defvar *client-esc-swallow-counts*
  (make-hash-table :test #'eq :weakness :key))
(defparameter +keyboard-owning-modals+
  '(:confirm :help :process-log :transient))
