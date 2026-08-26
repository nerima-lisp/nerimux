(in-package #:nerimux/renderer)

;;;; Workspace-view frame rendering, drawn as plain ANSI into a string. The
;;;; organization -> repository -> worktree -> window -> pane projection lives
;;;; in renderer-workspace-tree.lisp and is shared with the cl-tui-kit pass.
;;;;
;;;; This is the FIRST of the two passes behind the workspace UI.  The second,
;;;; in renderer-tui-kit.lisp, replays this frame into a cl-tui-kit surface and
;;;; draws the tree and picker as real widgets on top -- which is why
;;;; render-workspace-overview-to-string is called from there with
;;;; :render-tree-p NIL.  That is deliberate plumbing between the two passes,
;;;; not a redundant duplicate.
;;;;
;;;; These functions used to live in renderer-compose.lisp, the pane-frame
;;;; compositor.  They were the workspace views' ONLY reason to reach into that
;;;; file and its VT100 / border / status-bar / copy-mode machinery for
;;;; terminal panes. Split out, the workspace render path depends on generic
;;;; ANSI primitives, workspace presentation helpers, tree projection, and
;;;; none of the pane renderer. The aggregate attention view that used
;;;; to live here (render-workspace-attention-to-string) is gone -- workspace
;;;; contraction phase 3, R1.7 -- but the attention MODEL it read from
;;;; (worktree-attention-p / worktree-attention-reasons /
;;;; organization-attention-count / organization-attention-worktrees) is
;;;; still live: it drives the `!` marks in the tree below.
;;;;
;;;; Load order (declared in nerimux.asd): renderer-format -> workspace
;;;; status/title and command-line helpers -> renderer-workspace-tree ->
;;;; renderer-workspace, ahead of the pane-compositor chain.

(defun %workspace-prefix-label (code)
  (if (and (integerp code) (<= 1 code) (<= code 26))
      (format nil "C-~A" (code-char (+ (char-code #\a) (1- code))))
      (format nil "key/~D" code)))

;;; ── Initial-scan placeholder (R6.2) ─────────────────────────────────────────

(defun %render-workspace-scanning-frame (terminal-rows terminal-cols)
  "The whole-frame placeholder shown while the initial ghq/worktree catalog
   scan is still running (R6.2): an empty tree plus a centred \"scanning...\"
   line, in place of the ordinary header/tree/panes/preview layout, which has
   nothing to show yet."
  (let* ((rows (max 1 terminal-rows))
         (cols (max 1 terminal-cols))
         (stream (make-string-output-stream))
         (message "scanning...")
         (text (%display-clip message cols)))
    (cursor-invisible stream)
    (move-to stream (floor rows 2) (%center-coord cols (%display-width text)))
    (write-string text stream)
    (reset-attrs stream)
    (write-string (%client-title-osc nil nil) stream)
    (get-output-stream-string stream)))

(defun render-workspace-overview-to-string
    (organizations terminal-rows terminal-cols &key focus-pane
                                            selected-tree-object
                                            selected-worktree
                                            (tree-scroll 0)
                                            (messages nil)
                                            (mode :normal)
                                            (prefix-code #x11)
                                            (render-tree-p t)
                                            expanded-node-ids
                                            refreshing-ids
                                            stale-ids
                                            (scanning-p nil)
                                            (command-buffer ""))
  "Render the bare-repository/worktree overview used by an attached client.
   The output is intentionally a complete ANSI frame so it can share the
   headless cl-tui-kit backend with the detail view.
   SCANNING-P (R6.2), when true and ORGANIZATIONS is still empty, replaces
   the whole frame with the initial-scan placeholder instead of the ordinary
   layout below, which has nothing to show yet."
  (if (and scanning-p (null organizations))
      (%render-workspace-scanning-frame terminal-rows terminal-cols)
      (let* ((rows (max 1 terminal-rows))
             (cols (max 1 terminal-cols))
             (stream (make-string-output-stream))
             (multi-column-p (>= cols 9))
             (left-width (if multi-column-p (max 1 (min 30 (floor cols 3))) cols))
             (remaining (if multi-column-p (- cols left-width 1) 0))
             (center-width (if multi-column-p (max 1 (floor remaining 2)) 0))
             (right-width (if multi-column-p
                              (max 1 (- cols left-width center-width 2))
                              0))
             (center-col (if multi-column-p (1+ left-width) 0))
             (right-col (if multi-column-p (+ center-col center-width 1) 0))
             (body-start 1)
             (body-end (max body-start (- rows 2)))
             (selected-object
               (or selected-tree-object
                   selected-worktree
                   (and focus-pane (pane-worktree focus-pane))))
             (selected-worktree
               (and (typep selected-object 'worktree)
                    selected-object))
             (selected-repository
               (cond
                 ((typep selected-object 'repository) selected-object)
                 (selected-worktree (worktree-repository selected-worktree))
                 (t nil)))
             (selected-organization
               (and (typep selected-object 'organization)
                    selected-object))
             (repository-count
               (loop for organization in organizations
                     sum (length (organization-repositories organization))))
             (worktree-count
               (if render-tree-p
                   (loop for organization in organizations
                         sum (loop for repository in
                                   (organization-repositories organization)
                                   sum (length (repository-worktrees repository))))
                   (loop for organization in organizations
                         sum (organization-active-worktree-count organization))))
             (all-tree-entries
               (if render-tree-p
                   (%workspace-flat-tree-entries organizations expanded-node-ids
                                                 :refreshing-ids refreshing-ids
                                                 :stale-ids stale-ids)
                   nil)))
        (labels
            ((cell (row col width value)
               (when (plusp width)
                 (move-to stream row col)
                 ;; %display-clip already pads its own truncation branch to
                 ;; exactly WIDTH columns; the pad below only fires for text
                 ;; shorter than WIDTH, measured by display width (not
                 ;; (length text)) so a fullwidth character does not leave the
                 ;; row one column short (R6.9).
                 (let* ((text (%display-clip value width))
                        (pad (- width (%display-width text))))
                   (write-string text stream)
                   (when (plusp pad)
                     (write-string (make-string pad :initial-element #\Space)
                                   stream)))))
             (reason-text (reasons)
               (if reasons
                   (format nil "~{~A~^,~}"
                           (mapcar (lambda (reason)
                                     (string-downcase (symbol-name reason)))
                                   reasons))
                   "-"))
             (worktree-state (worktree)
               (%worktree-status-label worktree))
             (repository-state (repository)
               (cond
                 ((repository-missing-p repository) "MISSING")
                 ((repository-conflict-p repository) "CONFLICT")
                 ((repository-dirty-p repository) "DIRTY")
                 ((null (repository-worktrees repository)) "NO-WORKTREE")
                 (t "ready"))))
          (cursor-invisible stream)
          (when render-tree-p
            (dotimes (row rows)
              (cell row 0 cols "")))
          (reset-attrs stream)
          (%emit-sgr stream 1)
          (cell 0 0 cols
                (format nil "WORKSPACES  ~D org  ~D repo  ~D worktree"
                        (length organizations)
                        repository-count
                        worktree-count))
          (reset-attrs stream)
          (if multi-column-p
              (let* ((tree-count (length all-tree-entries))
                     (visible-tree-rows (max 0 (- body-end (1+ body-start))))
                     (max-tree-scroll (max 0 (- tree-count
                                                visible-tree-rows)))
                       (tree-scroll (max 0 (min tree-scroll max-tree-scroll)))
                       (visible-tree-lines
                         (subseq all-tree-entries
                                 (min tree-scroll tree-count)
                                 (min (+ tree-scroll visible-tree-rows) tree-count))))
                  (when render-tree-p
                    (cell body-start 0 left-width
                          (format nil "WORKTREE TREE ~D/~D"
                                  tree-scroll max-tree-scroll))
                    (loop for entry in visible-tree-lines
                          for row from (1+ body-start) below body-end
                          do (destructuring-bind (level label object kind) entry
                               (let* ((attention
                                        (%workspace-tree-node-attention-p object kind))
                                      (selected
                                        (eq object selected-object))
                                      (state
                                        (case kind
                                          (:organization
                                           (and (organization-missing-p object)
                                                "MISSING"))
                                          (:repository (repository-state object))
                                          (:worktree (worktree-state object))
                                          (t nil)))
                                      (prefix
                                        (format nil "~A~:[ ~;>~]~:[ ~;!~] "
                                                (make-string (* 2 level)
                                                             :initial-element #\Space)
                                                selected attention)))
                                 (cell row 0 left-width
                                       (format nil "~A~A~:[~; [~A]~]"
                                               prefix label state state))))))
                (cell body-start center-col center-width
                      "PANES branch dirty exit unread")
                (if selected-worktree
                    (let ((panes (reverse (worktree-panes selected-worktree))))
                      (if panes
                          (loop for pane in panes
                                for row from (1+ body-start) below body-end
                                do (cell row center-col center-width
                                         (format nil
                                                 "~:[ ~;>~]~A d:~:[-~;!~] e:~:[-~;!~] u:~:[-~;!~]"
                                                 (eq pane focus-pane)
                                                 (%pane-tree-label pane)
                                                 (and (pane-worktree pane)
                                                      (worktree-dirty-p
                                                       (pane-worktree pane)))
                                                 (pane-process-exited-p pane)
                                                 (pane-unread-output-p pane))))
                          (cell (1+ body-start) center-col center-width
                                "(no attached panes)")))
                    (cell (1+ body-start) center-col center-width
                          (if selected-repository
                              (format nil "~A: select a worktree or press Enter"
                                      (%repository-tree-label selected-repository))
                              (if selected-organization
                                  (format nil "~A: select a repository or press Enter"
                                          (%organization-tree-label selected-organization))
                                  "(select a worktree)"))))
                (cell body-start right-col right-width "PREVIEW")
                (let ((preview-lines
                        (append
                         (mapcar (lambda (message)
                                   (format nil "message: ~A" message))
                                 (reverse messages))
                         (cond
                           (selected-worktree
                             (list
                             (format nil "path: ~A" (worktree-path selected-worktree))
                             (format nil "branch: ~A"
                                     (or (worktree-branch selected-worktree) "-"))
                             (format nil "head: ~A"
                                     (or (worktree-head selected-worktree) "-"))
                             (format nil "state: ~A"
                                     (worktree-state selected-worktree))
                             (format nil "attention: ~A"
                                     (reason-text
                                      (worktree-attention-reasons selected-worktree)))
                             (when focus-pane
                               (format nil "output: ~A"
                                       (pane-last-output focus-pane)))))
                           (selected-repository
                            (list
                             (format nil "repository: ~A"
                                     (%repository-tree-label selected-repository))
                             (format nil "path: ~A"
                                     (or (repository-path selected-repository) "-"))
                             (format nil "state: ~A"
                                     (repository-state selected-repository))
                             (format nil "worktrees: ~D"
                                     (length (repository-worktrees selected-repository)))
                             (format nil "attention: ~:[no~;yes~]"
                                     (%repository-attention-p selected-repository))))
                           (selected-organization
                            (list
                             (format nil "organization: ~A"
                                     (%organization-tree-label selected-organization))
                             (format nil "state: ~A"
                                     (if (organization-missing-p selected-organization)
                                         "MISSING"
                                         "ready"))
                             (format nil "repositories: ~D"
                                     (length
                                      (organization-repositories selected-organization)))
                             (format nil "attention: ~D"
                                     (organization-attention-count selected-organization))))
                           (t (list "No worktree selected"))))))
                  (loop for line in (remove nil preview-lines)
                        for row from (1+ body-start) below body-end
                        do (cell row right-col right-width line)))
                (when (< left-width cols)
                  (loop for row from body-start below body-end
                        do (cell row left-width 1 "|")))
                (when (< right-col cols)
                  (loop for row from body-start below body-end
                        do (cell row (1- right-col) 1 "|"))))
              (cell body-start 0 cols "WORKSPACE OVERVIEW (terminal too narrow for panels)"))
          (reset-attrs stream)
          (if (eq mode :command)
              (%render-workspace-command-line stream (1- rows) cols command-buffer)
              (progn
                (cell (1- rows) 0 cols
                      (format nil
                              "overview[~A] | j/k select Enter open/create | n new | X delete | L lock | U unlock | :wt-create ... | :wt-delete ... | :wt-prune | ~A d | C-p"
                              (string-downcase (princ-to-string mode))
                              (%workspace-prefix-label prefix-code)))
                (reset-attrs stream)))
          ;; R6.11: embedded here for a caller of the plain-ANSI entry point
          ;; directly, but a client only ever sees this through
          ;; RENDER-WORKSPACE-OVERVIEW-TO-TUI-STRING (renderer-tui-kit.lisp),
          ;; whose ansi-frame/tui-kit round-trip parses this OSC sequence and
          ;; then discards it when redrawing from the parsed grid -- that
          ;; function re-emits the same title after the round-trip so it
          ;; actually reaches the outer terminal.
          (write-string (%client-title-osc selected-repository selected-worktree)
                        stream)
          (get-output-stream-string stream)))))
