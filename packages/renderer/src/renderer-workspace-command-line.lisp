(in-package #:nerimux/renderer)

(defparameter +workspace-command-names+
  '("wt-create" "wt-delete"
                "wt-lock"
                "wt-unlock"
                "wt-prune"
                "wt-prune-confirm"
                "overview"
                "detail"
                "refresh")
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

(defun %render-workspace-command-line (stream row cols command-buffer)
  "Draw the workspace command line and completion candidates at ROW.
   The `:` prompt renders bold accent, the typed buffer in the default
   colour, completion candidates faint; widths are still measured on the
   escape-free text so the clip math is unchanged."
  (let* ((typed (format nil ":~A" command-buffer))
         (typed-width (%display-width typed))
         (completions (%workspace-command-completions command-buffer)))
    (if (>= typed-width cols)
        (let ((visible (%display-clip-tail typed cols)))
          (move-to stream row 0)
          (write-string visible stream)
          (reset-attrs stream))
        (let* ((remaining (- cols typed-width))
               (suffix
                (if completions
                    (%display-clip (format nil "  ~{~A~^ ~}" completions)
                                   remaining)
                    ""))
               (width (+ typed-width (%display-width suffix))))
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
   search (redesign PR2) -- a bold-accent `/` followed by the typed query.
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
