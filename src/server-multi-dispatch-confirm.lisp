(in-package #:nerimux)

(defconstant +confirm-clean-preview-limit+ 8
  "Paths named in a `git clean` confirmation before the rest are only counted.")

(defun %confirm-clean-preview-p (operation)
  "T when OPERATION is a `git clean`, the one confirmation whose effect cannot
   be undone from git afterwards."
  (let ((prefix "git clean"))
    (and (>= (length operation) (length prefix))
         (string= prefix operation :end2 (length prefix)))))

(defun %confirm-clean-preview-paths (output)
  "The paths OUTPUT, a `git clean -n -d` run, said it would remove."
  (loop with start = 0
        with prefix = "Would remove "
        for newline = (position #\Newline output :start start)
        for line = (string-right-trim '(#\Return) (subseq output start (or newline (length output))))
        when (and (>= (length line) (length prefix))
                  (string= prefix line :end2 (length prefix)))
          collect (subseq line (length prefix))
        while newline
        do (setf start (1+ newline))))

(defun %confirm-clean-preview-text (output)
  (let* ((paths (%confirm-clean-preview-paths output))
         (extra (- (length paths) +confirm-clean-preview-limit+)))
    (cond
      ((null paths) "nothing")
      ((plusp extra)
       (format nil "~{~A~^ ~}  +~D more"
               (subseq paths 0 +confirm-clean-preview-limit+)
               extra))
      (t (format nil "~{~A~^ ~}" paths)))))

(defun %set-confirm-view-field (conn view label value)
  "Replace LABEL's line in VIEW, as long as VIEW is still the box on screen."
  (when (eq view (client-conn-confirm-view conn))
    (setf (nerimux/renderer:confirm-view-fields view)
          (mapcar (lambda (field)
                    (if (string= label (car field))
                        (cons label value)
                        field))
                  (nerimux/renderer:confirm-view-fields view)))
    (%mark-dirty)))

(defun %request-confirm-clean-preview (conn view)
  "Fill VIEW's `removes` line from `git clean -n -d`, the list magit shows
   before the same question -- untracked files are gone for good once y runs."
  (let ((repository (and (nerimux/vcs:vcs-package-available-p)
                         (%client-selected-repository conn))))
    (if repository
        (nerimux/vcs:git-write-operation-async
         repository
         :clean
         '("-n" "-d")
         :callback-dispatch #'%enqueue-main-thread-callback
         :on-complete (lambda (success-p output)
                        (%set-confirm-view-field
                         conn view "removes"
                         (if success-p
                             (%confirm-clean-preview-text output)
                             "list unavailable")))
         :on-error (lambda (condition)
                     (declare (ignore condition))
                     (%set-confirm-view-field conn view "removes"
                                              "list unavailable")))
        (%set-confirm-view-field conn view "removes" "list unavailable"))))

(defun %open-confirm-view (conn operation fields action &key on-cancel)
  "Put a y/n confirmation in front of CONN and remember what to run on y.
   OPERATION titles the box; FIELDS is the ordered (LABEL . VALUE) body, to
   which this adds, for `git clean`, the file list read while the box is
   already up.  The keys that answer the box are the prompt line's job
   (%CONFIRM-VIEW-PROMPT-LINE), not a field repeating them above it."
  (let* ((clean-p (%confirm-clean-preview-p operation))
         (view (nerimux/renderer:make-confirm-view
                :operation operation
                :fields (append fields
                                (when clean-p (list (cons "removes" "reading"))))
                :prompt-p t)))
    (setf (client-conn-confirm-view conn) view
          (client-conn-confirm-action conn) action
          (client-conn-confirm-cancel-action conn) on-cancel)
    (%set-client-modal conn :confirm)
    (when clean-p
      (%request-confirm-clean-preview conn view))
    nil))

(defun %close-confirm-view (conn)
  "Take the confirmation down and forget its pending action."
  (setf (client-conn-confirm-view conn) nil
        (client-conn-confirm-action conn) nil
        (client-conn-confirm-cancel-action conn) nil)
  (%set-client-modal conn nil))

(defun %cancel-confirm-view (conn)
  "Answer the confirmation with no, whichever cancel key was struck."
  (let ((cancel (client-conn-confirm-cancel-action conn)))
    (%close-confirm-view conn)
    (%client-notify conn "cancelled")
    (and cancel (funcall cancel))))

(define-key-rules %handle-confirm-key (session conn payload)
  "Answer the confirmation CONN is looking at.  Returns two values: whether the
   key was consumed here, and the loop disposition.

   y executes; Esc, q, n and the C-q C-q escape cancel, the keys
   getting-started.md promises close any modal.  The prefix is read here
   because :confirm is dispatched ahead of %HANDLE-WORKSPACE-PREFIX-KEY.  Every
   other key is still swallowed: a confirmation that let j scroll the tree
   underneath it would be asking about one thing while the user changed
   another."
  (:let ((prefix-code (client-conn-workspace-prefix-code conn))))
  ((client-conn-ui-prefix-p conn)
   (setf (client-conn-ui-prefix-p conn) nil)
   (if (%client-byte-p payload prefix-code)
       (values t (%cancel-confirm-view conn))
       (values t nil)))
  ((%client-byte-p payload prefix-code)
   (setf (client-conn-ui-prefix-p conn) t)
   (values t nil))
  (#\y
   (let ((action (client-conn-confirm-action conn)))
     (%close-confirm-view conn)
     (values t (and action (funcall action)))))
  (27
   (%client-esc-swallow-start conn)
   (values t (%cancel-confirm-view conn)))
  ((or (%client-key-p payload #\q) (%client-key-p payload #\n))
   (values t (%cancel-confirm-view conn)))
  (t (values t nil)))
