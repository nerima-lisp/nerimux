(in-package #:nerimux)

(defconstant +kill-sighup-grace-seconds+ 3)

(defconstant +max-clients+ 32)
(defconstant +max-notify-characters+
  99
  "Maximum length before the single-line message strip hides useful text.")

(defconstant +terminal-identity-term-program-name+
  :term_program
  "Exact TERM_PROGRAM variable name accepted from an attached client.")

(defconstant +terminal-identity-term-program-version-name+
  :term_program_version
  "Exact TERM_PROGRAM_VERSION variable name accepted from an attached client.")

(defconstant +terminal-identity-variable-prefix+
  :kitty_
  "Prefix for terminal identity variables accepted from an attached client.")

(defun %terminal-identity-variable-p (name)
  "Return true when NAME is an accepted POSIX terminal identity variable."
  (and (stringp name)
       (plusp (length name))
       (or (string= name (symbol-name +terminal-identity-term-program-name+))
           (string= name
                    (symbol-name +terminal-identity-term-program-version-name+))
           (and (>= (length name)
                    (length (symbol-name +terminal-identity-variable-prefix+)))
                (string= (symbol-name +terminal-identity-variable-prefix+)
                         name
                         :end2
                         (length (symbol-name +terminal-identity-variable-prefix+)))))
       (or (alpha-char-p (char name 0)) (char= (char name 0) #\_))
       (loop for index from 1 below (length name)
             for character = (char name index)
             always (or (alphanumericp character) (char= character #\_)))))

(defparameter +client-ui-modes+
  '(:normal :input :copy :command :picker :tree-filter))

(defparameter +client-command-allow-list+
  '(:wt-create
    :wt-delete
    :wt-lock
    :wt-unlock
    :wt-prune
    :wt-prune-confirm
    :wt-complete
    :clone
    :workspace-complete
    :workspace-prune
    :workspace-prune-all
    :overview
    :detail
    :refresh
    :kill))

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
  "One attached client: its socket and incremental frame state, FIFO control
   frames, latest pending render state, private UI state, and row baseline."
  socket
  stream
  fd
  (frame-reader (nerimux/transport:make-frame-reader))
  (frame-writer (nerimux/transport:make-frame-writer))
  (control-frame-head nil)
  (control-frame-tail nil)
  (control-frame-bytes 0 :type fixnum)
  (pending-render-state nil)
  (active-output-kind nil)
  (active-output-frame nil)
  (active-row-frame-candidate nil)
  (close-after-write-p nil :type boolean)
  stdin-target
  (message-log nil)
  (rows 24 :type fixnum)
  (cols 80 :type fixnum)
  (focus nil)
  (previous-pane nil)
  (previous-window nil)
  (previous-window-pane nil)
  (host-focused-p t :type boolean)
  (paste-active-p nil :type boolean)
  (paste-pane nil)
  (paste-modal nil)
  (paste-candidate-modal nil)
  (paste-candidate-view nil)
  (paste-candidate-command-return-view nil)
  (paste-candidate-text nil)
  (paste-candidate-text-prompt-kind nil)
  (paste-candidate-text-prompt-title nil)
  (paste-candidate-text-prompt-widget nil)
  (paste-candidate-text-prompt-repository nil)
  (paste-candidate-text-prompt-operation nil)
  (paste-candidate-text-prompt-static-args nil)
  (paste-wrapped-p nil :type boolean)
  (paste-bytes nil :type list)
  (selected-tree-object nil)
  (selected-worktree nil)
  (tree-scroll 0 :type fixnum)
  (tree-filter nil)
  (workspace-prefix-code +default-workspace-prefix-key-code+ :type fixnum)
  (ui-prefix-p nil :type boolean)
  (viewport 0 :type fixnum)
  (view :repolist)
  (modal nil)
  (modal-underlay nil)
  (transient-arguments nil)
  (transient-view nil)
  (read-view nil)
  (read-view-worktree nil)
  (read-search-widget nil)
  (text-prompt-kind nil)
  (text-prompt-title nil)
  (text-prompt-widget nil)
  (text-prompt-repository nil)
  (text-prompt-operation nil)
  (text-prompt-static-args nil)
  (workspace-assignment nil)
  (visibility-level 2 :type (integer 1 4))
  (command-buffer "" :type string)
  (command-return-view nil)
  (attach-target nil)
  (attach-cwd nil)
  (picker-items nil)
  (picker-mode :global)
  (picker-repository nil)
  (picker-query "" :type string)
  (picker-regex-p nil :type boolean)
  (picker-index 0 :type fixnum)
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
(defvar *client-meta-replaying* nil)
(defvar *client-wire-key-p* nil)
(defparameter +keyboard-owning-modals+
  '(:confirm :help :process-log :transient :read-view :read-search :text-prompt))

(defvar *workspace-worktree-last-pane*
  (make-hash-table :test #'equal))

(defconstant +max-client-control-frame-bytes+ (+ (* 64 1024 1024) 5))

(defconstant +max-client-output-buffer-bytes+ (+ (* 128 1024 1024) 10))

(defun %client-output-buffered-bytes (conn)
  (+ (client-conn-control-frame-bytes conn)
     (if (eq :render (client-conn-active-output-kind conn))
         (length (client-conn-active-output-frame conn))
         0)
     (let ((pending (client-conn-pending-render-state conn)))
       (if pending (length (first pending)) 0))))

(defun %client-output-pending-p (conn)
  (or (nerimux/transport:frame-writer-pending-p
       (client-conn-frame-writer conn))
      (client-conn-control-frame-head conn)
      (client-conn-pending-render-state conn)))

(defun %queue-client-control-frame (conn frame)
  (let* ((frame-bytes (length frame))
         (control-bytes (+ (client-conn-control-frame-bytes conn)
                           frame-bytes))
         (total-bytes (+ (%client-output-buffered-bytes conn)
                         frame-bytes)))
    (cond
      ((client-conn-close-after-write-p conn) :closing)
      ((or (> control-bytes +max-client-control-frame-bytes+)
           (> total-bytes +max-client-output-buffer-bytes+))
       (%drop-client conn)
       :overflow)
      (t
       (let ((node (list frame)))
         (if (client-conn-control-frame-tail conn)
             (setf (cdr (client-conn-control-frame-tail conn)) node)
             (setf (client-conn-control-frame-head conn) node))
         (setf (client-conn-control-frame-tail conn) node
               (client-conn-control-frame-bytes conn) control-bytes)
         :queued)))))

(defun %queue-client-render-state (conn frame candidate)
  (unless (client-conn-close-after-write-p conn)
    (let* ((pending (client-conn-pending-render-state conn))
           (previous-bytes (if pending (length (first pending)) 0))
           (total-bytes (+ (- (%client-output-buffered-bytes conn)
                              previous-bytes)
                           (length frame))))
      (if (> total-bytes +max-client-output-buffer-bytes+)
          (progn
            (%drop-client conn)
            :overflow)
          (progn
            (setf (client-conn-pending-render-state conn)
                  (list frame candidate))
            :queued)))))

(defun %clear-client-output (conn)
  (setf (client-conn-frame-reader conn)
        (nerimux/transport:make-frame-reader)
        (client-conn-frame-writer conn)
        (nerimux/transport:make-frame-writer)
        (client-conn-control-frame-head conn) nil
        (client-conn-control-frame-tail conn) nil
        (client-conn-control-frame-bytes conn) 0
        (client-conn-pending-render-state conn) nil
        (client-conn-active-output-kind conn) nil
        (client-conn-active-output-frame conn) nil
        (client-conn-active-row-frame-candidate conn) nil
        (client-conn-close-after-write-p conn) nil
        (client-conn-frame conn) nil
        (client-conn-row-frame-candidate conn) nil
        (client-conn-sent-row-frame conn) nil)
  conn)
