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
  "The header line. WORKTREE is NIL for a client put in this view before a
   worktree was ever selected (the frame-dispatch contract renders every view
   for such a connection), and then the header carries the chip alone."
  (let* ((repository (and worktree (worktree-repository worktree)))
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
      (cond
        ((null worktree) "")
        (repository-label
         (format nil
                 " ~A · ~A"
                 repository-label
                 (%worktree-tree-label worktree)))
        (t (format nil " ~A" (%worktree-tree-label worktree))))))))

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
   management keys, which do not apply to this view. Every key named here is
   bound in the status view (%HANDLE-CLIENT-UI-KEY-PAYLOAD); the second line
   carries `?`, the way into every transient, whatever row is selected."
  (values
   (%workspace-status-hint-spans
    (case kind
      (:section
       (list (cons "Tab" "fold")
             (cons "1..4" "visibility")
             (cons "s/S" "stage")
             (cons "u/U" "unstage")))
      (:file
       (list (cons "s" "stage")
             (cons "u" "unstage")
             (cons "k" "discard")
             (cons "Tab" "diff")))
      (:stash (list (cons "z" "stash") (cons "Tab" "fold")))
      (:commit (list (cons "l" "log") (cons "d" "diff") (cons "Tab" "expand")))
      (:pane
       (list (cons "Enter" "focus")
             (cons (format nil "~A x" (%workspace-prefix-label prefix-code))
                   "close (in pane)")))
      (t
       (list (cons "s/S" "stage")
             (cons "u/U" "unstage")
             (cons "c" "commit")
             (cons "P" "push")
             (cons "F" "pull")
             (cons "?" "all menus")))))
   (%workspace-status-hint-spans
    (list (cons "n/p" "move")
          (cons "v/q" "back")
          (cons "g" "refresh")
          (cons "?" "menu")
          (cons "$" "log")
          (cons ":" "command")
          (cons (format nil "~A w" (%workspace-prefix-label prefix-code))
                "repolist")
          (cons (format nil "~A d" (%workspace-prefix-label prefix-code))
                "detach")))))

(defun %workspace-status-command-line-spans (command-buffer)
  "The `:` command line as spans: the prompt, the typed buffer and the faint
   completion list %RENDER-WORKSPACE-COMMAND-LINE draws for the repolist,
   built for this view's surface instead of an ANSI stream."
  (let* ((buffer (or command-buffer ""))
         (completions (%workspace-command-completions buffer)))
    (append
     (list (cl-tui-kit/core:make-text-span
            ":"
            :style
            (%workspace-status-style-accent-bold))
           (cl-tui-kit/core:make-text-span buffer))
     (when completions
       (list
        (cl-tui-kit/core:make-text-span (format nil "  ~{~A~^ ~}" completions)
                                        :style
                                        (%workspace-status-style-faint)))))))

(defun %workspace-status-filter-line-spans (tree-filter)
  "The `/` filter input line as spans, the command line's sibling."
  (list
   (cl-tui-kit/core:make-text-span "/"
                                   :style
                                   (%workspace-status-style-accent-bold))
   (cl-tui-kit/core:make-text-span (or tree-filter ""))))

