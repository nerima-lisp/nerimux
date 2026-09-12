(in-package #:nerimux/renderer)

(defun %worktree-change-count-token (worktree)
  "Return WORKTREE's non-empty worktree diff line-count token.
   A zero side is left out: `+1 -0` on a repository with no remote reads as
   the ahead/behind pair the docs give `+N`/`-N` to."
  (when (worktree-status worktree)
    (let ((additions (nerimux/workspace-model:worktree-additions worktree))
          (deletions (nerimux/workspace-model:worktree-deletions worktree)))
      (when (or (plusp additions) (plusp deletions))
        (format nil "~{~A~^ ~}"
                (remove nil
                        (list (when (plusp additions) (format nil "+~D" additions))
                              (when (plusp deletions) (format nil "-~D" deletions)))))))))

(defun %worktree-ahead-behind-tokens (worktree style)
  "WORKTREE's nonzero ahead/behind tokens: `AHEAD 1`/`BEHIND 2` for the tree
   and overview rows, `↑1`/`↓2` for the pane status line, where the words do
   not fit beside the branch and the diff counts already own `+N`/`-N`."
  (append
   (when (plusp (worktree-ahead worktree))
     (list (format nil (if (eq style :arrows) "↑~D" "AHEAD ~D")
                   (worktree-ahead worktree))))
   (when (plusp (worktree-behind worktree))
     (list (format nil (if (eq style :arrows) "↓~D" "BEHIND ~D")
                   (worktree-behind worktree))))))

(defun %worktree-status-tokens (worktree &key (ahead-behind :words))
  "Return WORKTREE's structural and VCS status token strings in display order."
  (let ((structural
         (append
          (when (worktree-missing-p worktree)
            (list "MISSING"))
          (when (worktree-locked-p worktree)
            (list "LOCKED"))
          (when (worktree-prunable-p worktree)
            (list "PRUNABLE")))))
    (if (worktree-status worktree)
        (let ((health
               (append
                (when (worktree-dirty-p worktree)
                  (list "DIRTY"))
                (when (worktree-conflict-p worktree)
                  (list "CONFLICT"))
                (let ((changes (%worktree-change-count-token worktree)))
                  (when changes
                    (list changes)))
                (%worktree-ahead-behind-tokens worktree ahead-behind))))
          (or (append structural health) (list "CLEAN")))
        (append structural (list "UNKNOWN")))))

(defun %worktree-status-label (worktree)
  "WORKTREE's status tokens joined for display."
  (format nil "~{~A~^ ~}" (%worktree-status-tokens worktree)))

(defun %repository-title-text (repository)
  "REPOSITORY's `org/repo` name for the pane status line and the terminal
   title, with a bare clone's `.git` suffix stripped the way the tree
   (%REPOSITORY-TREE-LABEL) and the picker already strip it -- the catalog
   name of `…/beta.git` is displayed everywhere else as `…/beta`."
  (or
   (and repository
        (nerimux/text:strip-dot-git-suffix
         (or
          (and (plusp (length (repository-specification repository)))
               (repository-specification repository))
          (and (plusp (length (repository-local-path repository)))
               (repository-local-path repository))
          (repository-id repository))))
   "-"))

(defun %worktree-title-text (worktree)
  "The status line names WORKTREE the way its tree row does, so a detached
   worktree reads `detached @ sha name` instead of its absolute path."
  (if worktree
      (%worktree-tree-label worktree)
      "-"))

(defun %message-strip-text (message width)
  "MESSAGE fitted into WIDTH display columns, trimmed from the FRONT behind a
   leading ellipsis. A notification names a path by its tail -- `…acme/alpha`
   still identifies the worktree, where the same path clipped from the right
   leaves the user reading the ghq root every other message also starts with."
  (let ((width (max 0 width)))
    (if (<= (%display-width message) width)
        message
        (format nil "…~A" (%display-clip-tail message (max 0 (1- width)))))))

(defun %client-title-osc (repository worktree)
  "OSC 0 escape setting the outer client terminal's title, naming only the
   fields that exist: the em-dash placeholder the absent half used to carry
   put `nerimux: - — -` on a window that simply had nothing selected yet."
  (let ((fields
         (remove nil
                 (list (when repository (%repository-title-text repository))
                       (when worktree (%worktree-title-text worktree))))))
    (format nil
            "~C]0;nerimux~@[: ~A~]~C"
            +esc+
            (when fields (format nil "~{~A~^ · ~}" fields))
            (code-char 7))))

(defun %workspace-title-selection (focus-pane selected-tree-object
                                              selected-worktree)
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
