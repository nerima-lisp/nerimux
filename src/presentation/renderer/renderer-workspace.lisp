(in-package #:nerimux/renderer)

;;;; Workspace-view rendering: the organization -> repository -> worktree ->
;;;; window -> pane tree, drawn as plain ANSI into a string.
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
;;;; terminal panes.  Split out, the workspace render path depends on exactly
;;;; renderer-format.lisp (generic ANSI primitives) and renderer-tui-kit.lisp,
;;;; and on none of the pane renderer.  The aggregate attention view that used
;;;; to live here (render-workspace-attention-to-string) is gone -- workspace
;;;; contraction phase 3, R1.7 -- but the attention MODEL it read from
;;;; (worktree-attention-p / worktree-attention-reasons /
;;;; organization-attention-count / organization-attention-worktrees) is
;;;; still live: it drives the `!` marks in the tree below.
;;;;
;;;; Load order (declared in nerimux.asd): renderer-format -> renderer-workspace,
;;;; ahead of the pane-compositor chain, so the load order states that dependency.

(defun %workspace-prefix-label (code)
  (if (and (integerp code) (<= 1 code) (<= code 26))
      (format nil "C-~A" (code-char (+ (char-code #\a) (1- code))))
      (format nil "key/~D" code)))

;;; ── Worktree status tokens (R6.1) ──────────────────────────────────────────
;;;
;;; Shared by the tree label here and by %WORKSPACE-TREE-NODE-KEY /
;;; %WORKSPACE-FLAT-TREE-ENTRIES below (and, through those, by
;;; renderer-tui-kit.lisp, which loads after this file), so every drawer of
;;; the tree uses the same token set instead of two conds drifting apart.
;;;
;;; WORKTREE-STATUS (the NERIMUX/MODEL slot reader -- not to be confused with
;;; the same-named refresh function in NERIMUX/VCS, which sets it) is NIL
;;; until the first successful VCS-STATUS-STRUCTURED call and is reset to NIL
;;; whenever the worktree's path goes missing (vcs.lisp:319). That makes it
;;; the one slot that distinguishes "never fetched" / "known missing" from
;;; "fetched and clean": DIRTY-P, CONFLICT-P, AHEAD and BEHIND all default to
;;; false/0, the same values a genuinely clean worktree has, so none of them
;;; alone can tell UNKNOWN apart from CLEAN. MISSING-P / BARE-P / LOCKED-P /
;;; PRUNABLE-P come from `git worktree list --porcelain`, a different source
;;; from status, so they are reported regardless of whether status has ever
;;; been fetched.
(defun %worktree-status-tokens (worktree)
  "Return WORKTREE's state as a list of token strings, per the design
   document's status-token contract (docs/notes/workspace-ui-ux-design.md
   §6.1/§6.2): MISSING / BARE / LOCKED / PRUNABLE / DIRTY / CONFLICT /
   AHEAD n / BEHIND n, in that order, all that apply. AHEAD/BEHIND keep
   their counts rather than collapsing to a boolean. No applicable token and
   a fetched status yields (\"CLEAN\"); a status never fetched yields
   (\"UNKNOWN\") appended after any structural tokens, instead of assuming
   CLEAN."
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
  "WORKTREE's status tokens (%WORKTREE-STATUS-TOKENS) joined for display."
  (format nil "~{~A~^ ~}" (%worktree-status-tokens worktree)))

(defun %repository-attention-p (repository)
  "T when REPOSITORY itself, or any worktree under it, needs attention.
   Hoisted to top level (out of RENDER-WORKSPACE-OVERVIEW-TO-STRING's own
   LABELS block) so %WORKSPACE-TREE-NODE-ATTENTION-P below can share it with
   the tui-kit tree widget instead of the two computing it independently."
  (or (repository-dirty-p repository)
      (repository-conflict-p repository)
      (plusp (repository-ahead repository))
      (plusp (repository-behind repository))
      (repository-missing-p repository)
      (some #'worktree-attention-p (repository-worktrees repository))))

;;; ── Tree node identity, labels, and 5-level flattening (R6.3) ──────────────
;;;
;;; The tree widget in renderer-tui-kit.lisp (loads after this file) and the
;;; plain-ANSI path below both walk the same org -> repository -> worktree ->
;;; window -> pane tree, so the traversal, node keys, and per-kind labels
;;; live here once instead of as two copies that drift -- the same reasoning
;;; that already put %worktree-status-tokens here for the same two callers.
;;;
;;; %WORKTREE-TREE-WINDOWS duplicates workspace-window.lisp's
;;; %WORKTREE-WINDOWS (bootstrap layer, package NERIMUX) instead of calling
;;; it: NERIMUX/RENDERER is a lower layer than NERIMUX, and reaching up would
;;; be exactly the kind of violation R9.1 added `::`-reference detection for.
;;; Three lines of duplicated sort/remove-duplicates here is cheaper than an
;;; upward package reference.

(defun %worktree-tree-windows (worktree)
  "Distinct windows holding at least one of WORKTREE's panes, ordered by
   window id -- the order the tree and status line show them in (R5.8)."
  (sort (remove-duplicates (mapcar #'pane-window (worktree-panes worktree))
                           :test #'eq)
        #'< :key #'window-id))

(defun %workspace-em-dash ()
  "The single-character placeholder for an unselected value (design doc
   §2/§3.3): never carry the previous frame's selection forward silently --
   show this instead."
  (string (code-char #x2014)))

(defun %workspace-tree-node-key (node)
  "Stable, EQUAL-comparable identity for a tree row, across all 5 levels
   (R6.3). Used both for tree-widget selection and, at the organization and
   repository levels, as the collapse-state table's key."
  (typecase node
    (organization (list :organization (organization-id node)))
    (repository (list :repository (repository-id node)))
    (worktree (list :worktree (worktree-id node)))
    (window (list :window (window-id node)))
    (pane (list :pane (window-id (pane-window node)) (pane-id node)))
    (t (list :workspace-object node))))

(defun %workspace-node-expanded-p (kind id expanded-node-ids)
  "T when the (KIND ID) organization/repository row is expanded in
   EXPANDED-NODE-IDS (a hash-table of tree-node keys -> T, or NIL). Absent
   means collapsed -- the tree's default state (R6.3: only organization rows
   show at first). Worktree/window/pane rows have no collapse state of their
   own; once their repository ancestor is expanded, all of them show."
  (and expanded-node-ids (gethash (list kind id) expanded-node-ids)))

(defun %organization-tree-label (organization)
  (let ((host (organization-host organization))
        (name (organization-name organization)))
    (cond
      ((and (plusp (length host)) (plusp (length name)))
       (format nil "~A/~A" host name))
      ((plusp (length host)) host)
      ((plusp (length name)) name)
      (t (organization-id organization)))))

(defun %repository-tree-label (repository)
  (or (and (plusp (length (repository-specification repository)))
           (repository-specification repository))
      (and (plusp (length (repository-local-path repository)))
           (repository-local-path repository))
      (repository-id repository)))

(defun %worktree-tree-label (worktree)
  (or (and (worktree-branch worktree)
           (plusp (length (worktree-branch worktree)))
           (worktree-branch worktree))
      (and (plusp (length (worktree-path worktree)))
           (worktree-path worktree))
      (worktree-id worktree)))

(defun %window-tree-label (window)
  "WINDOW's tree-row label: id + name. NAME is already branch + sequence
   number (R5.8, computed once at window-creation time in
   workspace-window.lisp) -- this only formats it, it does not recompute it."
  (format nil "win ~D:~A" (window-id window) (window-name window)))

(defun %pane-tree-label (pane)
  (format nil "pane/~D ~A"
          (pane-id pane)
          (or (and (plusp (length (pane-title pane))) (pane-title pane))
              (and (plusp (length (pane-start-command pane)))
                   (pane-start-command pane))
              "shell")))

(defun %workspace-tree-node-attention-p (object kind)
  "T when OBJECT (a KIND tree node) should carry the `!` attention mark.
   Window rows never do -- attention is a VCS (org/repo/worktree) or pane
   concept, not a window one; a window's own panes already carry it."
  (case kind
    (:organization (or (plusp (organization-attention-count object))
                        (organization-attention-worktrees object)))
    (:repository (%repository-attention-p object))
    (:worktree (worktree-attention-p object))
    (:pane (pane-attention-p object))
    (t nil)))

(defun %workspace-node-refresh-tag (kind id refreshing-ids stale-ids)
  "\" refreshing\"/\" stale\"/\"\" suffix for an organization/repository/worktree
   row (R6.2). REFRESHING-IDS wins over STALE-IDS when a node is somehow in
   both (a fresh refresh started before the previous failure was ever
   redrawn) -- refreshing is the more current fact. Both default to NIL
   (nothing refreshing, nothing stale), which is the correct empty state
   until the caller that starts/settles a refresh populates them -- see the
   R6 report for exactly where that caller must call the mark/clear
   functions in server-multi.lisp."
  (let ((key (list kind id)))
    (cond
      ((and refreshing-ids (gethash key refreshing-ids)) " refreshing")
      ((and stale-ids (gethash key stale-ids)) " stale")
      (t ""))))

(defun workspace-tree-objects (organizations expanded-node-ids)
  "The objects the tree currently shows, in display order (R6.3).

   Key navigation and rendering must agree on this list or they cannot agree on
   anything: the selection is an index into the visible rows, so a caller that
   enumerates rows the frame does not draw moves the cursor onto rows nobody can
   see. Both sides read it from %WORKSPACE-FLAT-TREE-ENTRIES for that reason —
   the collapse rule lives in one function, not two."
  (mapcar #'third (%workspace-flat-tree-entries organizations expanded-node-ids)))

(defun %workspace-flat-tree-entries
    (organizations expanded-node-ids &key refreshing-ids stale-ids)
  "Flatten ORGANIZATIONS into the org -> repository -> worktree -> window ->
   pane tree (R6.3) as a list of (LEVEL LABEL OBJECT KIND) tuples in display
   order. A repository's worktrees (and a worktree's windows and panes) show
   only once both its organization and repository ancestors are expanded in
   EXPANDED-NODE-IDS -- worktree/window/pane rows carry no independent
   collapse state (only the organization and repository levels toggle via
   Enter, R6.3). REFRESHING-IDS / STALE-IDS (R6.2) append a tag to
   organization/repository/worktree labels; window/pane rows never carry one
   (a VCS refresh has no notion of a window or pane)."
  (let (entries)
    (dolist (organization organizations)
      (push (list 0
                  (concatenate
                   'string (%organization-tree-label organization)
                   (%workspace-node-refresh-tag
                    :organization (organization-id organization)
                    refreshing-ids stale-ids))
                  organization :organization)
            entries)
      (when (%workspace-node-expanded-p
             :organization (organization-id organization) expanded-node-ids)
        (dolist (repository (organization-repositories organization))
          (push (list 1
                      (concatenate
                       'string (%repository-tree-label repository)
                       (%workspace-node-refresh-tag
                        :repository (repository-id repository)
                        refreshing-ids stale-ids))
                      repository :repository)
                entries)
          (when (%workspace-node-expanded-p
                 :repository (repository-id repository) expanded-node-ids)
            (dolist (worktree (repository-worktrees repository))
              (push (list 2
                          (concatenate
                           'string (%worktree-tree-label worktree)
                           (%workspace-node-refresh-tag
                            :worktree (worktree-id worktree)
                            refreshing-ids stale-ids))
                          worktree :worktree)
                    entries)
              (dolist (window (%worktree-tree-windows worktree))
                (push (list 3 (%window-tree-label window) window :window) entries)
                (dolist (pane (window-panes window))
                  (push (list 4 (%pane-tree-label pane) pane :pane) entries))))))))
    (nreverse entries)))

;;; ── `:` command-line completion (R6.12) ────────────────────────────────────
;;;
;;; §11's "every action reaches keymap AND action menu" is rewritten by R6.12:
;;; no action menu is built; the `:` command line is the alternate route, and
;;; this is its only affordance beyond plain text entry -- a list of matching
;;; command names shown right after the colon.

(defparameter +workspace-command-names+
  '("wt-create" "wt-delete" "wt-lock" "wt-unlock" "wt-prune" "wt-prune-confirm"
    "overview" "detail" "refresh")
  "Command names the `:` prompt completes against (R6.12): the wt-* family
   plus the other names already surfaced in the overview footer's help text
   below. A presentation-layer literal rather than an import from
   server-multi-dispatch.lisp's command table, for the same upward-layering
   reason %WORKTREE-TREE-WINDOWS above is a local duplicate rather than a
   call across packages -- keep in sync with that table by hand if it grows.")

(defun %workspace-command-completions (command-buffer)
  "Command names from +WORKSPACE-COMMAND-NAMES+ whose prefix matches the
   first whitespace-delimited token of COMMAND-BUFFER (R6.12). Returns every
   name when that token is empty (right after typing `:`), and NIL once a
   space has been typed (the user is now typing an argument, not a command
   name, so completion has nothing useful to add)."
  (let* ((trimmed (string-left-trim " " command-buffer))
         (space (position #\Space trimmed)))
    (if space
        nil
        (remove-if-not
         (lambda (name)
           (and (<= (length trimmed) (length name))
                (string= trimmed name :end2 (length trimmed))))
         +workspace-command-names+))))

(defun %render-workspace-command-line (stream row cols command-buffer)
  "Draw the `:` command line with its completion candidates (R6.12) at ROW,
   overwriting whatever the footer would otherwise show there -- mirrors how
   renderer-compose.lisp's %RENDER-CLIENT-COMMAND-LINE overwrites the pane
   view's status-bar row for the same mode.
   TYPED (the colon and what the user has entered so far) is never
   truncated; only the completion-candidate suffix is clipped to whatever
   width remains, via %DISPLAY-CLIP (front-truncate would risk eating into
   TYPED itself, which %DISPLAY-CLIP-TAIL is built for and this is not — the
   part that must stay visible here is the head, not a live cursor tail)."
  (let* ((typed (format nil ":~A" command-buffer))
         (typed-width (%display-width typed))
         (completions (%workspace-command-completions command-buffer)))
    (if (>= typed-width cols)
        ;; TYPED alone already fills or overflows the row: fall back to
        ;; keeping its tail (where the cursor lives) visible, same as
        ;; renderer-compose.lisp's plain command line, and drop the
        ;; completions entirely rather than let them push the cursor off.
        (let ((visible (%display-clip-tail typed cols)))
          (move-to stream row 0)
          (write-string visible stream)
          (reset-attrs stream))
        (let* ((remaining (- cols typed-width))
               (suffix (if completions
                           (%display-clip (format nil "  ~{~A~^ ~}" completions) remaining)
                           ""))
               (text (concatenate 'string typed suffix))
               (width (%display-width text)))
          (move-to stream row 0)
          (write-string text stream)
          (when (< width cols)
            (write-string (make-string (- cols width) :initial-element #\Space) stream))
          (reset-attrs stream)))))

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

;;; ── Client-terminal title (R6.11) ───────────────────────────────────────────
;;;
;;; "nerimux: <repository> — <worktree>", "-" standing in for either half
;;; when nothing is selected/attached. Shared by both views (pane-frame
;;; title emission lives in renderer-compose.lisp; the workspace-overview
;;; call site is below) so the label fallbacks -- specification/local-path/id
;;; for a repository, branch/path/id for a worktree -- read identically to
;;; the tree labels elsewhere in this file, without being the same LABELS
;;; closures (those close over STREAM and are not reachable from outside
;;; RENDER-WORKSPACE-OVERVIEW-TO-STRING).

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
           (or (and (worktree-branch worktree)
                    (plusp (length (worktree-branch worktree)))
                    (worktree-branch worktree))
               (and (plusp (length (worktree-path worktree)))
                    (worktree-path worktree))
               (worktree-id worktree)))
      "-"))

(defun %client-title-osc (repository worktree)
  "OSC 0 escape setting the outer client terminal's title."
  (format nil "~C]0;nerimux: ~A ~A ~A~C"
          +esc+ (%repository-title-text repository) (code-char #x2014)
          (%worktree-title-text worktree) (code-char 7)))

(defun %workspace-title-selection (focus-pane selected-tree-object selected-worktree)
  "Resolve the (VALUES REPOSITORY WORKTREE) a workspace-overview frame's
   title should show, mirroring the SELECTED-OBJECT resolution inside
   RENDER-WORKSPACE-OVERVIEW-TO-STRING -- duplicated rather than shared
   because that resolution lives inside that function's own LET* and closes
   over locals (SELECTED-REPOSITORY, SELECTED-WORKTREE) not visible outside
   it; RENDER-WORKSPACE-OVERVIEW-TO-TUI-STRING needs the same answer at
   its own call boundary, after the ansi-frame/tui-kit round-trip that
   discards any title OSC embedded in the frame text (see
   %RENDER-ANSI-FRAME-WITH-TUI-KIT's OSC-skipping frame-grid parser)."
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
                             (format nil "status: ~A"
                                     (or (and (worktree-status selected-worktree)
                                              (princ-to-string
                                               (worktree-status selected-worktree)))
                                         "-"))
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
