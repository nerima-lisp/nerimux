(in-package #:nerimux/renderer)

(defconstant +status-line-rows+
  1
  "Rows reserved at the bottom of the terminal for the status line.")

(defun %status-left-fields (focus-pane)
  "(VALUES ATTENTION REPOSITORY-TEXT WORKTREE-TEXT STATE-TEXT) for the status
   line's left block (R6.5). Each value is NIL when FOCUS-PANE (or its
   worktree/repository) is absent: an absent field is left out of the line
   entirely, where the em-dash placeholder it used to carry only spent a
   column saying nothing."
  (let* ((worktree (and focus-pane (pane-worktree focus-pane)))
         (repository (and worktree (worktree-repository worktree))))
    (values
     (when (and worktree (worktree-attention-p worktree)) "!")
     (when repository (%repository-title-text repository))
     (when worktree (%worktree-title-text worktree))
     (when worktree (%worktree-status-label worktree)))))

(defun %status-state-text (worktree)
  "WORKTREE's status tokens, each wrapped in its palette colour
   (%WORKTREE-STATE-TOKEN-SGR), or NIL when WORKTREE is absent.  Styled
   sibling of %WORKTREE-STATUS-LABEL, kept out of that shared helper because
   the workspace tree feeds the plain label through %DISPLAY-CLIP, which must
   never see escape sequences.  The pane line reads ahead/behind as arrows so
   they cannot be confused with the diff line counts beside them."
  (when worktree
    (format nil
            "~{~A~^ ~}"
            (mapcar
             (lambda (token)
               (let ((sgr (%worktree-state-token-sgr token)))
                 (if sgr
                     (%status-wrap token sgr)
                     token)))
             (%worktree-status-tokens worktree :ahead-behind :arrows)))))

(defun %status-left-text (focus-pane &key include-repository-p)
  "The left block's text, styled: attention mark in alert red, repository
   muted, worktree branch in bold lavender, state tokens palette-coloured,
   composed as `org/repo · branch STATE`.
   INCLUDE-REPOSITORY-P T includes the repository field; NIL omits it, the
   first thing %COMPOSE-WORKSPACE-STATUS-LINE drops when the line does not
   fit (R6.5: notification, then tabs, then repository name; branch and
   state token are never dropped)."
  (multiple-value-bind (attention repository worktree state)
      (%status-left-fields focus-pane)
    (declare (ignore state))
    (let ((fields
           (remove nil
                   (list
                    (when attention (%status-wrap "!" +sgr-alert+))
                    (when (and include-repository-p repository)
                      (format nil "~A ·" (%status-wrap repository +sgr-muted+)))
                    (when worktree (%status-wrap worktree +sgr-branch+))
                    (%status-state-text (and focus-pane
                                             (pane-worktree focus-pane)))))))
      (when fields (format nil "~{~A~^ ~}" fields)))))

(defun %status-pane-tab-token (pane focus-pane)
  "PANE's status-bar tab token, including its own leading space: the pane
   number, `*` when PANE has the focus, then `!` when it has unread output
   (R6.7), so the strip reads `pane 1 2* 3!`.  The unread mark used to stand
   in for the separator itself, which glued the numbers together -- restore a
   window of three panes and `pane!1!2!3` reads as a corrupted string, not as
   three panes with unread output.  The visible text is unchanged by the
   theme; the unread mark renders amber and the focused pane's `N*` renders
   bold accent."
  (format nil
          " ~A~@[~A~]"
          (if (eq pane focus-pane)
              (%status-wrap (format nil "~D*" (pane-id pane))
                            +sgr-accent-bold+)
              (format nil "~D" (pane-id pane)))
          (when (pane-unread-output-p pane)
            (%status-wrap "!" +sgr-warn+))))

(defun %status-window-panes (window)
  "Every pane of WINDOW, including the ones zoom hid: WINDOW-ZOOM-TOGGLE swaps
   the split tree for a single leaf, so WINDOW-PANES answers one pane while
   zoomed and the strip would read as if the others had been closed."
  (if (and (window-zoom-p window) (window-zoom-tree window))
      (layout-leaves (window-zoom-tree window))
      (window-panes window)))

(defun %status-window-tab (window focus-pane)
  "WINDOW's locator: `win 1 · pane 1 2* 3!`, plus a zoom marker when the
   window is zoomed."
  (format nil
          "~A ·~{~A~}~@[ ~A~]"
          (%status-wrap (format nil "win ~D" (window-id window)) +sgr-muted+)
          (cons (%status-wrap " pane" +sgr-muted+)
                (mapcar
                 (lambda (pane)
                   (%status-pane-tab-token pane focus-pane))
                 (%status-window-panes window)))
          (when (window-zoom-p window)
            (%status-wrap "[zoom]" +sgr-warn+))))

(defun %status-middle-text (focus-pane)
  "The middle block: FOCUS-PANE's worktree's window/pane locators, or NIL when
   there is nothing to locate -- a single unzoomed pane in a single window is
   where the user already is, so naming it is noise."
  (let* ((worktree (and focus-pane (pane-worktree focus-pane)))
         (windows (and worktree (%worktree-tree-windows worktree))))
    (when (and windows
               (or (rest windows)
                   (rest (%status-window-panes (first windows)))
                   (window-zoom-p (first windows))))
      (format nil
              "~{~A~^  ~}"
              (mapcar
               (lambda (window)
                 (%status-window-tab window focus-pane))
               windows)))))

