(in-package #:nerimux/renderer)

;;;; Workspace `:` command completion and footer-row rendering (R6.12).

(defparameter +workspace-command-names+
  '("wt-create" "wt-delete" "wt-lock" "wt-unlock" "wt-prune" "wt-prune-confirm"
    "overview" "detail" "refresh")
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
               (suffix (if completions
                           (%display-clip (format nil "  ~{~A~^ ~}" completions) remaining)
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
            (write-string (make-string (- cols width) :initial-element #\Space) stream))
          (reset-attrs stream)))))