(defmacro %draw-status-text (surface row spans cols)
  `(cl-tui-kit/core:surface-draw-styled-text ,surface
                                             0
                                             ,row
                                             ,spans
                                             :max-width
                                             ,cols))

(defun %workspace-status-transient-rectangle (rows cols transient)
  "The open transient's panel: full width, anchored at the frame's bottom
   edge, as tall as the transient's own content plus its border. It grows
   over the key panel and, if the transient is long, over the status rows
   themselves -- what it never does is replace the frame, so the buffer the
   transient acts on stays on screen above it."
  (%bottom-panel-rectangle rows
                           cols
                           (transient-view-height transient nil (- cols 4))))

(defun %workspace-status-render-frame (worktree rows
                                                cols
                                                selected-object
                                                scroll
                                                expanded-node-ids
                                                file-diffs
                                                level
                                                messages
                                                transient
                                                prefix-code
                                                picker
                                                mode
                                                command-buffer
                                                tree-filter)
  (let* ((surface (cl-tui-kit/core:make-surface cols rows))
         (entries
          (when worktree
            (workspace-status-entries worktree
                                      :expanded-node-ids
                                      expanded-node-ids
                                      :file-diffs
                                      file-diffs
                                      :visibility-level
                                      level)))
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
    (%draw-status-text surface 0 (%workspace-status-header-spans worktree) cols)
    (loop for entry in visible
          for row from content-top
          do (%draw-status-text
              surface row (%workspace-status-row-spans entry selected-object) cols))
    (%draw-status-text
     surface separator-row
     (list (cl-tui-kit/core:make-text-span
            (make-string cols :initial-element #\─)
            :style (%workspace-status-style-muted)))
     cols)
    (when (and key-panel-p messages)
      (%draw-status-text
       surface message-row
       (list (cl-tui-kit/core:make-text-span
              (format nil
                      "message: ~A"
                      (%message-strip-text (first messages)
                                           (max 0 (- cols 9))))
              :style (%workspace-status-style-muted)))
       cols))
    (cond
      ((eq mode :command)
       (%draw-status-text
        surface footer-row
        (%workspace-status-command-line-spans command-buffer)
        cols))
      ((eq mode :filter)
       (%draw-status-text
        surface footer-row
        (%workspace-status-filter-line-spans tree-filter)
        cols))
      (key-panel-p
        (%draw-status-text
         surface key-panel-separator-row
         (list (cl-tui-kit/core:make-text-span
                (make-string cols :initial-element #\─)
                :style (%workspace-status-style-muted)))
         cols)
        (multiple-value-bind (line-1 line-2)
            (%workspace-status-key-panel-spans selected-kind prefix-code)
          (%draw-status-text surface key-panel-line-1 line-1 cols)
          (%draw-status-text surface footer-row line-2 cols)))
      (t
       (%draw-status-text
        surface footer-row
        (%workspace-status-hint-spans
         (list (cons "q" "back") (cons "?" "help")))
        cols)))
    (when transient
      (let ((rectangle
             (%workspace-status-transient-rectangle rows cols transient)))
        (render-transient-panel surface
                                (%draw-panel-frame surface
                                                   rectangle
                                                   (transient-view-title
                                                    transient))
                                transient
                                nil)))
    (when picker
      (destructuring-bind (items query index regex-p status) picker
        (%render-picker-widget surface rows cols items query index regex-p
                               status)))
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
                                                       (prefix-code #x11)
                                                       (picker-open-p nil)
                                                       (picker-items nil)
                                                       (picker-query "")
                                                       (picker-index 0)
                                                       (picker-regex-p nil)
                                                       (picker-status nil)
                                                       (mode nil)
                                                       (command-buffer "")
                                                       (tree-filter nil))
  "Render the magit-style status buffer for WORKTREE through CL-TUI-KIT's
   headless surface, same contract as RENDER-WORKSPACE-OVERVIEW-TO-TUI-
   STRING (renderer-tui-kit.lisp): a complete ANSI frame string. TRANSIENT,
   when non-NIL, is hosted in place as a bordered panel over the bottom of
   this frame (%WORKSPACE-STATUS-TRANSIENT-RECTANGLE); there is no
   replace-the-screen path, since a panel that can grow upwards always has
   somewhere to put its content.
   PICKER-OPEN-P draws the global picker over this frame, the same modal the
   pane and repolist frames host, so opening it from the status view does
   not swap the buffer underneath for the pane view.
   MODE :COMMAND or :FILTER replaces the key panel with that modal's input
   line, exactly as the repolist footer does (RENDER-WORKSPACE-OVERVIEW-TO-
   STRING): `:` and `/` are bound in this view too, and a prompt that draws
   nothing leaves the user typing into an invisible buffer."
  (let* ((rows (max 1 rows))
         (cols (max 1 cols))
         (level (or visibility-level 2)))
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
                                    prefix-code
                                    (when picker-open-p
                                      (list picker-items
                                            picker-query
                                            picker-index
                                            picker-regex-p
                                            picker-status))
                                    mode
                                    command-buffer
                                    tree-filter)))
