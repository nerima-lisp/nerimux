(in-package #:nerimux/renderer)

(defparameter +workspace-command-names+
  '("wt-create" "wt-delete"
                "wt-lock"
                "wt-unlock"
                "wt-prune"
                "wt-prune-confirm"
                "wt-complete"
                "workspace-complete"
                "workspace-prune"
                "workspace-prune-all"
                "overview"
                "detail"
                "refresh"
                "kill")
  "Command names completed by the workspace `:` prompt.")

(defun %workspace-command-completions (command-buffer)
  "Return command names matching COMMAND-BUFFER's first token."
  (let* ((trimmed (string-left-trim " " command-buffer))
         (space (position #\Space trimmed)))
    (if space
        nil
        (remove-if-not
         (lambda (name)
           (and (<= (length trimmed) (length name))
                (string= trimmed name :end2 (length trimmed))))
         +workspace-command-names+))))

(defun %workspace-command-hint-rows (row)
  "The rows a candidate list may spill onto: the gap between the message line
   and the prompt at ROW, which the key panel would own if the prompt were not
   up. Empty on a terminal too short to have that gap."
  (let ((message-row (+ (workspace-tree-view-rows (1+ row)) 4)))
    (loop for candidate from (1+ message-row) below row
          collect candidate)))

(defun %wrap-workspace-command-names (names width)
  "NAMES broken into lines of at most WIDTH columns, never mid-name."
  (let ((lines nil)
        (current ""))
    (dolist (name names)
      (let ((extended (if (zerop (length current))
                          name
                          (concatenate 'string current " " name))))
        (if (or (zerop (length current))
                (<= (%display-width extended) width))
            (setf current extended)
            (progn (push current lines)
                   (setf current name)))))
    (nreverse (if (plusp (length current))
                  (cons current lines)
                  lines))))

(defun %render-workspace-command-hint-lines (stream rows cols lines)
  "Paint LINES faint across ROWS, indented two columns."
  (loop for line in lines
        for line-row in rows
        do (let* ((text (%display-clip (format nil "  ~A" line) cols))
                  (pad (- cols (%display-width text))))
             (move-to stream line-row 0)
             (%emit-sgr stream +sgr-faint+)
             (write-string text stream)
             (reset-attrs stream)
             (when (plusp pad)
               (write-string (make-string pad :initial-element #\Space)
                             stream)))))

(defun %render-workspace-command-line (stream row cols command-buffer)
  "Draw the workspace command line and completion candidates at ROW.
   The `:` prompt renders bold accent, the typed buffer in the default
   colour, completion candidates faint; widths are still measured on the
   escape-free text so the clip math is unchanged.
   A candidate list too wide for the prompt row wraps onto the free rows above
   it rather than losing its tail to the clip."
  (let* ((typed (format nil ":~A" command-buffer))
         (typed-width (%display-width typed))
         (completions (%workspace-command-completions command-buffer)))
    (if (>= typed-width cols)
        (let ((visible (%display-clip-tail typed cols)))
          (move-to stream row 0)
          (write-string visible stream)
          (reset-attrs stream))
        (let* ((remaining (- cols typed-width))
               (inline-text (if completions
                                (format nil "  ~{~A~^ ~}" completions)
                                ""))
               (wrapped-p (> (%display-width inline-text) remaining))
               (hint-rows (when wrapped-p (%workspace-command-hint-rows row)))
               (lines (when wrapped-p
                        (%wrap-workspace-command-names completions
                                                       (max 1 (- remaining 2)))))
               (above (subseq lines 0 (min (length lines) (length hint-rows))))
               (suffix (%display-clip
                        (if wrapped-p
                            (format nil "  ~{~A~^ ~}" (nthcdr (length above) lines))
                            inline-text)
                        remaining))
               (width (+ typed-width (%display-width suffix))))
          (when above
            (%render-workspace-command-hint-lines stream hint-rows cols above))
          (move-to stream row 0)
          (%emit-sgr stream +sgr-accent-bold+)
          (write-char #\: stream)
          (reset-attrs stream)
          (write-string command-buffer stream)
          (%emit-sgr stream +sgr-faint+)
          (write-string suffix stream)
          (reset-attrs stream)
          (when (< width cols)
            (write-string (make-string (- cols width) :initial-element #\Space)
                          stream))
          (reset-attrs stream)))))

(defun %render-workspace-tree-filter-line (stream row cols tree-filter)
  "Draw the tree-filter (`/query`) input line at ROW: the `%RENDER-
   WORKSPACE-COMMAND-LINE` shape, but for the one-column overview's tree
   search -- a bold-accent `/` followed by the typed query.
   No separate cursor glyph is drawn: like the `:` command line, the real
   terminal cursor stays hidden (CURSOR-INVISIBLE, called once for the whole
   frame) and a synthetic block cursor would need an ambiguous-width
   character the UI theme convention bans, so the end of the typed text is
   the only cursor cue, exactly as `:` already works."
  (let* ((typed (format nil "/~A" (or tree-filter "")))
         (typed-width (%display-width typed)))
    (if (>= typed-width cols)
        (let ((visible (%display-clip-tail typed cols)))
          (move-to stream row 0)
          (write-string visible stream)
          (reset-attrs stream))
        (progn
          (move-to stream row 0)
          (%emit-sgr stream +sgr-accent-bold+)
          (write-char #\/ stream)
          (reset-attrs stream)
          (write-string (or tree-filter "") stream)
          (when (< typed-width cols)
            (write-string
             (make-string (- cols typed-width) :initial-element #\Space)
             stream))
          (reset-attrs stream)))))
