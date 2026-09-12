(in-package #:nerimux/renderer)

(defun %repository-open-worktree-count (repository)
  "How many of REPOSITORY's worktrees a user can open. A MISSING worktree
   still counts -- it keeps its branch and keeps its row, so dropping it
   here made the header disagree with the tree below it."
  (length (repository-worktrees repository)))

(defun %workspace-detail-field (key value)
  (format nil "~A ~A" (%sgr-wrap key +sgr-muted+) value))

(defun %workspace-section-detail-lines (key)
  "The two detail-panel lines for a section header row, which used to report
   \"(no selection)\" while plainly highlighted."
  (list
   (%workspace-detail-field
    "section:"
    (case key
      (:attention "worktrees with a conflict, a missing checkout, a waiting agent or an exited pane")
      (:active "worktrees with a pane open")
      (t "every repository in the workspace")))
   (%sgr-wrap "Enter or Tab folds this section" +sgr-muted-italic+)))

(defun %workspace-diff-row-detail-lines (object file-diffs)
  "The two detail-panel lines for a diff row: its file, and the hunk it sits
   in (the nearest @@ header above it) or the line itself."
  (let* ((path (third object))
         (index (fourth object))
         (lines (and file-diffs
                     (third (gethash (list (second object) path) file-diffs))))
         (hunk
          (when (integerp index)
            (loop for position from (min index (1- (length lines))) downto 0
                  for line = (nth position lines)
                  when (and (>= (length line) 2) (string= line "@@" :end1 2))
                    return line
                  finally (return (nth index lines))))))
    (list (%workspace-detail-field "diff:" path)
          (%sgr-wrap (or hunk "") +sgr-muted+))))

(defun %workspace-row-detail-lines (object file-diffs)
  "The two detail-panel lines for a cons-keyed inline-expansion row -- a
   changed file, a commit, or a diff line."
  (case (first object)
    (:file
     (list (%workspace-detail-field "file:" (third object))
           (format nil "~A  ~A"
                   (%changed-file-state-text (fourth object))
                   (%sgr-wrap "Tab shows its diff" +sgr-muted-italic+))))
    (:commit
     (let ((hash (third object))
           (subject (fourth object)))
       (if (stringp hash)
           (list (%workspace-detail-field "commit:" hash)
                 (%sgr-wrap (or subject "") +sgr-muted+))
           (list (%workspace-detail-field "commit:" "-")
                 (%sgr-wrap "history is still loading" +sgr-muted-italic+)))))
    (:diff-more
     (list (%workspace-detail-field "diff:" (third object))
           (%sgr-wrap "the rest of this diff is not loaded" +sgr-muted-italic+)))
    (t (%workspace-diff-row-detail-lines object file-diffs))))

(defun %workspace-pane-detail-lines (pane)
  "The two detail-panel lines for a pane row: what it runs and where, then
   its own last visible output."
  (list
   (format nil "~A  ~A~@[  ~A~]"
           (%workspace-detail-field "pane:" (%pane-tree-label pane))
           (%workspace-detail-field
            "cwd:"
            (if (plusp (length (pane-start-path pane)))
                (pane-start-path pane)
                "-"))
           (and (pane-process-exited-p pane)
                (%sgr-wrap "exited" +sgr-alert+)))
   (%sgr-wrap
    (let ((output (string-trim " " (pane-last-output pane))))
      (if (plusp (length output)) output "(no output)"))
    +sgr-muted+)))

(defun render-workspace-overview-to-string
    (organizations terminal-rows terminal-cols &key focus-pane
                                            selected-tree-object
                                            selected-worktree
                                            (tree-scroll 0)
                                            (messages nil)
                                            (mode :repolist)
                                            (prefix-code #x11)
                                            (render-tree-p t)
                                            collapsed-node-ids
                                            expanded-node-ids
                                            refreshing-ids
                                            job-labels
                                            stale-ids
                                            file-diffs
                                            (scanning-p nil)
                                            (scan-progress nil)
                                            (catalog-empty-hint nil)
                                            (command-buffer "")
                                            (tree-filter nil)
                                            (precomputed-tree-entries nil))
  "Render the bare-repository/worktree overview used by an attached client:
   a header, the tree panel, a
   separator, a 2-line detail panel for the current selection, a
   most-recent-message strip, and a bottom key panel (2 content lines plus
   its own divider at TERMINAL-ROWS >= 12, else the single-line
   %WORKSPACE-FOOTER-LINE it collapses to). The output is intentionally a
   complete ANSI frame so it can share the headless cl-tui-kit backend with
   the detail view.
   SCANNING-P (R6.2), when true and ORGANIZATIONS is still empty, replaces
   the whole frame with the initial-scan placeholder instead of the ordinary
   layout below, which has nothing to show yet. SCAN-PROGRESS (FR-004b) is
   forwarded to that placeholder unchanged -- see
   %RENDER-WORKSPACE-SCANNING-FRAME.
   CATALOG-EMPTY-HINT (FR-004c), when non-NIL (a ghq root path) and
   ORGANIZATIONS is empty with no scan running, draws a 3-line
   no-repositories-found guide over the interior instead of leaving it
   blank -- see %RENDER-WORKSPACE-EMPTY-CATALOG-HINT.
   TREE-FILTER, when a non-empty string, narrows the tree to matching rows
   and their ancestors (see %WORKSPACE-FILTER-TREE-ENTRIES) regardless of
   MODE; MODE = :FILTER (the live modal set by %CLIENT-ENTER-TREE-FILTER-
   MODE, server-multi-dispatch-command-input.lisp) additionally replaces the
   WHOLE key panel with
   the `/query` input prompt at the bottom row (see %RENDER-WORKSPACE-TREE-
   FILTER-LINE), the same way MODE = :COMMAND replaces it with the command
   line -- neither mode's ordinary key hints or divider draw at all while
   the prompt is active, matching the single-line footer's own pre-key-
   panel behaviour.
  PRECOMPUTED-TREE-ENTRIES, when non-NIL, is used verbatim. NIL requests
  that this function compute the flattened tree entries itself."
  (if (and scanning-p (null organizations))
      (%render-workspace-scanning-frame terminal-rows terminal-cols
                                        :scan-progress scan-progress)
      (let* ((rows (max 1 terminal-rows))
             (cols (max 1 terminal-cols))
             (stream (make-string-output-stream))
             (wide-enough-p (>= cols 9))
             (tall-enough-p (>= rows 7))
             (key-panel-p (>= rows 12))
             (view-rows (workspace-tree-view-rows rows))
             (tree-top 1)
             (tree-bottom (+ tree-top view-rows))
             (separator-row tree-bottom)
             (detail-row-1 (1+ separator-row))
             (detail-row-2 (1+ detail-row-1))
             (message-row (1+ detail-row-2))
             (footer-row (max 0 (1- rows)))
             (key-panel-line-1 (1- footer-row))
             (key-panel-separator-row (1- key-panel-line-1))
             (selected-object
               (or selected-tree-object
                   selected-worktree
                   (and focus-pane (pane-worktree focus-pane))))
             (selected-pane
               (and (typep selected-object 'pane) selected-object))
             (selected-worktree
               (and (typep selected-object 'worktree) selected-object))
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
               (loop for organization in organizations
                     sum (loop for repository in
                               (organization-repositories organization)
                               sum (%repository-open-worktree-count repository)))))
        (labels
            ((cell (row col width value)
               (when (plusp width)
                 (move-to stream row col)
                 (let* ((text (%display-clip value width))
                        (pad (- width (%display-width text))))
                   (write-string text stream)
                   (when (plusp pad)
                     (write-string (make-string pad :initial-element #\Space)
                                   stream)))))
             (field (key value)
               (%workspace-detail-field key value))
             (state-field (key state)
               (format nil "~A ~A"
                       (%sgr-wrap key +sgr-muted+)
                       (let ((sgr (%worktree-state-token-sgr state)))
                         (if sgr (%sgr-wrap state sgr) state))))
             (repository-state (repository)
               (cond
                 ((repository-missing-p repository) "MISSING")
                 ((repository-conflict-p repository) "CONFLICT")
                 ((repository-dirty-p repository) "DIRTY")
                 ((null (repository-worktrees repository)) "NO-WORKTREE")
                 (t "ready")))
             (detail-row-styled-label (label object kind)
               (case kind
                 (:file
                  (let ((state (%changed-file-state-text (fourth object)))
                        (path (third object)))
                    (format nil "~A ~A"
                            (%sgr-wrap state (if (string= state "conflict")
                                                 +sgr-alert+ +sgr-warn+))
                            path)))
                 (:commit
                  (let ((hash (third object)) (subject (fourth object)))
                    (if (stringp hash)
                        (format nil "~A ~A"
                                (%sgr-wrap hash +sgr-accent+)
                                (%sgr-wrap subject +sgr-faint+))
                        (%sgr-wrap label +sgr-faint+))))
                 (:pane
                  (if (pane-process-exited-p object)
                      (%sgr-wrap label +sgr-alert+)
                      label))
                 (:diff-line
                  (cond
                    ((eq (first object) :diff-more)
                     (%sgr-wrap label +sgr-muted+))
                    (t
                     (case (fourth object)
                       (:pending (%sgr-wrap label +sgr-muted+))
                       (:failed (%sgr-wrap label +sgr-faint+))
                       (:untracked (%sgr-wrap label +sgr-muted+))
                       (t
                        (cond
                          ((and (plusp (length label)) (char= (char label 0) #\+))
                           (%sgr-wrap label +sgr-ok+))
                          ((and (plusp (length label)) (char= (char label 0) #\-))
                           (%sgr-wrap label +sgr-alert+))
                          ((and (>= (length label) 2) (string= label "@@" :end1 2))
                           (%sgr-wrap label +sgr-accent+))
                          (t (%sgr-wrap label +sgr-muted+))))))))
                 (t label)))
             (tree-row-text (entry)
               (destructuring-bind (level label object kind &optional fold) entry
                 (let* ((selected
                          (or (eq object selected-object)
                              (and (consp object) (consp selected-object)
                                   (equal object selected-object))))
                        (mark (%workspace-tree-node-mark object kind))
                        (fold-glyph (%workspace-tree-fold-glyph fold))
                        (indent (make-string (* 2 level) :initial-element #\Space))
                        (plain-prefix
                          (format nil "~A~:[ ~;>~]~A ~A "
                                  indent selected mark fold-glyph))
                        (base-plain (format nil "~A~A" plain-prefix label))
                        (styled-prefix
                          (format nil "~A~A~A ~A "
                                  indent
                                  (if selected (%sgr-wrap ">" +sgr-accent-bold+) " ")
                                  (if (string= mark " ")
                                      mark
                                      (%sgr-wrap mark +sgr-alert+))
                                  fold-glyph))
                        (base-styled
                          (format nil "~A~A" styled-prefix
                                  (cond
                                    ((eq kind :section) (%sgr-wrap label +sgr-section+))
                                    ((member kind '(:file :commit :pane :diff-line :diff-more))
                                     (detail-row-styled-label label object kind))
                                    (t label)))))
                   (values
                    (case kind
                      (:worktree
                       (multiple-value-bind (plain styled)
                           (%worktree-tree-info-suffix
                            object (max 0 (- cols (%display-width base-plain) 2)))
                         (declare (ignore plain))
                         (if (plusp (length styled))
                             (format nil "~A  ~A" base-styled styled)
                             base-styled)))
                      (:repository
                       (multiple-value-bind (plain styled)
                           (%repository-tree-info-suffix
                            object (max 0 (- cols (%display-width base-plain) 2)))
                         (declare (ignore plain))
                         (if (plusp (length styled))
                             (format nil "~A  ~A" base-styled styled)
                             base-styled)))
                      (t base-styled))
                    selected))))
             (detail-lines ()
               (cond
                 (selected-worktree
                  (list
                   (field "path:" (worktree-path selected-worktree))
                   (format nil "~A  ~A"
                           (field "head:" (or (worktree-head selected-worktree) "-"))
                           (%workspace-state-text selected-worktree))))
                 (selected-pane (%workspace-pane-detail-lines selected-pane))
                 (selected-repository
                  (let ((state (repository-state selected-repository))
                        (worktrees
                          (field "worktrees:"
                                 (princ-to-string
                                  (%repository-open-worktree-count
                                   selected-repository)))))
                    (list
                     (field "repository:"
                            (%repository-tree-label selected-repository))
                     ;; A resting repository has no state worth a field of its
                     ;; own, the way %WORKTREE-GIT-STATE-TEXT drops CLEAN.
                     (if (string= state "ready")
                         worktrees
                         (format nil "~A  ~A"
                                 (state-field "state:" state)
                                 worktrees)))))
                 (selected-organization
                  (list
                   (field "organization:" (%organization-tree-label selected-organization))
                   (field "repositories:"
                          (princ-to-string
                           (length (organization-repositories selected-organization))))))
                 ((keywordp selected-object)
                  (%workspace-section-detail-lines selected-object))
                 ((consp selected-object)
                  (%workspace-row-detail-lines selected-object file-diffs))
                 (t (list (%sgr-wrap "(no selection)" +sgr-muted-italic+) "")))))
          (cursor-invisible stream)
          (when render-tree-p
            (dotimes (row rows)
              (cell row 0 cols "")))
          (reset-attrs stream)
          (%emit-styled-row
           stream 0 0 cols
           (format nil " ~A  ~A ~A  ~A ~A  ~A ~A"
                   (%sgr-wrap " nerimux " +sgr-header-chip+)
                   (%sgr-wrap (princ-to-string (length organizations))
                              +sgr-accent-bold+)
                   (%sgr-wrap "org" +sgr-muted+)
                   (%sgr-wrap (princ-to-string repository-count)
                              +sgr-accent-bold+)
                   (%sgr-wrap "repo" +sgr-muted+)
                   (%sgr-wrap (princ-to-string worktree-count)
                              +sgr-accent-bold+)
                   (%sgr-wrap "worktree" +sgr-muted+)))
          (if (and wide-enough-p tall-enough-p)
              (let* ((all-tree-entries
                       (or precomputed-tree-entries
                           (workspace-flat-tree-entries
                            organizations collapsed-node-ids
                            :refreshing-ids refreshing-ids
                            :job-labels job-labels
                            :stale-ids stale-ids
                            :filter tree-filter
                            :expanded-node-ids expanded-node-ids
                            :file-diffs file-diffs)))
                     (tree-count (length all-tree-entries))
                     (no-matches-p (and (plusp (length (or tree-filter "")))
                                        (plusp (length organizations))
                                        (zerop tree-count))))
                (cond
                  (no-matches-p
                   (let* ((message (format nil "no matches: /~A" tree-filter))
                          (clipped (%display-clip message cols))
                          (width (%display-width clipped)))
                     (%emit-styled-row
                      stream (+ tree-top (floor view-rows 2))
                      (%center-coord cols width) width
                      (%sgr-wrap clipped +sgr-muted-italic+))))
                  (render-tree-p
                   (let* ((max-tree-scroll (max 0 (- tree-count view-rows)))
                          (tree-scroll (max 0 (min tree-scroll max-tree-scroll)))
                          (visible-tree-lines
                            (subseq all-tree-entries
                                    (min tree-scroll tree-count)
                                    (min (+ tree-scroll view-rows) tree-count))))
                     (loop for entry in visible-tree-lines
                           for row from tree-top below tree-bottom
                           do (multiple-value-bind (text selected)
                                  (tree-row-text entry)
                                (%emit-styled-row
                                 stream row 0 cols text
                                 (and selected
                                      +sgr-tree-row-selected-background+)))))))
                (%emit-styled-row
                 stream separator-row 0 cols
                 (%sgr-wrap (make-string cols :initial-element #\─) +sgr-line+))
                (let ((lines (detail-lines)))
                  (%emit-styled-row stream detail-row-1 0 cols (or (first lines) ""))
                  (%emit-styled-row stream detail-row-2 0 cols (or (second lines) "")))
                (when messages
                  (%emit-styled-row
                   stream message-row 0 cols
                   (%sgr-wrap
                    (format nil
                            "message: ~A"
                            (%message-strip-text (first messages)
                                                 (max 0 (- cols 9))))
                    +sgr-muted-italic+))))
              (cell (min tree-top (max 0 (1- rows))) 0 cols
                    (cond
                      ((not (or wide-enough-p tall-enough-p))
                       "WORKSPACE OVERVIEW (terminal too small for panels)")
                      ((not wide-enough-p)
                       "WORKSPACE OVERVIEW (terminal too narrow for panels)")
                      (t "WORKSPACE OVERVIEW (terminal too short for panels)"))))
          (when (and (null organizations) catalog-empty-hint)
            (%render-workspace-empty-catalog-hint stream rows cols
                                                  catalog-empty-hint))
          (reset-attrs stream)
          (cond
            ((eq mode :command)
             (%render-workspace-command-line stream footer-row cols command-buffer))
            ((eq mode :filter)
             (%render-workspace-tree-filter-line stream footer-row cols tree-filter))
            (key-panel-p
             (%emit-styled-row
              stream key-panel-separator-row 0 cols
              (%sgr-wrap (make-string cols :initial-element #\─) +sgr-line+))
             (multiple-value-bind (line-1 line-2)
                 (%workspace-key-panel-content
                  selected-object mode prefix-code tree-filter)
               (%emit-styled-row stream key-panel-line-1 0 cols line-1)
               (%emit-styled-row stream footer-row 0 cols line-2)))
            (t
             (%emit-styled-row stream footer-row 0 cols
                               (%workspace-footer-line mode prefix-code tree-filter))))
          (write-string (%client-title-osc selected-repository selected-worktree)
                        stream)
          (get-output-stream-string stream)))))
