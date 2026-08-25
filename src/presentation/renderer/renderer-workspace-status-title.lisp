(in-package #:nerimux/renderer)

;;;; Worktree status labels and client-terminal titles shared by the workspace
;;;; frame, pane status bar, pane compositor, and cl-tui-kit adapter.

;;; ── Worktree status tokens (R6.1) ──────────────────────────────────────────
;;;
;;; WORKTREE-STATUS is NIL until the first successful status refresh and is
;;; reset to NIL when the path disappears. Structural flags come from the
;;; worktree catalog and therefore remain meaningful before that refresh.

(defun %worktree-status-tokens (worktree)
  "Return WORKTREE's structural and VCS status token strings in display order."
  (let ((structural
          (append
           (when (worktree-missing-p worktree) (list "MISSING"))
           (when (worktree-bare-p worktree) (list "BARE"))
           (when (worktree-locked-p worktree) (list "LOCKED"))
           (when (worktree-prunable-p worktree) (list "PRUNABLE")))))
    (if (worktree-status worktree)
        (let ((health
                (append
                 (when (worktree-dirty-p worktree) (list "DIRTY"))
                 (when (worktree-conflict-p worktree) (list "CONFLICT"))
                 (when (plusp (worktree-ahead worktree))
                   (list (format nil "AHEAD ~D" (worktree-ahead worktree))))
                 (when (plusp (worktree-behind worktree))
                   (list (format nil "BEHIND ~D" (worktree-behind worktree)))))))
          (or (append structural health) (list "CLEAN")))
        (append structural (list "UNKNOWN")))))

(defun %worktree-status-label (worktree)
  "WORKTREE's status tokens joined for display."
  (format nil "~{~A~^ ~}" (%worktree-status-tokens worktree)))

(defun %workspace-em-dash ()
  "The single-character placeholder for an unselected workspace value."
  (string (code-char #x2014)))

;;; ── Client-terminal title (R6.11) ───────────────────────────────────────────

(defun %repository-title-text (repository)
  (or (and repository
           (or (and (plusp (length (repository-specification repository)))
                    (repository-specification repository))
               (and (plusp (length (repository-local-path repository)))
                    (repository-local-path repository))
               (repository-id repository)))
      "-"))

(defun %worktree-title-text (worktree)
  (or (and worktree
           (let ((branch (worktree-branch worktree))
                 (path (worktree-path worktree)))
             (or (when (and branch (plusp (length branch))) branch)
                 (and (plusp (length path)) path)
                 (worktree-id worktree))))
      "-"))

(defun %client-title-osc (repository worktree)
  "OSC 0 escape setting the outer client terminal's title."
  (format nil "~C]0;nerimux: ~A ~A ~A~C"
          +esc+ (%repository-title-text repository) (code-char #x2014)
          (%worktree-title-text worktree) (code-char 7)))

(defun %workspace-title-selection (focus-pane selected-tree-object selected-worktree)
  "Resolve the repository and worktree shown in a workspace frame's title."
  (let* ((selected-object
           (or selected-tree-object
               selected-worktree
               (and focus-pane (pane-worktree focus-pane))))
         (worktree (and (typep selected-object 'worktree) selected-object))
         (repository
           (cond
             ((typep selected-object 'repository) selected-object)
             (worktree (worktree-repository worktree))
             (t nil))))
    (values repository worktree)))
