(in-package #:nerimux/renderer)

(defun %emit-styled-row (stream row col width text)
  (when (plusp width)
    (move-to stream row col)
    (let* ((clipped (%visible-truncate text width))
           (pad (- width (%visible-length clipped))))
      (write-string clipped stream)
      (reset-attrs stream)
      (when (plusp pad)
        (write-string (make-string pad :initial-element #\Space) stream)))))

(defun %workspace-state-text (worktree)
  (format nil
          "~{~A~^ ~}"
          (mapcar
           (lambda (token)
             (let ((sgr (%worktree-state-token-sgr token)))
               (if sgr
                   (%sgr-wrap token sgr)
                   token)))
           (%worktree-status-tokens worktree))))

(defun %render-workspace-scanning-frame (terminal-rows terminal-cols
                                                       &key
                                                       scan-progress)
  (let* ((rows (max 1 terminal-rows))
         (cols (max 1 terminal-cols))
         (stream (make-string-output-stream))
         (message
          (if (and (integerp scan-progress) (plusp scan-progress))
              (format nil
                      "scanning workspaces... ~D repositories"
                      scan-progress)
              "scanning workspaces..."))
         (text (%display-clip message cols)))
    (cursor-invisible stream)
    (move-to stream (floor rows 2) (%center-coord cols (%display-width text)))
    (%emit-sgr stream +sgr-muted-italic+)
    (write-string text stream)
    (reset-attrs stream)
    (write-string (%client-title-osc nil nil) stream)
    (get-output-stream-string stream)))

(defun %render-workspace-empty-catalog-hint (stream rows cols ghq-root)
  (let ((top (max 0 (1- (floor rows 2))))
        (lines
         (list (cons "no repositories found" +sgr-muted-italic+)
               (cons (format nil "ghq root: ~A" ghq-root) +sgr-muted+)
               (cons "get one: ghq get <owner>/<repo>" +sgr-muted+))))
    (loop for (text . sgr) in lines
          for row from top
          for clipped = (%display-clip text cols)
          do (move-to stream row (%center-coord cols (%display-width clipped)))
             (%emit-sgr stream sgr)
             (write-string clipped stream)
             (reset-attrs stream))))
