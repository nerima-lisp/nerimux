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

;;; ── Styled row emission ─────────────────────────────────────────────────────

(defun %emit-styled-row (stream row col width text)
  "MOVE-TO (ROW, COL) and write TEXT — which may embed SGR escapes — clipped
   SGR-aware to WIDTH display columns and padded with spaces to exactly WIDTH,
   then reset.  The styled sibling of the plain CELL helper below: CELL's
   %DISPLAY-CLIP counts every character, so escape-bearing text must come
   through here instead."
  (when (plusp width)
    (move-to stream row col)
    (let* ((clipped (%visible-truncate text width))
           (pad (- width (%visible-length clipped))))
      (write-string clipped stream)
      (reset-attrs stream)
      (when (plusp pad)
        (write-string (make-string pad :initial-element #\Space) stream)))))

(defun %workspace-state-text (worktree)
  "WORKTREE's status tokens, palette-coloured with a plain reset after each
   token (unlike %STATUS-STATE-TEXT, which restores the status bar's base
   background and would leak it into a default-background panel)."
  (format nil "~{~A~^ ~}"
          (mapcar (lambda (token)
                    (let ((sgr (%worktree-state-token-sgr token)))
                      (if sgr (%sgr-wrap token sgr) token)))
                  (%worktree-status-tokens worktree))))

(defun %workspace-hint (key description)
  "One footer hint: KEY in bold accent, DESCRIPTION muted."
  (format nil "~A ~A"
          (%sgr-wrap key +sgr-accent-bold+)
          (%sgr-wrap description +sgr-muted+)))

(defun %workspace-footer-line (mode prefix-code)
  "The overview footer: a mode chip followed by two-tone key hints.  The
   pre-theme footer spelled out every :wt-* command; those are discoverable
   from the `:` prompt's completion now, so the footer keeps only the
   single-key surface."
  (format nil " ~A  ~{~A~^  ~}"
          (%sgr-wrap (format nil " ~:@(~A~) " mode) +sgr-mode-chip+)
          (list (%workspace-hint "j/k" "select")
                (%workspace-hint "Enter" "open/create")
                (%workspace-hint "n" "new")
                (%workspace-hint "X" "delete")
                (%workspace-hint "L/U" "lock")
                (%workspace-hint ":" "command")
                (%workspace-hint "C-p" "picker")
                (%workspace-hint (format nil "~A d" (%workspace-prefix-label prefix-code))
                                 "detach"))))

;;; ── Initial-scan placeholder (R6.2) ─────────────────────────────────────────

(defun %render-workspace-scanning-frame (terminal-rows terminal-cols &key scan-progress)
  "The whole-frame placeholder shown while the initial ghq/worktree catalog
   scan is still running (R6.2): an empty tree plus a centred \"scanning...\"
   line, in place of the ordinary header/tree/panes/preview layout, which has
   nothing to show yet.
   SCAN-PROGRESS (FR-004b), when a positive integer, names how many
   repositories the scan has found so far instead of the bare ellipsis -- a
   scan that legitimately runs tens of seconds otherwise looks identical at
   second 1 and second 30.  NIL or 0 keeps the plain ellipsis wording."
  (let* ((rows (max 1 terminal-rows))
         (cols (max 1 terminal-cols))
         (stream (make-string-output-stream))
         (message (if (and (integerp scan-progress) (plusp scan-progress))
                      (format nil "scanning workspaces... ~D repositories"
                              scan-progress)
                      "scanning workspaces..."))
         (text (%display-clip message cols)))
    (cursor-invisible stream)
    (move-to stream (floor rows 2) (%center-coord cols (%display-width text)))
    (%emit-sgr stream +sgr-muted-italic+)
    (write-string text stream)
    (reset-attrs stream)
    (write-string (%client-title-osc nil nil) stream)
    (get-output-stream-string stream)))

(defun %render-workspace-empty-catalog-hint (stream rows cols ghq-root)
  "Three centred lines shown over the (otherwise empty) interior when
   ORGANIZATIONS is empty and no scan is running (FR-004c): the ghq catalog
   genuinely has nothing in it, which needs to read differently from the
   SCANNING-P placeholder above -- an empty tree because the scan has not
   finished yet, versus an empty tree because there is nothing to find.
   Callable only once the caller has confirmed ORGANIZATIONS is empty and
   SCANNING-P is false, so it does not re-check either here.
   Uses the same centred-line technique as
   %RENDER-WORKSPACE-SCANNING-FRAME rather than the %CELL/%EMIT-STYLED-ROW
   panel machinery: these lines float over the tree/panes/preview panels'
   empty interior instead of belonging to one of them, and the header/footer
   drawn by the caller are left alone.  Each line is %DISPLAY-CLIP'd -- a
   plain-text clip -- before it is wrapped in SGR, per this file's
   clip-before-SGR ordering rule (%DISPLAY-CLIP must never see escapes)."
  (let ((top (max 0 (1- (floor rows 2))))
        (lines (list (cons "no repositories found" +sgr-muted-italic+)
                     (cons (format nil "ghq root: ~A" ghq-root) +sgr-muted+)
                     (cons "get one: ghq get <owner>/<repo>" +sgr-muted+))))
    (loop for (text . sgr) in lines
          for row from top
          for clipped = (%display-clip text cols)
          do (move-to stream row (%center-coord cols (%display-width clipped)))
             (%emit-sgr stream sgr)
             (write-string clipped stream)
             (reset-attrs stream))))

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
                                            (scan-progress nil)
                                            (catalog-empty-hint nil)
                                            (command-buffer ""))
  "Render the bare-repository/worktree overview used by an attached client.
   The output is intentionally a complete ANSI frame so it can share the
   headless cl-tui-kit backend with the detail view.
   SCANNING-P (R6.2), when true and ORGANIZATIONS is still empty, replaces
   the whole frame with the initial-scan placeholder instead of the ordinary
   layout below, which has nothing to show yet. SCAN-PROGRESS (FR-004b) is
   forwarded to that placeholder unchanged -- see
   %RENDER-WORKSPACE-SCANNING-FRAME.
   CATALOG-EMPTY-HINT (FR-004c), when non-NIL (a ghq root path) and
   ORGANIZATIONS is empty with no scan running, draws a 3-line
   no-repositories-found guide over the interior instead of leaving it
   blank -- see %RENDER-WORKSPACE-EMPTY-CATALOG-HINT."
  (if (and scanning-p (null organizations))
      (%render-workspace-scanning-frame terminal-rows terminal-cols
                                        :scan-progress scan-progress)
      (let* ((rows (max 1 terminal-rows))
             (cols (max 1 terminal-cols))
             (stream (make-string-output-stream))
             (multi-column-p (>= cols 9))
             (left-width (if multi-column-p (%workspace-left-width cols) cols))
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
             ;; Computed for both passes now: the tui pass (render-tree-p NIL)
             ;; leaves row drawing to the tree widget but still labels the
             ;; panel and its scroll position here.
             (all-tree-entries
               (%workspace-flat-tree-entries organizations expanded-node-ids
                                             :refreshing-ids refreshing-ids
                                             :stale-ids stale-ids)))
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
                  (%emit-styled-row
                   stream body-start 0 left-width
                   (if (plusp max-tree-scroll)
                       (format nil "~A ~A"
                               (%sgr-wrap "WORKTREES" +sgr-accent-bold+)
                               (%sgr-wrap (format nil "~D/~D"
                                                  tree-scroll max-tree-scroll)
                                          +sgr-faint+))
                       (%sgr-wrap "WORKTREES" +sgr-accent-bold+)))
                  (when render-tree-p
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
                (%emit-styled-row
                 stream body-start center-col center-width
                 (format nil "~A ~A"
                         (%sgr-wrap "PANES" +sgr-accent-bold+)
                         (%sgr-wrap "d=dirty e=exited u=unread" +sgr-faint+)))
                (if selected-worktree
                    (let ((panes (reverse (worktree-panes selected-worktree))))
                      (if panes
                          (loop for pane in panes
                                for row from (1+ body-start) below body-end
                                do (let ((focused (eq pane focus-pane))
                                         (dirty (and (pane-worktree pane)
                                                     (worktree-dirty-p
                                                      (pane-worktree pane))))
                                         (exited (pane-process-exited-p pane))
                                         (unread (pane-unread-output-p pane)))
                                     (flet ((flag (label on sgr)
                                              (if on
                                                  (%sgr-wrap (format nil "~A:!" label)
                                                             sgr)
                                                  (%sgr-wrap (format nil "~A:-" label)
                                                             +sgr-faint+))))
                                       (%emit-styled-row
                                        stream row center-col center-width
                                        (format nil "~A~A ~A ~A ~A"
                                                (if focused
                                                    (%sgr-wrap ">" +sgr-accent-bold+)
                                                    " ")
                                                (if focused
                                                    (%sgr-wrap (%pane-tree-label pane)
                                                               +sgr-accent-bold+)
                                                    (%pane-tree-label pane))
                                                (flag "d" dirty +sgr-warn+)
                                                (flag "e" exited +sgr-alert+)
                                                (flag "u" unread +sgr-warn+))))))
                          (%emit-styled-row stream (1+ body-start) center-col
                                            center-width
                                            (%sgr-wrap "(no attached panes)"
                                                       +sgr-muted-italic+))))
                    (%emit-styled-row
                     stream (1+ body-start) center-col center-width
                     (%sgr-wrap
                      (if selected-repository
                          (format nil "~A: select a worktree or press Enter"
                                  (%repository-tree-label selected-repository))
                          (if selected-organization
                              (format nil "~A: select a repository or press Enter"
                                      (%organization-tree-label selected-organization))
                              "(select a worktree)"))
                      +sgr-muted-italic+)))
                (%emit-styled-row stream body-start right-col right-width
                                  (%sgr-wrap "PREVIEW" +sgr-accent-bold+))
                (flet ((field (key value)
                         (format nil "~A ~A" (%sgr-wrap key +sgr-muted+) value))
                       (state-field (key state)
                         (format nil "~A ~A"
                                 (%sgr-wrap key +sgr-muted+)
                                 (let ((sgr (%worktree-state-token-sgr state)))
                                   (if sgr (%sgr-wrap state sgr) state)))))
                  (let ((preview-lines
                          (append
                           (mapcar (lambda (message)
                                     (%sgr-wrap (format nil "message: ~A" message)
                                                +sgr-muted-italic+))
                                   (reverse messages))
                           (cond
                             (selected-worktree
                              (list
                               (field "path:" (worktree-path selected-worktree))
                               (field "branch:"
                                      (%sgr-wrap
                                       (or (worktree-branch selected-worktree) "-")
                                       +sgr-branch+))
                               (field "head:"
                                      (or (worktree-head selected-worktree) "-"))
                               (field "state:"
                                      (%workspace-state-text selected-worktree))
                               (field "attention:"
                                      (reason-text
                                       (worktree-attention-reasons selected-worktree)))
                               (when focus-pane
                                 (field "output:"
                                        (pane-last-output focus-pane)))))
                             (selected-repository
                              (list
                               (field "repository:"
                                      (%repository-tree-label selected-repository))
                               (field "path:"
                                      (or (repository-path selected-repository) "-"))
                               (state-field "state:"
                                            (repository-state selected-repository))
                               (field "worktrees:"
                                      (princ-to-string
                                       (length (repository-worktrees
                                                selected-repository))))
                               (field "attention:"
                                      (if (%repository-attention-p selected-repository)
                                          (%sgr-wrap "yes" +sgr-warn+)
                                          "no"))))
                             (selected-organization
                              (list
                               (field "organization:"
                                      (%organization-tree-label selected-organization))
                               (state-field "state:"
                                            (if (organization-missing-p
                                                 selected-organization)
                                                "MISSING"
                                                "ready"))
                               (field "repositories:"
                                      (princ-to-string
                                       (length (organization-repositories
                                                selected-organization))))
                               (field "attention:"
                                      (princ-to-string
                                       (organization-attention-count
                                        selected-organization)))))
                             (t (list (%sgr-wrap "No worktree selected"
                                                 +sgr-muted-italic+)))))))
                    (loop for line in (remove nil preview-lines)
                          for row from (1+ body-start) below body-end
                          do (%emit-styled-row stream row right-col right-width
                                               line))))
                (when (< left-width cols)
                  (loop for row from body-start below body-end
                        do (%emit-styled-row stream row left-width 1
                                             (%sgr-wrap "│" +sgr-line+))))
                (when (< right-col cols)
                  (loop for row from body-start below body-end
                        do (%emit-styled-row stream row (1- right-col) 1
                                             (%sgr-wrap "│" +sgr-line+)))))
              (cell body-start 0 cols "WORKSPACE OVERVIEW (terminal too narrow for panels)"))
          ;; Reaching this branch already means (not (and scanning-p (null
          ;; organizations))) -- the IF above took its other arm otherwise --
          ;; so ORGANIZATIONS being null here already implies SCANNING-P is
          ;; false; no need to re-check it.
          (when (and (null organizations) catalog-empty-hint)
            (%render-workspace-empty-catalog-hint stream rows cols
                                                  catalog-empty-hint))
          (reset-attrs stream)
          (if (eq mode :command)
              (%render-workspace-command-line stream (1- rows) cols command-buffer)
              (%emit-styled-row stream (1- rows) 0 cols
                                (%workspace-footer-line mode prefix-code)))
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
