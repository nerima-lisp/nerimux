(in-package #:nerimux/renderer)

(defun %session-title-pane (session focus-pane)
  "The pane RENDER-SESSION-TO-STRING's own ACTIVE-PANE binding resolves to,
   duplicated as a top-level function so RENDER-SESSION-TO-TUI-STRING
   (renderer-tui-kit.lisp, loads after this file) can derive the same pane
   at its own call boundary for the R6.11 title -- see the comment on
   render-session-to-string's title block below for why that second call is
   the one that actually reaches the client."
  (let* ((window (session-active-window session))
         (panes
          (when window
            (window-panes window))))
    (or (and focus-pane (find focus-pane panes :test #'eq))
        (session-active-pane session))))

(defun %render-panes-and-borders (buffer session
                                         window
                                         panes
                                         active-pane
                                         terminal-cols
                                         &key
                                         (viewport 0))
  "Render all panes and split-tree borders for WINDOW into BUFFER.
   Snapshots zoom state under the window lock to avoid a race with
   window-zoom-toggle running on the main thread."
  (let ((zoomed nil)
        (tree nil))
    (when window
      (with-lock-held ((window-lock window))
                      (setf zoomed (window-zoom-p window)
                            tree (window-tree window))))
    (dolist (pane panes)
      (render-pane buffer
                   session
                   pane
                   :viewport
                   (if (eq pane active-pane)
                       viewport
                       0)))
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
    (format nil
            "~A ~:[ ~;!~] ~A"
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
  (let* ((clipped (%display-clip text inner-width))
         (pad (- inner-width (%display-width clipped))))
    (write-string clipped stream)
    (when (plusp pad)
      (write-string (make-string pad :initial-element #\Space) stream)))
  (reset-attrs stream)
  (write-char #\| stream))

(defun %render-client-picker (stream terminal-rows
                                     terminal-cols
                                     items
                                     query
                                     index
                                     &key
                                     regex-p)
  (when (and (>= terminal-rows 5) (>= terminal-cols 12))
    (let* ((inner-width (min 68 (max 1 (- terminal-cols 6))))
           (max-items (max 1 (min 10 (- terminal-rows 4))))
           (item-count (length items))
           (first-index
            (if (plusp item-count)
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
      (%write-picker-box-line stream
                              (1+ top)
                              left
                              (format nil
                                      "~:[literal~;regex~] query: ~A"
                                      regex-p
                                      query)
                              inner-width)
      (loop for item-index from first-index below last-index
            for row from (+ top 2)
            do (let ((item (nth item-index items)))
                 (%write-picker-box-line stream
                                         row
                                         left
                                         (%picker-item-display-text item)
                                         inner-width
                                         :selected
                                         (= item-index index)
                                         :attention
                                         (nerimux/picker:picker-item-attention-p
                                          item))))
      (when (= last-index first-index)
        (%write-picker-box-line stream (+ top 2) left "no matches" inner-width))
      (move-to stream (+ top box-height -1) left)
      (write-char #\+ stream)
      (write-string (make-string inner-width :initial-element #\-) stream)
      (write-char #\+ stream))))

(defun %render-client-command-line
    (stream terminal-rows terminal-cols command-buffer)
  (when (and (stringp command-buffer)
             (plusp terminal-rows)
             (plusp terminal-cols))
    (let* ((text (concatenate 'string ":" command-buffer))
           (visible (%display-clip-tail text terminal-cols))
           (width (%display-width visible)))
      (move-to stream (1- terminal-rows) 0)
      (when (and (plusp (length visible)) (char= (char visible 0) #\:))
        (%emit-sgr stream +sgr-accent-bold+)
        (write-char #\: stream)
        (reset-attrs stream)
        (setf visible (subseq visible 1)))
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
         (active-pane (%session-title-pane session focus-pane)))
    (cursor-invisible buffer)
    (%render-panes-and-borders buffer session window panes active-pane terminal-cols
                               :viewport viewport)
    (when (and active-pane (pane-screen active-pane)
               (screen-copy-mode-p (pane-screen active-pane)))
      (%render-copy-search-matches buffer active-pane))
    (%render-overlay-layer buffer active-pane terminal-rows terminal-cols)
    (render-status-bar buffer session terminal-rows terminal-cols :mode mode)
    (when (eq mode :picker)
      (%render-client-picker buffer terminal-rows terminal-cols
                             (or picker-items '()) picker-query
                             picker-index :regex-p picker-regex-p))
    (when (eq mode :command)
      (%render-client-command-line buffer terminal-rows terminal-cols
                                   command-buffer))
    (when panes (%render-passthrough buffer panes))
    (when panes (%render-clipboard buffer panes))
    (%render-bell-and-cursor buffer active-pane)
    (%discard-background-bells session window)
    (let ((worktree (and active-pane (pane-worktree active-pane))))
      (write-string
       (%client-title-osc (and worktree (worktree-repository worktree))
                          worktree)
       buffer))
    (get-output-stream-string buffer)))
