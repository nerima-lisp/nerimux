(in-package #:nerimux/ports)

;;;; VCS port

(defvar *vcs-list-repositories* nil
  "Function (&key ...) -> organization hierarchy.")

(defvar *vcs-list-worktrees* nil
  "Function (repository &key ...) -> worktree list.")

(defvar *vcs-status* nil
  "Function (worktree &key ...) -> updated worktree.")

(defvar *vcs-scan-async* nil
  "Function (&key ...) -> implementation-specific async handle.")

(defvar *vcs-create-worktree* nil
  "Function (repository path branch) -> updated worktree or async handle.")

(defvar *vcs-delete-worktree* nil
  "Function (worktree) -> implementation-specific result or async handle.")

(defun %require-vcs-port (function name)
  (or function
      (error "VCS port ~A is not installed. Call NERIMUX/VCS:INSTALL-VCS-PORT."
             name)))

(defun vcs-list-repositories (&rest arguments)
  "List ghq repositories through the installed VCS adapter."
  (apply (%require-vcs-port *vcs-list-repositories* 'vcs-list-repositories)
         arguments))

(defun vcs-list-worktrees (repository &rest arguments)
  "List REPOSITORY worktrees through the installed VCS adapter."
  (apply (%require-vcs-port *vcs-list-worktrees* 'vcs-list-worktrees)
         repository arguments))

(defun vcs-worktree-status (worktree &rest arguments)
  "Refresh WORKTREE status through the installed VCS adapter."
  (apply (%require-vcs-port *vcs-status* 'vcs-worktree-status)
         worktree arguments))

(defun vcs-status (worktree &rest arguments)
  "Backward-compatible alias for VCS-WORKTREE-STATUS."
  (apply #'vcs-worktree-status worktree arguments))

(defun vcs-scan-async (&rest arguments)
  "Start an asynchronous repository scan through the installed adapter."
  (apply (%require-vcs-port *vcs-scan-async* 'vcs-scan-async)
         arguments))

(defun vcs-create-worktree (&rest arguments)
  "Create a worktree through the installed VCS adapter."
  (apply (%require-vcs-port *vcs-create-worktree* 'vcs-create-worktree)
         arguments))

(defun vcs-delete-worktree (&rest arguments)
  "Delete a worktree through the installed VCS adapter."
  (apply (%require-vcs-port *vcs-delete-worktree* 'vcs-delete-worktree)
         arguments))
