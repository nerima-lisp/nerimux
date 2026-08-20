(in-package #:nerimux/renderer)

;;;; Workspace-view rendering: the organization -> repository -> worktree tree
;;;; and the attention list, drawn as plain ANSI into a string.
;;;;
;;;; This is the FIRST of the two passes behind the workspace UI.  The second,
;;;; in renderer-tui-kit.lisp, replays this frame into a cl-tui-kit surface and
;;;; draws the tree and picker as real widgets on top -- which is why
;;;; render-workspace-overview-to-string is called from there with
;;;; :render-tree-p NIL.  That is deliberate plumbing between the two passes,
;;;; not a redundant duplicate.
;;;;
;;;; These four functions used to live in renderer-compose.lisp, the pane-frame
;;;; compositor.  They were the workspace views' ONLY reason to reach into that
;;;; file, and through it into the 17-file VT100 / border / status-bar /
;;;; copy-mode machinery that renders terminal panes.  Split out, the workspace
;;;; render path depends on exactly renderer-format.lisp (generic ANSI
;;;; primitives) and renderer-tui-kit.lisp, and on none of the pane renderer.
;;;;
;;;; Load order (declared in nerimux.asd): renderer-format -> renderer-workspace,
;;;; ahead of the pane-compositor chain, so the load order states that dependency.

(defun %workspace-prefix-label (code)
  (if (and (integerp code) (<= 1 code) (<= code 26))
      (format nil "C-~A" (code-char (+ (char-code #\a) (1- code))))
      (format nil "key/~D" code)))

(defun %workspace-attention-events (organizations messages
                                    &optional (recovery-items nil))
  (let ((events nil))
    (labels ((repository-label (repository)
               (or (and (plusp (length (repository-id repository)))
                        (repository-id repository))
                   (repository-specification repository)
                   (repository-path repository)))
             (worktree-label (worktree)
               (or (and (worktree-branch worktree)
                        (plusp (length (princ-to-string
                                        (worktree-branch worktree))))
                        (princ-to-string (worktree-branch worktree)))
                   (worktree-path worktree)
                   (worktree-id worktree)))
             (add-event (label reasons object kind)
               (when reasons
                 (push (list :object object
                             :label label
                             :reasons reasons
                             :kind kind)
                       events))))
      (dolist (organization organizations)
        (dolist (repository (organization-repositories organization))
          (dolist (worktree (repository-worktrees repository))
            (add-event
             (format nil "~A / ~A / ~A"
                     (organization-id organization)
                     (repository-label repository)
                     (worktree-label worktree))
             (worktree-attention-reasons worktree)
             worktree
             :worktree)
            (dolist (pane (reverse (worktree-panes worktree)))
              (add-event
               (format nil "  pane/~D ~A"
                       (pane-id pane)
                       (or (and (plusp (length (pane-title pane)))
                                (pane-title pane))
                           (and (plusp (length (pane-start-command pane)))
                                (pane-start-command pane))
                           "shell"))
               (pane-attention-reasons pane)
               pane
               :pane)))
          (add-event
           (format nil "~A / ~A"
                   (organization-id organization)
                   (repository-label repository))
           (remove nil
                   (list (and (repository-dirty-p repository) :dirty)
                         (and (repository-conflict-p repository) :conflict)
                         (and (plusp (repository-ahead repository)) :ahead)
                         (and (plusp (repository-behind repository)) :behind)
                         (and (repository-missing-p repository) :missing)))
           repository
           :repository)))
      (dolist (recovery-item (reverse recovery-items))
        (add-event (getf recovery-item :label)
                   (getf recovery-item :reasons)
                   recovery-item
                   :runtime-recovery))
      (dolist (message (reverse messages))
        (add-event "notification" '(:notification) message :message))
      (nreverse events))))

(defun render-workspace-attention-to-string
    (organizations terminal-rows terminal-cols &key focus-pane
                                                   (selected-object nil)
                                                   (messages nil)
                                                   (recovery-items nil)
                                                   (mode :normal)
                                                   (prefix-code #x11))
  "Render the aggregate attention view for the attached workspace catalog."
  (let* ((rows (max 1 terminal-rows))
         (cols (max 1 terminal-cols))
         (stream (make-string-output-stream))
         (events (%workspace-attention-events organizations
                                               messages
                                               recovery-items)))
    (labels ((clip (value width)
               (let ((text (if (stringp value)
                               value
                               (princ-to-string value))))
                 (if (<= (length text) width)
                     text
                     (if (<= width 3)
                         (subseq text 0 width)
                         (concatenate 'string
                                      (subseq text 0 (- width 3))
                                      "...")))))
             (cell (row col width value)
               (when (plusp width)
                 (move-to stream row col)
                 (let ((text (clip value width)))
                   (write-string text stream)
                   (when (< (length text) width)
                     (write-string (make-string (- width (length text))
                                                :initial-element #\Space)
                                  stream)))))
             (reason-text (reasons)
               (if reasons
                   (format nil "~{~A~^,~}"
                           (mapcar (lambda (reason)
                                     (string-downcase (symbol-name reason)))
                                   reasons))
                   "-")))
      (cursor-invisible stream)
      (dotimes (row rows)
        (cell row 0 cols ""))
      (%emit-sgr stream 1)
      (cell 0 0 cols
            (format nil "ATTENTION  ~D item~:P~@[  focus pane/~D~]"
                    (length events)
                    (and focus-pane (pane-id focus-pane))))
      (reset-attrs stream)
      (if events
          (loop for event in events
                for label = (getf event :label)
                for reasons = (getf event :reasons)
                for object = (getf event :object)
                for row from 2 below (max 2 (1- rows))
                do (cell row 0 cols
                         (format nil "~:[ ~;>~]~:[ ~;!~] ~A  [~A]"
                                 (eq object selected-object)
                                 (or (typep object 'pane)
                                     (eq (getf event :kind)
                                         :runtime-recovery))
                                 label
                                 (reason-text reasons))))
          (cell 2 0 cols "No attention items"))
      (reset-attrs stream)
      (cell (1- rows) 0 cols
            (format nil
                    "attention | mode: ~A | j/k select Enter open | prefix: ~A d detach | C-p picker | refresh: command workspace-refresh"
                    (string-downcase (princ-to-string mode))
                    (%workspace-prefix-label prefix-code)))
      (reset-attrs stream)
      (get-output-stream-string stream))))

(defun render-workspace-overview-to-string
    (organizations terminal-rows terminal-cols &key focus-pane
                                            selected-tree-object
                                            selected-worktree
                                            (tree-scroll 0)
                                            (messages nil)
                                            (mode :normal)
                                            (prefix-code #x11)
                                            (render-tree-p t))
  "Render the bare-repository/worktree overview used by an attached client.
   The output is intentionally a complete ANSI frame so it can share the
   headless cl-tui-kit backend with the detail view."
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
                     sum (organization-active-worktree-count organization)))))
    (labels
        ((clip (value width)
           (let ((text (if (stringp value) value (princ-to-string value))))
             (if (<= (length text) width)
                 text
                 (if (<= width 3)
                     (subseq text 0 width)
                     (concatenate 'string (subseq text 0 (- width 3)) "...")))))
         (cell (row col width value)
           (when (plusp width)
             (move-to stream row col)
             (let ((text (clip value width)))
               (write-string text stream)
               (when (< (length text) width)
                 (write-string (make-string (- width (length text))
                                            :initial-element #\Space)
                               stream)))))
         (reason-text (reasons)
           (if reasons
               (format nil "~{~A~^,~}"
                       (mapcar (lambda (reason)
                                 (string-downcase (symbol-name reason)))
                               reasons))
               "-"))
         (worktree-state (worktree)
           (cond
             ((worktree-missing-p worktree) "MISSING")
             ((worktree-bare-p worktree) "BARE")
             ((worktree-locked-p worktree) "LOCKED")
             ((worktree-prunable-p worktree) "PRUNABLE")
             (t "ready")))
         (organization-label (organization)
           (let ((host (organization-host organization))
                 (name (organization-name organization)))
             (cond
               ((and (plusp (length host)) (plusp (length name)))
                (format nil "~A/~A" host name))
               ((plusp (length host)) host)
               ((plusp (length name)) name)
               (t (organization-id organization)))))
         (repository-label (repository)
           (or (and (plusp (length (repository-specification repository)))
                    (repository-specification repository))
               (and (plusp (length (repository-local-path repository)))
                    (repository-local-path repository))
               (repository-id repository)))
         (worktree-label (worktree)
           (or (and (worktree-branch worktree)
                    (plusp (length (worktree-branch worktree)))
                    (worktree-branch worktree))
               (and (plusp (length (worktree-path worktree)))
                    (worktree-path worktree))
               (worktree-id worktree)))
         (repository-attention-p (repository)
           (or (repository-dirty-p repository)
               (repository-conflict-p repository)
               (plusp (repository-ahead repository))
               (plusp (repository-behind repository))
               (repository-missing-p repository)
               (some #'worktree-attention-p (repository-worktrees repository))))
         (repository-state (repository)
           (cond
             ((repository-missing-p repository) "MISSING")
             ((repository-conflict-p repository) "CONFLICT")
             ((repository-dirty-p repository) "DIRTY")
             ((null (repository-worktrees repository)) "NO-WORKTREE")
             (t "ready")))
         (pane-label (pane)
           (format nil "pane/~D ~A"
                   (pane-id pane)
                   (or (and (plusp (length (pane-title pane)))
                            (pane-title pane))
                       (and (plusp (length (pane-start-command pane)))
                            (pane-start-command pane))
                       "shell")))
         (tree-entry (level label object kind)
           (list level label object kind))
         (tree-entry-count ()
           (loop for organization in organizations
                 sum (1+
                      (loop for repository in
                                (organization-repositories organization)
                            sum (1+ (length (repository-worktrees repository)))))))
         (tree-entries (start count)
           (let ((index 0)
                 (entries nil)
                 (end (+ start count)))
             (labels ((maybe-add (level object kind)
                        (when (and (>= index start) (< index end))
                          (push (tree-entry
                                 level
                                 (ecase kind
                                   (:organization (organization-label object))
                                   (:repository (repository-label object))
                                   (:worktree (worktree-label object)))
                                 object
                                 kind)
                                entries))
                        (incf index)))
               (dolist (organization organizations)
                 (maybe-add 0 organization :organization)
                 (dolist (repository (organization-repositories organization))
                   (maybe-add 1 repository :repository)
                   (dolist (worktree (repository-worktrees repository))
                     (maybe-add 2 worktree :worktree))))
             (nreverse entries)))))
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
          (let* ((tree-count (if render-tree-p
                                 (tree-entry-count)
                                 0))
                 (visible-tree-rows (max 0 (- body-end (1+ body-start))))
                 (max-tree-scroll (max 0 (- tree-count
                                            visible-tree-rows)))
                   (tree-scroll (max 0 (min tree-scroll max-tree-scroll)))
                   (visible-tree-lines
                     (if render-tree-p
                         (tree-entries tree-scroll visible-tree-rows)
                         nil)))
              (when render-tree-p
                (cell body-start 0 left-width
                      (format nil "WORKTREE TREE ~D/~D"
                              tree-scroll max-tree-scroll))
                (loop for entry in visible-tree-lines
                      for row from (1+ body-start) below body-end
                      do (destructuring-bind (level label object kind) entry
                           (let* ((attention
                                    (case kind
                                      (:organization
                                       (or (plusp (organization-attention-count object))
                                           (organization-attention-worktrees object)))
                                      (:repository (repository-attention-p object))
                                      (:worktree (worktree-attention-p object))))
                                  (selected
                                    (eq object selected-object))
                                  (state
                                    (case kind
                                      (:organization
                                       (and (organization-missing-p object)
                                            "MISSING"))
                                      (:repository (repository-state object))
                                      (:worktree (worktree-state object))))
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
                                             (pane-label pane)
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
                                  (repository-label selected-repository))
                          (if selected-organization
                              (format nil "~A: select a repository or press Enter"
                                      (organization-label selected-organization))
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
                         (format nil "status: ~A"
                                 (or (and (worktree-status selected-worktree)
                                          (princ-to-string
                                           (worktree-status selected-worktree)))
                                     "-"))
                         (format nil "attention: ~A"
                                 (reason-text
                                  (worktree-attention-reasons selected-worktree)))
                         (when (worktree-tags selected-worktree)
                           (format nil "tags: ~{~A~^,~}"
                                   (worktree-tags selected-worktree)))
                         (when (plusp (length (worktree-notes selected-worktree)))
                           (format nil "note: ~A"
                                   (worktree-notes selected-worktree)))
                         (when focus-pane
                           (format nil "output: ~A"
                                   (pane-last-output focus-pane)))
                         (when (and focus-pane
                                    (plusp (length (pane-note focus-pane))))
                            (format nil "note: ~A" (pane-note focus-pane)))))
                       (selected-repository
                        (list
                         (format nil "repository: ~A"
                                 (repository-label selected-repository))
                         (format nil "path: ~A"
                                 (or (repository-path selected-repository) "-"))
                         (format nil "state: ~A"
                                 (repository-state selected-repository))
                         (format nil "worktrees: ~D"
                                 (length (repository-worktrees selected-repository)))
                         (format nil "attention: ~:[no~;yes~]"
                                 (repository-attention-p selected-repository))
                         (when (repository-tags selected-repository)
                           (format nil "tags: ~{~A~^,~}"
                                   (repository-tags selected-repository)))
                         (when (plusp (length (repository-notes selected-repository)))
                           (format nil "note: ~A"
                                    (repository-notes selected-repository)))))
                       (selected-organization
                        (list
                         (format nil "organization: ~A"
                                 (organization-label selected-organization))
                         (format nil "state: ~A"
                                 (if (organization-missing-p selected-organization)
                                     "MISSING"
                                     "ready"))
                         (format nil "repositories: ~D"
                                 (length
                                  (organization-repositories selected-organization)))
                         (format nil "attention: ~D"
                                 (organization-attention-count selected-organization))
                         (when (organization-tags selected-organization)
                           (format nil "tags: ~{~A~^,~}"
                                   (organization-tags selected-organization)))
                         (when (plusp (length (organization-notes selected-organization)))
                           (format nil "note: ~A"
                                    (organization-notes selected-organization)))))
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
      (cell (1- rows) 0 cols
            (format nil
                    "overview[~A] | j/k select Enter open/create | n new | X delete | L lock | U unlock | :wt-create ... | :wt-delete ... | :wt-prune | ~A d | C-p"
                    (string-downcase (princ-to-string mode))
                    (%workspace-prefix-label prefix-code)))
      (reset-attrs stream)
      (get-output-stream-string stream))))
