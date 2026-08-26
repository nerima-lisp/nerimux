(in-package #:nerimux/renderer)

;;;; Status bar composition for the nerimux renderer.
;;;;
;;;; This file owns the status bar: format composition and the
;;;; render-status-bar entry point.  It has no knowledge of session-frame
;;;; compositing; that lives in renderer-compose.lisp.
;;;;
;;;; R6.5 replaced the previous status bar (session name, whole-session
;;;; window list, clock) with the workspace-scoped contract: attention mark +
;;;; repository + worktree + state token on the left, the CURRENT worktree's
;;;; window/pane tabs in the middle (not every window in the session — a
;;;; worktree's own windows, %WORKTREE-TREE-WINDOWS,
;;;; renderer-workspace-tree.lisp),
;;;; and the latest client notification on the right.  No clock (§1.4/R6.5).
;;;; The old per-option R2.2/R2.3 "fixed at its registered default" comments
;;;; this file used to carry no longer apply to any of the content below —
;;;; there is no more session/window-list template to have fixed.
;;;;
;;;; Load order (declared in nerimux.asd): renderer-format → renderer-style
;;;;             → renderer-statusbar-layout → renderer-pane
;;;;             → renderer-statusbar → renderer-compose

;;; The status line is one row at the bottom, always (requirements §1.4).
;;; nerimux/options:status-line-count and +max-status-lines+ (the "status"
;;; option could pick 0..5 rows) are gone with domain/options (R2.2) — this
;;; is the one place that concept survives, as a fixed constant instead of a
;;; cross-package function call, so anything outside nerimux/renderer that
;;; still needs to reserve rows for the status line (e.g. pane-area layout)
;;; has exactly one definition to reference rather than each side keeping
;;; its own copy of "1".

(defconstant +status-line-rows+ 1
  "Rows reserved at the bottom of the terminal for the status line.")

;;; ── Left block: attention + repository + worktree + state token ───────────

(defun %status-left-fields (focus-pane)
  "(VALUES ATTENTION REPOSITORY-TEXT WORKTREE-TEXT STATE-TEXT) for the status
   line's left block (R6.5). Each of REPOSITORY-TEXT/WORKTREE-TEXT/STATE-TEXT
   is %WORKSPACE-EM-DASH when FOCUS-PANE (or its worktree/repository) is
   absent — design doc §2/§3.3: an unselected value must show as such, never
   silently carry the previous frame's text forward."
  (let* ((worktree (and focus-pane (pane-worktree focus-pane)))
         (repository (and worktree (worktree-repository worktree))))
    (values (if (and worktree (worktree-attention-p worktree)) "!" " ")
            (if repository (%repository-title-text repository) (%workspace-em-dash))
            (if worktree (%worktree-title-text worktree) (%workspace-em-dash))
            (if worktree (%worktree-status-label worktree) (%workspace-em-dash)))))

(defun %status-state-text (worktree)
  "WORKTREE's status tokens, each wrapped in its palette colour
   (%WORKTREE-STATE-TOKEN-SGR), or the em-dash placeholder when WORKTREE is
   absent.  Styled sibling of %WORKTREE-STATUS-LABEL, kept out of that shared
   helper because the workspace tree feeds the plain label through
   %DISPLAY-CLIP, which must never see escape sequences."
  (if worktree
      (format nil "~{~A~^ ~}"
              (mapcar (lambda (token)
                        (let ((sgr (%worktree-state-token-sgr token)))
                          (if sgr (%status-wrap token sgr) token)))
                      (%worktree-status-tokens worktree)))
      (%workspace-em-dash)))

(defun %status-left-text (focus-pane &key include-repository-p)
  "The left block's text, styled: attention mark in alert red, repository
   muted, worktree branch in bold lavender, state tokens palette-coloured.
   INCLUDE-REPOSITORY-P T includes the repository field; NIL omits it — the
   first thing %COMPOSE-WORKSPACE-STATUS-LINE drops when the line does not
   fit (R6.5: notification, then tabs, then repository name; branch and
   state token are never dropped)."
  (multiple-value-bind (attention repository worktree state)
      (%status-left-fields focus-pane)
    (declare (ignore state))
    (let* ((source-worktree (and focus-pane (pane-worktree focus-pane)))
           (attention-styled (if (string= attention "!")
                                 (%status-wrap "!" +sgr-alert+)
                                 attention))
           (repository-styled (%status-wrap repository +sgr-muted+))
           (worktree-styled (%status-wrap worktree +sgr-branch+))
           (state-styled (%status-state-text source-worktree)))
      (if include-repository-p
          (format nil "~A ~A ~A ~A"
                  attention-styled repository-styled worktree-styled state-styled)
          (format nil "~A ~A ~A" attention-styled worktree-styled state-styled)))))

;;; ── Middle block: the current worktree's window/pane tabs (R6.5/R6.7) ─────

(defun %status-pane-tab-token (pane focus-pane)
  "PANE's status-bar tab token, including its own leading separator: a space
   normally, or `!` in its place when PANE has unread output (R6.7) — the
   marker doubles as the separator, matching the format the requirements
   give ([w1: 1 2*!3]: pane 3's `!` sits where the usual space would, with no
   extra glue needed between it and the previous pane's tab).  The visible
   text is unchanged by the theme; the unread mark renders amber and the
   focused pane's `N*` renders bold accent."
  (let ((separator (if (pane-unread-output-p pane)
                       (%status-wrap "!" +sgr-warn+)
                       " ")))
    (if (eq pane focus-pane)
        (format nil "~A~A" separator
                (%status-wrap (format nil "~D*" (pane-id pane)) +sgr-accent-bold+))
        (format nil "~A~D" separator (pane-id pane)))))

(defun %status-window-tab (window focus-pane)
  (format nil "~A~{~A~}~A"
          (%status-wrap (format nil "[w~D:" (window-id window)) +sgr-muted+)
          (mapcar (lambda (pane) (%status-pane-tab-token pane focus-pane))
                  (window-panes window))
          (%status-wrap "]" +sgr-muted+)))

(defun %status-window-pane-tabs (focus-pane)
  "The middle block: FOCUS-PANE's worktree's window/pane tabs
   ([w1: 1 2*][w2: 1], R6.5), or NIL when there is no worktree or it has no
   open windows — the caller shows %WORKSPACE-EM-DASH for NIL."
  (let* ((worktree (and focus-pane (pane-worktree focus-pane)))
         (windows (and worktree (%worktree-tree-windows worktree))))
    (when windows
      (format nil "~{~A~}"
              (mapcar (lambda (window) (%status-window-tab window focus-pane))
                      windows)))))

(defun %status-middle-text (focus-pane)
  (or (%status-window-pane-tabs focus-pane) (%workspace-em-dash)))

;;; ── Right block: latest notification (R6.5) ────────────────────────────────

(defun %status-right-text (messages)
  "The right block: the single most recent notification, or an em-dash when
   there is none yet. MESSAGES is CLIENT-CONN-MESSAGE-LOG (most-recent-first,
   %CLIENT-NOTIFY conses onto its front) — the 64-entry cap stays on the
   conn's log (R6.5: \"display only, not retention, changes\"); this only
   ever reads the first entry."
  (if messages
      (%status-wrap (first messages) +sgr-muted-italic+)
      (%workspace-em-dash)))

;;; ── Composition with width-driven degradation (R6.5) ───────────────────────

(defun %compose-workspace-status-line (focus-pane messages cols)
  "Assemble the R6.5 status line, dropping blocks right-to-left when COLS is
   too narrow: the notification first, then the window/pane tabs, then the
   repository name — branch and state token are never dropped (design doc
   §11). A final %VISIBLE-TRUNCATE is the safety net below the terminal's
   40-column floor (R6.10 already refuses anything narrower)."
  (let ((middle (%status-middle-text focus-pane))
        (right (%status-right-text messages)))
    (labels ((assemble (include-repository-p include-middle-p include-right-p)
               (format nil "~{~A~^  ~}"
                       (remove nil
                               (list (%status-left-text
                                      focus-pane
                                      :include-repository-p include-repository-p)
                                     (and include-middle-p middle)
                                     (and include-right-p right))))))
      (let ((full (assemble t t t)))
        (if (<= (%visible-length full) cols)
            full
            (let ((no-notification (assemble t t nil)))
              (if (<= (%visible-length no-notification) cols)
                  no-notification
                  (let ((no-tabs (assemble t nil nil)))
                    (if (<= (%visible-length no-tabs) cols)
                        no-tabs
                        (%visible-truncate (assemble nil nil nil) cols))))))))))

(defun %render-status-line (stream status-row sgr-code line &optional cols)
  "Emit a fully-composed status LINE at STATUS-ROW, wrapped in SGR-CODE, then
   reset.  When COLS is given, pad the remainder of the row with spaces while
   SGR-CODE's background is still active, so the bar spans the full terminal
   width instead of stopping where the text ends."
  (move-to stream status-row 0)
  (%emit-sgr stream sgr-code)
  (write-string line stream)
  (when cols
    (let ((gap (- cols (%visible-length line))))
      (when (plusp gap)
        (%emit-sgr stream (concatenate 'string "0;" sgr-code))
        (write-string (make-string gap :initial-element #\Space) stream))))
  (reset-attrs stream))

(defun render-status-bar (stream session terminal-rows terminal-cols
                          &key (status-row (- terminal-rows +status-line-rows+))
                            (focus-pane (session-active-pane session))
                            (messages nil))
  "Draw the R6.5 status line at STATUS-ROW (defaults to the bottom row,
   §1.4/R2.2).
   FOCUS-PANE/MESSAGES default from SESSION / empty for a caller that has not
   been updated to pass the attached client's own focus pane and
   notification log (renderer-compose.lisp's render-session-to-string call
   site does not yet — see the R6 report for the small additive change that
   closes the gap); SESSION-ACTIVE-PANE is the correct answer whenever a
   client's focus tracks the session's active pane, which is the common
   case, so this degrades gracefully rather than going blank."
  (%render-status-line stream status-row +sgr-default-status+
                       (%compose-workspace-status-line focus-pane messages
                                                       terminal-cols)
                       terminal-cols))
