(in-package #:nerimux/renderer)

;;;; PANE-frame compositing for the nerimux renderer.
;;;;
;;;; This file owns the full-frame pipeline for the terminal-pane view:
;;;; pane/border rendering, overlay dispatch, mouse sequences, bell emission,
;;;; cursor restoration, and the render-session / render-session-to-string
;;;; entry points.
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
;;;;             → renderer-pane → renderer-statusbar
;;;;             → renderer-compose-protocols → renderer-compose-overlay
;;;;             → renderer-compose-effects → renderer-compose

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
                          (session-active-pane session))))
    (cursor-invisible buffer)
    (%render-panes-and-borders buffer session window panes active-pane terminal-cols
                               :viewport viewport)
    ;; pane-border-status (border title lines) is deleted outright — R6.6.
    ;; copy-mode search-match highlighting on the active pane (it is the one that
    ;; can be in copy mode), overdrawn after panes/borders.
    (when (and active-pane (pane-screen active-pane)
               (screen-copy-mode-p (pane-screen active-pane)))
      (%render-copy-search-matches buffer active-pane))
    (%render-overlay-layer buffer active-pane terminal-rows terminal-cols)
    ;; Status line is fixed at one row, docked to the bottom (§1.4).
    ;; `status`/`status-position` (domain/options, deleted R2.2) always
    ;; resolved to "on" (1 row) / "bottom", which is exactly what
    ;; render-status-bar's default :status-row (the bottom row) already
    ;; draws — so this is not a behaviour change.
    (render-status-bar buffer session terminal-rows terminal-cols)
    (when (eq mode :picker)
      (%render-client-picker buffer terminal-rows terminal-cols
                             (or picker-items '()) picker-query
                             picker-index :regex-p picker-regex-p))
    (when (eq mode :command)
      (%render-client-command-line buffer terminal-rows terminal-cols
                                   command-buffer))
    ;; allow-passthrough: emit any DCS-passthrough sequences (images, nested tmux).
    (when panes (%render-passthrough buffer panes))
    (when panes (%render-clipboard buffer panes))
    (%render-bell-and-cursor buffer active-pane)
    (%discard-background-bells session window)
    ;; set-titles: emit OSC 0 to set the outer terminal window title.
    ;; set-titles defaulted to off (domain/options, deleted R2.2) — a change
    ;; from that default, made unconditional per R2.2: R6.11 changes the
    ;; CONTENT of the title later; this only removes the dead on/off branch,
    ;; since nothing could ever have flipped it on with no config to write
    ;; through.  set-titles-string's content is unchanged for now
    ;; ("#S:#I:#W" = session name : window index : window name).
    (let* ((win   (session-active-window session))
           (title (format nil "~A:~D:~A"
                          (session-name session)
                          (if win (window-id win) 0)
                          (if win (window-name win) ""))))
      (format buffer "~C]0;~A~C" +esc+ title (code-char 7)))
    (get-output-stream-string buffer)))

(defun render-session (session terminal-rows terminal-cols)
  "Repaint all panes and the status bar; flush to *standard-output* in one write."
  (write-string (render-session-to-string session terminal-rows terminal-cols))
  (force-output))
