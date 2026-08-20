(in-package #:nerimux/renderer)

;;;; PANE-frame compositing for the nerimux renderer.
;;;;
;;;; This file owns the full-frame pipeline for the terminal-pane view:
;;;; lock-screen overlay, pane/border rendering, overlay dispatch, mouse
;;;; sequences, bell emission, cursor restoration, and the render-session /
;;;; render-session-to-string entry points.
;;;;
;;;; The workspace tree and attention views used to live here too.  They are the
;;;; other UI, they share none of the VT100 cell machinery below, and they now
;;;; live in renderer-workspace.lisp -- which loads far earlier, right after
;;;; renderer-format.lisp, because generic ANSI primitives are all they need.
;;;;
;;;; Status-bar composition lives in renderer-statusbar.lisp (loaded just before
;;;; this file).
;;;;
;;;; Load order (declared in nerimux.asd): renderer-format → renderer-style
;;;;             → renderer-pane → renderer-overlay → renderer-statusbar
;;;;             → renderer-compose-protocols → renderer-compose-overlay
;;;;             → renderer-compose-effects → renderer-compose

;;; ── Lock-screen overlay ─────────────────────────────────────────────────────

(defun render-lock-screen (stream terminal-rows terminal-cols)
  "Render a full-screen lock overlay.  Fills the screen with a solid colour
   and centres a 'Session locked' message."
  (reset-attrs stream)
  (%emit-sgr stream +sgr-default-status+)
  ;; Fill all rows with spaces.
  (let ((blank-row (make-string terminal-cols :initial-element #\Space)))
    (loop for row below (1- terminal-rows)
          do (move-to stream row 0)
             (write-string blank-row stream)))
  ;; Centre the lock message.
  (let* ((msg     "Session locked — press any key to unlock")
         (mlen    (min (length msg) terminal-cols))
         (mid-row (floor terminal-rows 2))
         (mid-col (%center-coord terminal-cols mlen)))
    (move-to stream mid-row mid-col)
    (write-string (subseq msg 0 mlen) stream))
  (reset-attrs stream))

(defun %render-panes-and-borders (buffer session window panes active-pane terminal-cols
                                  &key (viewport 0))
  "Render all panes and split-tree borders for WINDOW into BUFFER.
   Snapshots zoom state under the window lock to avoid a race with
   window-zoom-toggle running on the main thread."
  (let ((zoomed nil) (tree nil))
    (when window
      (with-lock-held ((window-lock window))
        (setf zoomed (window-zoom-p window)
              tree   (window-tree   window))))
          (dolist (pane panes)
            (render-pane buffer session pane
                         :viewport (if (eq pane active-pane) viewport 0)))
    (when (and tree (not zoomed))
      (render-tree-borders buffer tree active-pane terminal-cols))))

(defun %picker-item-display-text (item)
  (let ((prefix
          (case (nerimux/picker:picker-item-kind item)
            (:organization "org ")
            (:repository "repo")
            (:worktree "  wt ")
            (:pane "pane")
            (otherwise "     "))))
    (format nil "~A ~:[ ~;!~] ~A"
            prefix
            (nerimux/picker:picker-item-attention-p item)
            (nerimux/picker:picker-item-label item))))

(defun %write-picker-box-line (stream row col text inner-width &key selected attention)
  (move-to stream row col)
  (write-char #\| stream)
  (if selected
      (%emit-sgr stream 7)
      (when attention
        (%emit-sgr stream 33)))
  (let ((width (min inner-width (length text))))
    (write-string text stream :start 0 :end width)
    (when (< width inner-width)
      (write-string (make-string (- inner-width width)
                                 :initial-element #\Space)
                    stream)))
  (reset-attrs stream)
  (write-char #\| stream))

(defun %render-client-picker
    (stream terminal-rows terminal-cols items query index &key regex-p)
  (when (and (>= terminal-rows 5) (>= terminal-cols 12))
    (let* ((inner-width (min 68 (max 1 (- terminal-cols 6))))
           (max-items (max 1 (min 10 (- terminal-rows 4))))
           (item-count (length items))
           (first-index (if (plusp item-count)
                            (max 0 (min index (- item-count max-items)))
                            0))
           (last-index (min item-count (+ first-index max-items)))
           (display-count (max 1 (- last-index first-index)))
           (body-height (+ 1 display-count))
           (box-height (+ body-height 2))
           (top (max 0 (floor (- terminal-rows box-height) 2)))
           (left (max 0 (floor (- terminal-cols (+ inner-width 2)) 2))))
      (move-to stream top left)
      (write-char #\+ stream)
      (write-string (make-string inner-width :initial-element #\-) stream)
      (write-char #\+ stream)
      (%write-picker-box-line stream (1+ top) left
                              (format nil "~:[literal~;regex~] query: ~A"
                                      regex-p query)
                              inner-width)
      (loop for item-index from first-index below last-index
            for row from (+ top 2) do
              (let ((item (nth item-index items)))
                (%write-picker-box-line
                 stream row left
                 (%picker-item-display-text item)
                 inner-width
                 :selected (= item-index index)
                 :attention (nerimux/picker:picker-item-attention-p item))))
      (when (= last-index first-index)
        (%write-picker-box-line stream (+ top 2) left "no matches"
                                inner-width))
      (move-to stream (+ top box-height -1) left)
      (write-char #\+ stream)
      (write-string (make-string inner-width :initial-element #\-) stream)
      (write-char #\+ stream)
      )))

(defun %render-client-command-line
    (stream terminal-rows terminal-cols command-buffer)
  (when (and (stringp command-buffer)
             (plusp terminal-rows)
             (plusp terminal-cols))
    (let* ((text (concatenate 'string ":" command-buffer))
           (start (max 0 (- (length text) terminal-cols)))
           (visible (subseq text start))
           (width (length visible)))
      (move-to stream (1- terminal-rows) 0)
      (write-string visible stream)
      (when (< width terminal-cols)
        (write-string (make-string (- terminal-cols width)
                                   :initial-element #\Space)
                      stream))
      (reset-attrs stream))))

(defun render-session-to-string (session terminal-rows terminal-cols
                                 &key focus-pane (viewport 0) (mode :normal)
                                   (picker-items nil) (picker-query "")
                                   (picker-index 0) (picker-regex-p nil)
                                   (command-buffer ""))
  "Compose a full frame for SESSION as an escape-sequence string.
   FOCUS-PANE overrides the session's active pane when it belongs to the
   active window.  VIEWPORT and MODE are accepted at this boundary for
   per-client rendering; their interaction with overlays is implemented by
   the corresponding mode/viewport phases.  Does not touch *standard-output*;
   suitable for unit-testing without a TTY."
  (let* ((buffer      (make-string-output-stream))
         (window      (session-active-window session))
         (panes       (when window (window-panes window)))
         (active-pane (or (and focus-pane
                               (find focus-pane panes :test #'eq))
                          (session-active-pane session)))
         ;; Status row count from the `status` option (0..5).  The pane layout
         ;; reserves the matching count via nerimux/config:*status-height*, kept
         ;; in sync by the `status` option's side-effect — so the bar and the
         ;; pane area stay in lockstep in normal use.
         (status-lines (nerimux/options:status-line-count))
         (status-on   (> status-lines 0))
         (status-pos  (nerimux/options:get-option "status-position" "bottom")))
    (cursor-invisible buffer)
    (if (session-locked-p session)
        (render-lock-screen buffer terminal-rows terminal-cols)
        (progn
          (%render-panes-and-borders buffer session window panes active-pane terminal-cols
                                     :viewport viewport)
          ;; pane-border-status title lines (drawn after borders so they overwrite border cells)
          (when (and window panes
                     (string/= (nerimux/options:get-option "pane-border-status" "off") "off"))
            (dolist (pane panes)
              (%render-pane-border-status buffer pane session window)))
          ;; copy-mode search-match highlighting on the active pane (it is the one that
          ;; can be in copy mode), overdrawn after panes/borders.
          (when (and active-pane (pane-screen active-pane)
                     (screen-copy-mode-p (pane-screen active-pane)))
            (%render-copy-search-matches buffer active-pane))
          (%render-overlay-layer buffer active-pane terminal-rows terminal-cols)
          (when status-on
            (render-status-region buffer session terminal-rows terminal-cols
                                  status-lines status-pos))
          (when (eq mode :picker)
            (%render-client-picker buffer terminal-rows terminal-cols
                                   (or picker-items '()) picker-query
                                   picker-index :regex-p picker-regex-p))
          (when (eq mode :command)
            (%render-client-command-line buffer terminal-rows terminal-cols
                                         command-buffer))
          (%render-mouse-sequences buffer active-pane)
          ;; allow-passthrough: emit any DCS-passthrough sequences (images, nested tmux).
          (when panes (%render-passthrough buffer panes))
          (when panes (%render-clipboard buffer panes))
          (%render-bell-and-cursor buffer active-pane)
          ;; Relay bells from background windows (bell-action 'any'/'other').
          (%render-background-bells buffer session window)
          ;; set-titles: emit OSC 0 to set the outer terminal window title.
          (when (nerimux/options:get-option "set-titles")
            (let* ((title-fmt (nerimux/options:get-option "set-titles-string" "#W"))
                   (win        (session-active-window session))
                   (pane       (session-active-pane session))
                   (ctx        (nerimux/format:format-context-from-session session win pane))
                   (title      (nerimux/format:expand-format title-fmt ctx)))
              (format buffer "~C]0;~A~C" +esc+ title (code-char 7))))))
    (get-output-stream-string buffer)))

(defun render-session (session terminal-rows terminal-cols)
  "Repaint all panes and the status bar; flush to *standard-output* in one write."
  (write-string (render-session-to-string session terminal-rows terminal-cols))
  (force-output))
