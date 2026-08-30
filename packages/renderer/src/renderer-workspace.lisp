(in-package #:nerimux/renderer)

;;;; Workspace-view frame rendering, drawn as plain ANSI into a string. The
;;;; organization -> repository -> worktree -> window -> pane projection lives
;;;; in renderer-workspace-tree.lisp and is shared with the cl-tui-kit pass.
;;;;
;;;; This is the FIRST of the two passes behind the workspace UI.  The second,
;;;; in renderer-tui-kit.lisp, replays this frame into a cl-tui-kit surface and
;;;; draws the tree as a real widget on top -- which is why
;;;; render-workspace-overview-to-string is called from there with
;;;; :render-tree-p NIL.  That is deliberate plumbing between the two passes,
;;;; not a redundant duplicate.
;;;;
;;;; Overview redesign PR2: the WORKTREES/PANES/PREVIEW three-column layout
;;;; ("worktrees column hard to read", "Enter floods the screen with a
;;;; branch list") is gone. The frame is now one column, top to bottom:
;;;; header (1 row, unchanged) / tree (WORKSPACE-TREE-VIEW-ROWS rows, full
;;;; width, section-based -- see renderer-workspace-tree.lisp) / a horizontal
;;;; separator (1 row) / a 2-line detail panel for whatever tree row is
;;;; selected / a 1-line most-recent-message strip / a bottom key panel.
;;;;
;;;; The section-based overview redesign replaced the old single-line footer
;;;; with a 2-line key panel (plus its own divider) whose content switches on
;;;; the selected row's KIND -- section, repository, or worktree -- so the
;;;; hints on screen always name keys that do something on the current
;;;; selection (see %WORKSPACE-KEY-PANEL-CONTENT). Below TERMINAL-ROWS = 12
;;;; there is no room for 3 extra rows over the pre-redesign layout, so the
;;;; panel collapses back to the original single %WORKSPACE-FOOTER-LINE.
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

(defun %workspace-footer-line (mode prefix-code &optional tree-filter)
  "The overview footer: a mode chip followed by two-tone key hints.  The
   pre-theme footer spelled out every :wt-* command; those are discoverable
   from the `:` prompt's completion now, so the footer keeps only the
   single-key surface. When TREE-FILTER is a non-empty string, a muted
   `/query` chip is prepended so an active filter stays visible after the
   user leaves tree-filter input mode and returns to ordinary navigation
   (R... one-column redesign, PR2)."
  (format nil " ~A~A  ~{~A~^  ~}"
          (if (plusp (length (or tree-filter "")))
              (format nil "~A  " (%sgr-wrap (format nil "/~A" tree-filter) +sgr-muted+))
              "")
          (%sgr-wrap (format nil " ~:@(~A~) " mode) +sgr-mode-chip+)
          (list (%workspace-hint "n/p" "select")
                (%workspace-hint "Enter" "open")
                (%workspace-hint "Tab" "expand")
                (%workspace-hint "g" "refresh")
                (%workspace-hint "/" "filter")
                (%workspace-hint ":" "command")
                (%workspace-hint "?" "menu")
                (%workspace-hint (format nil "~A d" (%workspace-prefix-label prefix-code))
                                 "detach"))))

(defun %workspace-key-panel-content (selected-object mode prefix-code tree-filter)
  "Two values -- the key panel's two content lines -- switching on
   SELECTED-OBJECT's row kind: a section keyword (:ATTENTION/:ACTIVE/
   :REPOSITORIES, the section headers' OBJECT), a REPOSITORY, or anything
   else (a WORKTREE, or no selection at all, which shares the worktree-row
   hints as the common default). Line 2 carries the mode chip and the
   tree-filter's `/query` chip, mirroring %WORKSPACE-FOOTER-LINE -- the
   single-line footer this panel replaces at TERMINAL-ROWS >= 12."
  (values
   (format nil " ~{~A~^  ~}"
           (cond
             ((keywordp selected-object)
              (list (%workspace-hint "Enter/Tab" "fold")
                    (%workspace-hint "M-n/M-p" "section")
                    (%workspace-hint "1-4" "level")
                    (%workspace-hint "/" "filter")
                    (%workspace-hint "C-p" "picker")
                    (%workspace-hint "g" "refresh")))
             ((typep selected-object 'repository)
              (list (%workspace-hint "Enter" "shell(main)")
                    (%workspace-hint "Tab" "expand")
                    (%workspace-hint "w" "worktree menu")
                    (%workspace-hint "f" "fetch menu")))
             ;; Inline worktree expansion (Wave B): a :COMMIT row has no
             ;; action of its own -- Enter genuinely does nothing, shown
             ;; honestly rather than hidden or faked as working.
             ;; Wave C gave :FILE its Tab action (inline diff); :DIFF-LINE/
             ;; :DIFF-MORE (the diff's own child rows) are navigation-only,
             ;; same rationale as :COMMIT.
             ((and (consp selected-object) (eq (first selected-object) :file))
              (list (%workspace-hint "Tab" "diff")
                    (%workspace-hint "s/u" "stage")
                    (%workspace-hint "k" "discard")
                    (%workspace-hint "n/p" "move")))
             ((and (consp selected-object)
                   (member (first selected-object) '(:diff-line :diff-more)))
              (list (%workspace-hint "n/p" "move")))
             ((and (consp selected-object) (eq (first selected-object) :commit))
              (list (%workspace-hint "n/p" "select")
                    (%workspace-hint "Tab" "diff")))
             ((typep selected-object 'pane)
              (list (%workspace-hint "Enter" "focus")
                    (%workspace-hint "n/p" "select")))
             (t
              (list (%workspace-hint "Enter" "shell")
                    (%workspace-hint "Tab" "expand")
                    (%workspace-hint "w" "worktree menu")
                    (%workspace-hint "c/P/F" "commit/push/pull")
                    (%workspace-hint "g" "refresh")))))
   (format nil " ~A~A  ~{~A~^  ~}"
           (if (plusp (length (or tree-filter "")))
               (format nil "~A  " (%sgr-wrap (format nil "/~A" tree-filter) +sgr-muted+))
               "")
           (%sgr-wrap (format nil " ~:@(~A~) " mode) +sgr-mode-chip+)
           ;; Line 2 is the "leaving this screen" row. It no longer advertises
           ;; o/d/i/c: view switching is Enter and q now, and a pane takes
           ;; typing with no mode to enter, so `i` and `c` have nothing to name.
           (list (%workspace-hint "q" "back")
                 (%workspace-hint "?" "menu")
                 (%workspace-hint "$" "log")
                 (%workspace-hint ":" "command")
                 (%workspace-hint (format nil "~A w" (%workspace-prefix-label prefix-code))
                                  "status")
                 (%workspace-hint (format nil "~A d" (%workspace-prefix-label prefix-code))
                                  "detach")))))

;;; ── Initial-scan placeholder (R6.2) ─────────────────────────────────────────

(defun %render-workspace-scanning-frame (terminal-rows terminal-cols &key scan-progress)
  "Render the complete frame shown while the workspace catalog is scanning."
  (let* ((rows (max 1 terminal-rows))
         (cols (max 1 terminal-cols))
         (stream (make-string-output-stream))
         (message (if (and (integerp scan-progress) (plusp scan-progress))
                      (format nil "scanning workspaces... ~D repositories" scan-progress)
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
  "Render centered guidance when the catalog is empty and scanning is done."
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
                                            collapsed-node-ids
                                            expanded-node-ids
                                            refreshing-ids
                                            stale-ids
                                            file-diffs
                                            (scanning-p nil)
                                            (scan-progress nil)
                                            (catalog-empty-hint nil)
                                            (command-buffer "")
                                            (tree-filter nil)
                                            (precomputed-tree-entries nil))
  "Render the bare-repository/worktree overview used by an attached client:
   a header, the tree (its only panel now -- PR2's one-column redesign), a
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
   MODE, server-multi-dispatch-command-input.lisp -- :TREE-FILTER is only
   the retired legacy command name that maps to it, server-multi-dispatch-
   command-workspace.lisp) additionally replaces the WHOLE key panel with
   the `/query` input prompt at the bottom row (see %RENDER-WORKSPACE-TREE-
   FILTER-LINE), the same way MODE = :COMMAND replaces it with the command
   line -- neither mode's ordinary key hints or divider draw at all while
   the prompt is active, matching the single-line footer's own pre-key-
   panel behaviour.
   PRECOMPUTED-TREE-ENTRIES, when non-NIL, is used verbatim instead of
   calling %WORKSPACE-FLAT-TREE-ENTRIES again -- RENDER-WORKSPACE-OVERVIEW-
   TO-TUI-STRING (renderer-tui-kit.lisp) flattens the tree once per frame
   and passes the result here, since this function used to redo that same
   walk of the org/repo/worktree/pane graph on every call regardless of
   whether the caller already had it. NIL still means \"not supplied\" (the
   default, and what a direct caller such as a test gets), so it falls back
   to computing it here exactly as before; the one frame where that is
   wrong -- FILTER narrows the tree to genuinely zero rows, which is also
   NIL -- just recomputes an already-empty result, which is cheap and not a
   correctness gap."
  (if (and scanning-p (null organizations))
      (%render-workspace-scanning-frame terminal-rows terminal-cols
                                        :scan-progress scan-progress)
      (let* ((rows (max 1 terminal-rows))
             (cols (max 1 terminal-cols))
             (stream (make-string-output-stream))
             (wide-enough-p (>= cols 9))
             ;; The fixed 6-row overhead (header + separator + 2-line detail
             ;; + message + footer) needs at least 7 rows before the tree
             ;; gets even a single row of its own; below that, the footer
             ;; row (FOOTER-ROW, always ROWS-1) lands on top of the detail
             ;; rows instead of below them, and some rows compute past the
             ;; terminal's actual height entirely.
             (tall-enough-p (>= rows 7))
             ;; The key panel (a divider + 2 content lines, replacing the old
             ;; single footer line) needs 2 more rows than that floor allows
             ;; for; below TERMINAL-ROWS = 12 it collapses back to the single
             ;; %WORKSPACE-FOOTER-LINE row instead (see WORKSPACE-TREE-VIEW-
             ;; ROWS, which reserves the matching 8 vs. 6 rows of overhead).
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
               (if render-tree-p
                   (loop for organization in organizations
                         sum (loop for repository in
                                   (organization-repositories organization)
                                   sum (length (repository-worktrees repository))))
                   (loop for organization in organizations
                         sum (organization-active-worktree-count organization)))))
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
             (field (key value)
               (format nil "~A ~A" (%sgr-wrap key +sgr-muted+) value))
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
               ;; Inline worktree expansion (Wave B): file rows colour their
               ;; 2-char status code (+SGR-ALERT+ for a "UU" conflict,
               ;; +SGR-WARN+ otherwise); commit rows colour their hash, or
               ;; the whole label faint/italic for the :PENDING/:FAILED
               ;; placeholder rows (HASH holds the state keyword there);
               ;; pane rows go +SGR-ALERT+ once their process has exited,
               ;; the same alert colour every other exited-pane marker in
               ;; this tree already uses (%WORKTREE-PANE-COUNT-TEXT's "!").
               (case kind
                 (:file
                  (let ((code (fourth object)) (path (third object)))
                    (format nil "~A ~A"
                            (%sgr-wrap code (if (string= code "UU")
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
                 ;; Wave C: a :FILE row's own inline-diff child rows, ALL
                 ;; carrying entry KIND = :DIFF-LINE -- including the
                 ;; truncation row, whose OBJECT head is :DIFF-MORE but
                 ;; whose KIND (dispatched on here) is still :DIFF-LINE, so
                 ;; a separate (:DIFF-MORE ...) case clause above this one
                 ;; was dead: KIND never takes that value. The check on
                 ;; (FIRST OBJECT) below makes that dispatch explicit rather
                 ;; than relying on the truncation label happening not to
                 ;; start with +/-/@@ and falling into the same plain-muted
                 ;; default by accident.
                 ;; The sentinel (:PENDING/:FAILED/:UNTRACKED) sits in a real
                 ;; line's OBJECT's INDEX slot (fourth object) exactly where
                 ;; its integer index would be -- same sentinel-in-place-of-
                 ;; data convention :COMMIT's HASH slot already uses above.
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
               (destructuring-bind (level label object kind) entry
                 (let* ((selected
                          ;; A :FILE/:COMMIT row's OBJECT is a fresh cons
                          ;; every flatten call (D3), so EQ never matches it
                          ;; against a SELECTED-OBJECT captured on an earlier
                          ;; frame -- fall back to EQUAL for that case only;
                          ;; every struct/keyword-backed kind keeps its
                          ;; original EQ behaviour unchanged.
                          (or (eq object selected-object)
                              (and (consp object) (consp selected-object)
                                   (equal object selected-object))))
                        (attention (%workspace-tree-node-attention-p object kind))
                        (indent (make-string (* 2 level) :initial-element #\Space))
                        (plain-prefix
                          (format nil "~A~:[ ~;>~]~:[ ~;!~] "
                                  indent selected attention))
                        (base-plain (format nil "~A~A" plain-prefix label))
                        (styled-prefix
                          (format nil "~A~A~A "
                                  indent
                                  (if selected (%sgr-wrap ">" +sgr-accent-bold+) " ")
                                  (if attention (%sgr-wrap "!" +sgr-alert+) " ")))
                        (base-styled
                          (format nil "~A~A" styled-prefix
                                  (cond
                                    ((eq kind :section) (%sgr-wrap label +sgr-section+))
                                    ((member kind '(:file :commit :pane :diff-line :diff-more))
                                     (detail-row-styled-label label object kind))
                                    (t label)))))
                   (if (eq kind :worktree)
                       (multiple-value-bind (plain styled)
                           (%worktree-tree-info-suffix
                            object (max 0 (- cols (%display-width base-plain) 2)))
                         (declare (ignore plain))
                         (if (plusp (length styled))
                             (format nil "~A  ~A" base-styled styled)
                             base-styled))
                       base-styled))))
             (detail-lines ()
               (cond
                 (selected-worktree
                  (list
                   (field "path:" (worktree-path selected-worktree))
                   (format nil "~A  ~A"
                           (field "head:" (or (worktree-head selected-worktree) "-"))
                           (%workspace-state-text selected-worktree))))
                 (selected-pane
                  (list
                   (field "pane:" (%pane-tree-label selected-pane))
                   (%sgr-wrap
                    (let ((output (pane-last-output selected-pane)))
                      (if (plusp (length output)) output "(no output)"))
                    +sgr-muted+)))
                 (selected-repository
                  (list
                   (field "repository:" (%repository-tree-label selected-repository))
                   (format nil "~A  ~A"
                           (state-field "state:" (repository-state selected-repository))
                           (field "worktrees:"
                                  (princ-to-string
                                   (length (repository-worktrees selected-repository)))))))
                 (selected-organization
                  (list
                   (field "organization:" (%organization-tree-label selected-organization))
                   (field "repositories:"
                          (princ-to-string
                           (length (organization-repositories selected-organization))))))
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
              ;; ALL-TREE-ENTRIES/TREE-COUNT are computed unconditionally
              ;; here now, not inside a (WHEN RENDER-TREE-P ...) guard: the
              ;; NO-MATCHES-P message below must appear even when
              ;; RENDER-TREE-P is NIL (the real client's tui-kit pass, which
              ;; leaves ordinary row *content* to the tree widget) --
              ;; otherwise a filter with zero matches produced a silent blank
              ;; tree area with no way to tell "broken" from "no matches"
              ;; apart from an empty catalog, which CATALOG-EMPTY-HINT does
              ;; not cover (it only fires when ORGANIZATIONS itself is
              ;; empty). The tree widget still recomputes its own copy
              ;; separately (renderer-tui-kit-widgets.lisp) -- see
              ;; RENDER-WORKSPACE-OVERVIEW-TO-TUI-STRING's own NO-MATCHES-P
              ;; check for why that is not wasted, either.
              (let* ((all-tree-entries
                       (or precomputed-tree-entries
                           (%workspace-flat-tree-entries
                            organizations collapsed-node-ids
                            :refreshing-ids refreshing-ids
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
                          ;; Clip-before-SGR (this file's ordering rule):
                          ;; %DISPLAY-CLIP never sees an escape, so it is
                          ;; wrapped in SGR only after clipping.
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
                           do (%emit-styled-row stream row 0 cols (tree-row-text entry))))))
                (%emit-styled-row
                 stream separator-row 0 cols
                 (%sgr-wrap (make-string cols :initial-element #\─) +sgr-line+))
                (let ((lines (detail-lines)))
                  (%emit-styled-row stream detail-row-1 0 cols (or (first lines) ""))
                  (%emit-styled-row stream detail-row-2 0 cols (or (second lines) "")))
                (when messages
                  (%emit-styled-row
                   stream message-row 0 cols
                   (%sgr-wrap (format nil "message: ~A" (first messages))
                              +sgr-muted-italic+))))
              (cell (min tree-top (max 0 (1- rows))) 0 cols
                    (cond
                      ((not (or wide-enough-p tall-enough-p))
                       "WORKSPACE OVERVIEW (terminal too small for panels)")
                      ((not wide-enough-p)
                       "WORKSPACE OVERVIEW (terminal too narrow for panels)")
                      (t "WORKSPACE OVERVIEW (terminal too short for panels)"))))
          ;; Reaching this branch already means (not (and scanning-p (null
          ;; organizations))) -- the IF above took its other arm otherwise --
          ;; so ORGANIZATIONS being null here already implies SCANNING-P is
          ;; false; no need to re-check it.
          (when (and (null organizations) catalog-empty-hint)
            (%render-workspace-empty-catalog-hint stream rows cols
                                                  catalog-empty-hint))
          (reset-attrs stream)
          ;; :COMMAND/:FILTER replace the WHOLE panel with the prompt at
          ;; FOOTER-ROW alone, exactly as they replaced the single-line
          ;; footer before the key panel existed -- "no ordinary key hints
          ;; while the user is actively typing" holds regardless of
          ;; KEY-PANEL-P, so the divider and first content line only draw in
          ;; the third, ordinary-navigation branch below.
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