(defparameter +status-key-hints+
  "C-q ? keys  C-q w repolist  C-q d detach"
  "The pane view's only key panel: a focused pane forwards every byte to the
   shell, so without this the prefix itself is invisible to a new user.")

(defun %status-right-text (messages)
  "The right block: the single most recent notification, or the key hints when
   there is none. MESSAGES is CLIENT-CONN-MESSAGE-LOG (most-recent-first,
   %CLIENT-NOTIFY conses onto its front), the 64-entry cap stays on the
   conn's log (R6.5: \"display only, not retention, changes\"); this only
   ever reads the first entry."
  (if messages
      (%status-wrap (first messages) +sgr-muted-italic+)
      (%status-wrap +status-key-hints+ +sgr-muted+)))

(defun %status-mode-chip (mode)
  "The status line's leftmost, always-kept segment (FR-003): a bold MODE-name
   chip naming whatever has taken the keyboard away from the shell. Returns
   NIL -- not an empty string -- when MODE is NIL: %RENDER-PANE-FRAME
   (server-multi-render.lisp) passes CLIENT-CONN-MODAL straight through, and
   NIL is the ordinary case since FR-007 gave a pane with no modal the
   keyboard directly, with nothing for the chip to report.
   %COMPOSE-WORKSPACE-STATUS-LINE's own (REMOVE NIL ...) then drops a NIL
   chip from the assembled line with no separator artifact, the same
   mechanism already used to drop the middle/right blocks when width
   excludes them. Every non-NIL MODE (:view-pane, :scrollback, :command,
   :filter, :picker, :transient, ...) shows the chip alone, the mode name
   already being the whole message.
   Styled with %STATUS-WRAP (not %SGR-WRAP) so it restores the status bar's
   own base style rather than a plain reset; +sgr-mode-chip+
   (renderer-style.lisp) is the same chip the workspace footer uses
   (%workspace-footer-line, renderer-workspace.lisp).
   :NORMAL reports nothing for the same reason NIL does: the :normal/:input
   vocabulary is retired, and a caller that still defaults to it is naming a
   mode the user can no longer be in."
  (when (and mode (not (eq mode :normal)))
    (%status-wrap (format nil " ~:@(~A~) " mode) +sgr-mode-chip+)))

(defparameter +status-message-columns-floor+
  16
  "Columns a notification needs before eliding it beats dropping it: below
   this the ellipsis and the fragment behind it name nothing to act on.")

(defun %compose-workspace-status-line (focus-pane messages
                                                  cols
                                                  &key
                                                  (mode nil))
  "Assemble the R6.5 status line, dropping blocks right-to-left when COLS is
   too narrow: a notification too long for the room left over is first
   elided from the front (%MESSAGE-STRIP-TEXT) and only dropped when even
   +STATUS-MESSAGE-COLUMNS-FLOOR+ columns are unavailable, since a pane
   forwards every key to the shell and the strip is the only place an action
   it refused can report itself. Then the window/pane tabs, then the
   repository name, branch and state token are never dropped (design doc
   §11). The MODE chip (FR-003, %STATUS-MODE-CHIP) is placed ahead of all
   three and is never dropped by width degradation: it is a safety feature
   (whether a keystroke reaches the shell), not a display convenience, so it
   must survive as far into a narrow terminal as the fields design doc §11
   already protects. Being first also means the final %VISIBLE-TRUNCATE
   safety net below the terminal's 40-column floor (R6.10 already refuses
   anything narrower) keeps it, since that truncation keeps a string's
   prefix. Separately from width, MODE-CHIP itself is NIL when MODE is NIL
   (%STATUS-MODE-CHIP), and the REMOVE NIL below drops a NIL entry from the
   assembled list with no gap -- that is MODE having nothing to report, not
   a degradation step, so it happens identically at every COLS width."
  (let ((middle (%status-middle-text focus-pane))
        (mode-chip (%status-mode-chip mode)))
    (labels ((assemble (include-repository-p include-middle-p right)
               (format nil
                       "~{~A~^  ~}"
                       (remove nil
                               (list mode-chip
                                     (%status-left-text focus-pane
                                                        :include-repository-p
                                                        include-repository-p)
                                     (and include-middle-p middle)
                                     right)))))
      (let* ((right (%status-right-text messages))
             (full (assemble t t right))
             (no-notification (assemble t t nil))
             (room (- cols (%visible-length no-notification) 2)))
        (cond
          ((<= (%visible-length full) cols) full)
          ((and messages (>= room +status-message-columns-floor+))
           (assemble t
                     t
                     (%status-right-text
                      (list (%message-strip-text (first messages) room)))))
          ((<= (%visible-length no-notification) cols) no-notification)
          (t
           (let ((no-tabs (assemble t nil nil)))
             (if (<= (%visible-length no-tabs) cols)
                 no-tabs
                 (%visible-truncate (assemble nil nil nil) cols)))))))))

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

(defun render-status-bar (stream session
                                 terminal-rows
                                 terminal-cols
                                 &key
                                 (status-row
                                  (- terminal-rows +status-line-rows+))
                                 (focus-pane (session-active-pane session))
                                 (messages nil)
                                 (mode nil))
  "Draw the R6.5 status line at STATUS-ROW (defaults to the bottom row,
   §1.4/R2.2).
   FOCUS-PANE/MESSAGES default from SESSION / empty for a caller that has not
   been updated to pass the attached client's own focus pane and
   notification log; SESSION-ACTIVE-PANE is the correct answer whenever a
   client's focus tracks the session's active pane, which is the common
   case, so this degrades gracefully rather than going blank.
   MODE (FR-003) feeds the mode chip (%STATUS-MODE-CHIP) that
   %COMPOSE-WORKSPACE-STATUS-LINE draws first."
  (%render-status-line stream
                       status-row
                       +sgr-default-status+
                       (%compose-workspace-status-line focus-pane
                                                       messages
                                                       terminal-cols
                                                       :mode
                                                       mode)
                       terminal-cols))
