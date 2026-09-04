(in-package #:nerimux/renderer)

(defun workspace-status-view-rows (terminal-rows)
  "Rows available for the status view's scrollable row list: TERMINAL-ROWS
   minus header(1) + separator(1) + footer(1) -- plus, at TERMINAL-ROWS >=
   12, the message line(1) and the 2-line key panel with its own
   divider(+3), the same TERMINAL-ROWS = 12 threshold and same reasoning
   WORKSPACE-TREE-VIEW-ROWS uses for the repolist tree's own key panel
   (renderer-workspace-tree.lisp) -- below that height the panel collapses
   to a single footer line and the message line is dropped rather than
   stealing a row from an already-tight frame. Floored at 1."
  (max 1
       (- (max 1 terminal-rows)
          (if (< terminal-rows 12)
              3
              6))))

(defun %workspace-status-row-selected-p (object selected-object)
  (or (eq object selected-object)
      (and (consp object) (consp selected-object) (equal object selected-object))))

(defun %workspace-status-row-prefix-spans (level selected-p attention-p)
  (list
   (cl-tui-kit/core:make-text-span
    (make-string (* 2 level) :initial-element #\Space))
   (cl-tui-kit/core:make-text-span
    (if selected-p
        ">"
        " ")
    :style
    (if selected-p
        (%workspace-status-style-accent-bold)
        (%workspace-status-style-plain)))
   (cl-tui-kit/core:make-text-span
    (if attention-p
        "!"
        " ")
    :style
    (if attention-p
        (%workspace-status-style-alert)
        (%workspace-status-style-plain)))
   (cl-tui-kit/core:make-text-span " ")))

(defun %workspace-status-diff-line-style (object label)
  (cond
    ((eq (first object) :diff-more) (%workspace-status-style-muted))
    (t (case (fourth object)
         (:pending (%workspace-status-style-muted))
         (:failed (%workspace-status-style-faint))
         (:untracked (%workspace-status-style-muted))
         (t (cond
              ((and (plusp (length label)) (char= (char label 0) #\+))
               (%workspace-status-style-ok))
              ((and (plusp (length label)) (char= (char label 0) #\-))
               (%workspace-status-style-alert))
              ((and (>= (length label) 2) (string= label "@@" :end1 2))
               (%workspace-status-style-accent))
              (t (%workspace-status-style-muted))))))))

(defun %workspace-status-row-content-spans (label object kind)
  "Content spans for one row, dispatched on KIND. :FILE/:COMMIT/:STASH read
   their colour from OBJECT's own fields (mirroring DETAIL-ROW-STYLED-LABEL,
   renderer-workspace.lisp) rather than re-parsing LABEL; every other kind
   draws LABEL as a single span, optionally styled."
  (case kind
    (:section
     (list
      (cl-tui-kit/core:make-text-span label
                                      :style
                                      (%workspace-status-style-heading))))
    (:head (%workspace-status-head-spans object))
    (:file
     (let ((code (fourth object))
           (path (third object)))
       (list
        (cl-tui-kit/core:make-text-span code
                                        :style
                                        (%workspace-status-file-code-style code))
        (cl-tui-kit/core:make-text-span (format nil " ~A" path)))))
    (:commit
     (let ((hash (third object))
           (subject (fourth object)))
       (if (stringp hash)
           (list
            (cl-tui-kit/core:make-text-span hash
                                            :style
                                            (%workspace-status-style-accent))
            (cl-tui-kit/core:make-text-span (format nil " ~A" subject)
                                            :style
                                            (%workspace-status-style-faint)))
           (list
            (cl-tui-kit/core:make-text-span label
                                            :style
                                            (%workspace-status-style-faint))))))
    (:stash
     (let ((reference (third object))
           (message (fourth object)))
       (if (stringp reference)
           (list
            (cl-tui-kit/core:make-text-span reference
                                            :style
                                            (%workspace-status-style-accent))
            (cl-tui-kit/core:make-text-span (format nil " ~A" (or message ""))
                                            :style
                                            (%workspace-status-style-faint)))
           (list
            (cl-tui-kit/core:make-text-span label
                                            :style
                                            (%workspace-status-style-faint))))))
    (:pane
     (if (pane-process-exited-p object)
         (list
          (cl-tui-kit/core:make-text-span label
                                          :style
                                          (%workspace-status-style-alert)))
         (list (cl-tui-kit/core:make-text-span label))))
    (:diff-line
     (list
      (cl-tui-kit/core:make-text-span label
                                      :style
                                      (%workspace-status-diff-line-style object
                                                                         label))))
    (t (list (cl-tui-kit/core:make-text-span label)))))

(defun %workspace-status-row-spans (entry selected-object)
  (destructuring-bind (level label object kind) entry
    (let ((selected-p (%workspace-status-row-selected-p object selected-object))
          (attention-p (%workspace-tree-node-attention-p object kind)))
      (append (%workspace-status-row-prefix-spans level selected-p attention-p)
              (%workspace-status-row-content-spans label object kind)))))

(defun %workspace-status-header-spans (worktree)
  (let* ((repository (worktree-repository worktree))
         (organization (and repository (repository-organization repository)))
         (repository-label
          (cond
            ((and repository organization)
             (format nil
                     "~A/~A"
                     (%organization-tree-label organization)
                     (%repository-tree-label repository)))
            (repository (%repository-tree-label repository))
            (t nil))))
    (list
     (cl-tui-kit/core:make-text-span " nerimux "
                                     :style
                                     (%workspace-status-style-header-chip))
     (cl-tui-kit/core:make-text-span "  STATUS  "
                                     :style
                                     (%workspace-status-style-heading))
     (cl-tui-kit/core:make-text-span
      (if repository-label
          (format nil
                  " ~A · ~A"
                  repository-label
                  (%worktree-tree-label worktree))
          (format nil " ~A" (%worktree-tree-label worktree)))))))

(defun %workspace-status-hint-spans (pairs)
  "One flat spans list for PAIRS (KEY . DESCRIPTION) -- the span equivalent
   of %WORKSPACE-HINT's plain-ANSI string building (renderer-workspace.lisp),
   needed here because this view draws directly onto a surface instead of
   concatenating SGR strings."
  (loop for (key . description) in pairs
        for firstp = t then nil
        append (list
                (cl-tui-kit/core:make-text-span
                 (if firstp
                     key
                     (format nil "  ~A" key))
                 :style
                 (%workspace-status-style-accent-bold))
                (cl-tui-kit/core:make-text-span (format nil " ~A" description)
                                                :style
                                                (%workspace-status-style-muted)))))

(defun %workspace-status-selected-entry (entries selected-object)
  (find-if
   (lambda (entry)
     (%workspace-status-row-selected-p (third entry) selected-object))
   entries))

(defun %workspace-status-key-panel-spans (kind prefix-code)
  "Two span lists -- the status view's bottom key-panel lines -- switching on
   the selected row's KIND. Mirrors %WORKSPACE-KEY-PANEL-CONTENT's per-kind
   dispatch (renderer-workspace.lisp) but with FR-003's status-only stage/
   unstage/discard keys (contract §2) in place of the repolist's worktree-
   management keys, which do not apply to this view."
  (values
   (%workspace-status-hint-spans
    (case kind
      (:section
       (list (cons "TAB" "fold")
             (cons "1..4" "visibility")
             (cons "?" "transient")))
      (:file
       (list (cons "s" "stage")
             (cons "u" "unstage")
             (cons "k" "discard")
             (cons "TAB" "diff")))
      (:stash (list (cons "z" "stash") (cons "TAB" "fold")))
      (:commit (list (cons "n/p" "move")))
      (:pane (list (cons "RET" "focus")))
      (:worktree (list (cons "RET" "open")))
      (t (list (cons "n/p" "move") (cons "TAB" "expand") (cons "g" "refresh")))))
   (%workspace-status-hint-spans
    (list (cons "$" "process log")
          (cons "/" "filter")
          (cons ":" "command")
          (cons "C-p" "picker")
          (cons (format nil "~A d" (%workspace-prefix-label prefix-code))
                "detach")
          (cons "q" "back")))))

(defun %workspace-status-panel-rows-available (rows)
  "Rows the bottom key panel occupies below TERMINAL-ROWS = 12's threshold
   (2 content lines) vs. above the single-line footer it collapses to (1) --
   what a TRANSIENT (Unit TRANSIENT) must fit within before
   RENDER-WORKSPACE-STATUS-TO-TUI-STRING falls back to drawing it full-
   screen instead (contract §3's TRANSIENT-VIEW-HEIGHT/height-fallback
   note)."
  (if (>= rows 12)
      2
      1))

(defun %workspace-status-render-frame (worktree rows
                                                cols
                                                selected-object
                                                scroll
                                                expanded-node-ids
                                                file-diffs
                                                level
                                                messages
                                                transient
                                                prefix-code)
  (let* ((surface (cl-tui-kit/core:make-surface cols rows))
         (entries
          (workspace-status-entries worktree
                                    :expanded-node-ids
                                    expanded-node-ids
                                    :file-diffs
                                    file-diffs
                                    :visibility-level
                                    level))
         (view-rows (workspace-status-view-rows rows))
         (entry-count (length entries))
         (max-scroll (max 0 (- entry-count view-rows)))
         (scroll (max 0 (min (or scroll 0) max-scroll)))
         (visible
          (subseq entries
                  (min scroll entry-count)
                  (min (+ scroll view-rows) entry-count)))
         (key-panel-p (>= rows 12))
         (content-top 1)
         (content-bottom (+ content-top view-rows))
         (separator-row content-bottom)
         (message-row (1+ separator-row))
         (footer-row (max 0 (1- rows)))
         (key-panel-line-1 (1- footer-row))
         (key-panel-separator-row (1- key-panel-line-1))
         (selected-entry
          (%workspace-status-selected-entry entries selected-object))
         (selected-kind (and selected-entry (fourth selected-entry))))
    (cl-tui-kit/core:surface-draw-styled-text surface
                                              0
                                              0
                                              (%workspace-status-header-spans
                                               worktree)
                                              :max-width
                                              cols)
    (loop for entry in visible
          for row from content-top
          do (cl-tui-kit/core:surface-draw-styled-text surface
                                                       0
                                                       row
                                                       (%workspace-status-row-spans
                                                        entry
                                                        selected-object)
                                                       :max-width
                                                       cols))
    (cl-tui-kit/core:surface-draw-styled-text surface
                                              0
                                              separator-row
                                              (list
                                               (cl-tui-kit/core:make-text-span
                                                (make-string cols
                                                             :initial-element
                                                             #\─)
                                                :style
                                                (%workspace-status-style-muted)))
                                              :max-width
                                              cols)
    (let ((panel-top
           (if key-panel-p
               key-panel-separator-row
               footer-row)))
      (cond
        (transient
         (render-transient-panel surface
                                 (cl-tui-kit/core:make-rectangle 0
                                                                 panel-top
                                                                 cols
                                                                 (- rows
                                                                    panel-top))
                                 transient))
        (key-panel-p
          (when messages
            (cl-tui-kit/core:surface-draw-styled-text surface
                                                      0
                                                      message-row
                                                      (list
                                                       (cl-tui-kit/core:make-text-span
                                                        (format nil
                                                                "message: ~A"
                                                                (first messages))
                                                        :style
                                                        (%workspace-status-style-muted)))
                                                      :max-width
                                                      cols))
          (cl-tui-kit/core:surface-draw-styled-text surface
                                                    0
                                                    key-panel-separator-row
                                                    (list
                                                     (cl-tui-kit/core:make-text-span
                                                      (make-string cols
                                                                   :initial-element
                                                                   #\─)
                                                      :style
                                                      (%workspace-status-style-muted)))
                                                    :max-width
                                                    cols)
          (multiple-value-bind (line-1 line-2) 
              (%workspace-status-key-panel-spans selected-kind prefix-code)
            (cl-tui-kit/core:surface-draw-styled-text surface
                                                      0
                                                      key-panel-line-1
                                                      line-1
                                                      :max-width
                                                      cols)
            (cl-tui-kit/core:surface-draw-styled-text surface
                                                      0
                                                      footer-row
                                                      line-2
                                                      :max-width
                                                      cols)))
        (t
         (cl-tui-kit/core:surface-draw-styled-text surface
                                                   0
                                                   footer-row
                                                   (%workspace-status-hint-spans
                                                    (list (cons "q" "back")
                                                          (cons "?" "help")))
                                                   :max-width
                                                   cols))))
    (%surface-to-ansi-frame surface)))

(defun render-workspace-status-to-tui-string (worktree rows
                                                       cols
                                                       &key
                                                       selected-object
                                                       (scroll 0)
                                                       expanded-node-ids
                                                       file-diffs
                                                       visibility-level
                                                       messages
                                                       transient
                                                       (prefix-code #x11))
  "Render the magit-style status buffer for WORKTREE through CL-TUI-KIT's
   headless surface, same contract as RENDER-WORKSPACE-OVERVIEW-TO-TUI-
   STRING (renderer-tui-kit.lisp): a complete ANSI frame string. TRANSIENT,
   when non-NIL and taller than the bottom key panel can hold
   (%WORKSPACE-STATUS-PANEL-ROWS-AVAILABLE), replaces the WHOLE frame with
   Unit TRANSIENT's own full-screen fallback (RENDER-TRANSIENT-FULL-SCREEN-
   TO-TUI-STRING) instead of being drawn into the panel -- the same height-
   fallback contract §3 documents for TRANSIENT-VIEW-HEIGHT."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (level (or visibility-level 2)))
    (if (and transient
             (> (transient-view-height transient)
                (%workspace-status-panel-rows-available rows)))
        (render-transient-full-screen-to-tui-string transient rows cols)
        (%workspace-status-render-frame worktree
                                        rows
                                        cols
                                        selected-object
                                        scroll
                                        expanded-node-ids
                                        file-diffs
                                        level
                                        messages
                                        transient
                                        prefix-code))))

