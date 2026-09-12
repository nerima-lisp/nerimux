(in-package #:nerimux/renderer)

(defun %sgr-reinstate-background (text row-background)
  "TEXT with every bare SGR reset (ESC[0m, the plain restore every
   %SGR-WRAP in this renderer produces) rewritten to ESC[0;ROW-BACKGROUNDm,
   so a token that ends its own %SGR-WRAP mid-row (a mark, a fold glyph, an
   info-cluster colour) resets to the row's background instead of dropping
   it -- the row background %EMIT-STYLED-ROW opens with is otherwise only
   the row's OWN restore away from vanishing under the first embedded reset."
  (let ((reset (format nil "~C[0m" +esc+))
        (replacement (format nil "~C[0;~Am" +esc+ row-background)))
    (with-output-to-string (out)
      (loop with start = 0
            for hit = (search reset text :start2 start)
            do (write-string text out :start start :end (or hit (length text)))
               (when hit
                 (write-string replacement out)
                 (setf start (+ hit (length reset))))
            while hit))))

(defun %emit-styled-row (stream row col width text &optional row-background)
  "Draw TEXT (already SGR-wrapped by the caller) at ROW, COL, clipped and
   padded to WIDTH. ROW-BACKGROUND, when supplied (an SGR background
   fragment like \"48;2;68;71;90\"), is emitted before TEXT, reinstated
   after every embedded reset (%SGR-REINSTATE-BACKGROUND) so the row stays
   one colour behind its differently-coloured tokens, and kept active
   through the padding spaces -- the selected tree row's highlight, which
   must cover the whole row width, not just the token text."
  (when (plusp width)
    (move-to stream row col)
    (let* ((clipped (%visible-truncate text width))
           (pad (- width (%visible-length clipped))))
      (if row-background
          (progn
            (%emit-sgr stream row-background)
            (write-string (%sgr-reinstate-background clipped row-background) stream)
            (when (plusp pad)
              (write-string (make-string pad :initial-element #\Space) stream))
            (reset-attrs stream))
          (progn
            (write-string clipped stream)
            (reset-attrs stream)
            (when (plusp pad)
              (write-string (make-string pad :initial-element #\Space) stream)))))))

(defun %workspace-state-text (worktree)
  "WORKTREE's Git state for the detail panel, in the tree row's own words:
   a lowercase state word, ↑N/↓N for ahead/behind and +A −D for changed
   lines, so one glyph does not mean two things on one screen."
  (let* ((state (%worktree-git-state-text worktree))
         (state-sgr (and state (%worktree-state-token-sgr (string-upcase state))))
         (changes (%worktree-change-count-parts worktree))
         (parts
          (remove nil
                  (append
                   (list (and state
                              (if state-sgr (%sgr-wrap state state-sgr) state)))
                   (mapcar (lambda (part) (%sgr-wrap (car part) (cdr part)))
                           (%worktree-ahead-behind-parts worktree))
                   (list (and changes (cdr changes)))))))
    (format nil "~{~A~^ ~}"
            (or parts (list (%sgr-wrap "clean" +sgr-ok+))))))

(defun %render-workspace-scanning-frame (terminal-rows terminal-cols
                                                       &key
                                                       scan-progress)
  (let* ((rows (max 1 terminal-rows))
         (cols (max 1 terminal-cols))
         (stream (make-string-output-stream))
         (message
          (if (and (integerp scan-progress) (plusp scan-progress))
              (format nil
                      "scanning workspaces... ~D ~:[repositories~;repository~]"
                      scan-progress
                      (= scan-progress 1))
              "scanning workspaces..."))
         (text (%display-clip message cols)))
    (cursor-invisible stream)
    (move-to stream (floor rows 2) (%center-coord cols (%display-width text)))
    (%emit-sgr stream +sgr-muted-italic+)
    (write-string text stream)
    (reset-attrs stream)
    (write-string (%client-title-osc nil nil) stream)
    (get-output-stream-string stream)))

(defparameter +workspace-ghq-missing-root+
  "ghq not found on PATH"
  "What %RENDER-WORKSPACE-FRAME (src/server-multi-render.lisp) passes as
   GHQ-ROOT when NERIMUX/VCS:GHQ-ROOT-DIRECTORY answers NIL. Matched below
   rather than inferred, so the remedy line never tells the user to run the
   binary the line above it just reported missing.")

(defun %render-workspace-empty-catalog-hint (stream rows cols ghq-root)
  (let* ((top (max 0 (1- (floor rows 2))))
         (ghq-missing-p (string= ghq-root +workspace-ghq-missing-root+))
         (lines
          (list (cons (if ghq-missing-p
                          "no repositories scanned"
                          "no repositories found")
                      +sgr-muted-italic+)
                (cons (format nil "ghq root: ~A" ghq-root) +sgr-muted+)
                (cons (if ghq-missing-p
                          "install ghq, or add it to PATH"
                          "get one: ghq get <owner>/<repo>")
                      +sgr-muted+))))
    (loop for (text . sgr) in lines
          for row from top
          for clipped = (%display-clip text cols)
          do (move-to stream row (%center-coord cols (%display-width clipped)))
             (%emit-sgr stream sgr)
             (write-string clipped stream)
             (reset-attrs stream))))
