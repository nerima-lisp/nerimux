(in-package #:nerimux)

(defparameter +default-workspace-prefix-key-code+
  #x11
  "Control-Q, the workspace UI prefix used by the multi-client overview.")
(declaim (special *clients*))
(defvar *last-selected-worktree-token* nil)
(defvar *client-esc-swallow-counts*
  (make-hash-table :test #'eq :weakness :key))
(defparameter +keyboard-owning-modals+
  '(:confirm :help :process-log :transient))
