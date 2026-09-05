(in-package #:nerimux/picker)

(defmacro define-picker-search-fields (name documentation &body fields)
  "Define the ordered data fields folded into a picker search index."
  `(defparameter ,name
     (list ,@fields)
     ,documentation))

(define-picker-search-fields *organization-search-fields*
                             "Organization-level fields folded into a picker item's search text.
   Each is a function of one ORGANIZATION, returning a string or NIL."
                             #'nerimux/workspace-model:organization-id
                             #'nerimux/workspace-model:organization-host
                             #'nerimux/workspace-model:organization-name
                             (lambda (organization)
                               (when 
                                   (nerimux/workspace-model:organization-missing-p
                                    organization)
                                 "missing"))
                             (lambda (organization)
                               (when 
                                   (plusp
                                    (nerimux/workspace-model:organization-attention-count
                                     organization))
                                 (format nil
                                         "attention ~D"
                                         (nerimux/workspace-model:organization-attention-count
                                          organization))))
                             (lambda (organization)
                               (format nil
                                       "repositories ~D worktrees ~D"
                                       (length
                                        (nerimux/workspace-model:organization-repositories
                                         organization))
                                       (nerimux/workspace-model:organization-active-worktree-count
                                        organization))))

(define-picker-search-fields *repository-search-fields*
                             "Repository-level fields folded into a picker item's search text.
   Each is a function of one REPOSITORY, returning a string or NIL."
                             #'nerimux/workspace-model:repository-id
                             #'nerimux/workspace-model:repository-specification
                             #'nerimux/workspace-model:repository-local-path
                             #'nerimux/workspace-model:repository-remote
                             #'nerimux/workspace-model:repository-backend
                             (lambda (repository)
                               (when 
                                   (nerimux/workspace-model:repository-dirty-p
                                    repository)
                                 "dirty"))
                             (lambda (repository)
                               (when 
                                   (nerimux/workspace-model:repository-conflict-p
                                    repository)
                                 "conflict"))
                             (lambda (repository)
                               (when 
                                   (plusp
                                    (nerimux/workspace-model:repository-ahead
                                     repository))
                                 (format nil
                                         "ahead ~D"
                                         (nerimux/workspace-model:repository-ahead
                                          repository))))
                             (lambda (repository)
                               (when 
                                   (plusp
                                    (nerimux/workspace-model:repository-behind
                                     repository))
                                 (format nil
                                         "behind ~D"
                                         (nerimux/workspace-model:repository-behind
                                          repository))))
                             (lambda (repository)
                               (when 
                                   (nerimux/workspace-model:repository-missing-p
                                    repository)
                                 "missing")))

(define-picker-search-fields *worktree-search-fields*
                             "Worktree-level fields folded into a picker item's search text.
   Each is a function of one WORKTREE, returning a string or NIL."
                             #'nerimux/workspace-model:worktree-id
                             #'nerimux/workspace-model:worktree-branch
                             #'nerimux/workspace-model:worktree-path
                             #'nerimux/workspace-model:worktree-head
                             #'nerimux/workspace-model:worktree-status
                             (lambda (worktree)
                               (when 
                                   (nerimux/workspace-model:worktree-dirty-p
                                    worktree)
                                 "dirty"))
                             (lambda (worktree)
                               (when 
                                   (nerimux/workspace-model:worktree-conflict-p
                                    worktree)
                                 "conflict"))
                             (lambda (worktree)
                               (when 
                                   (plusp
                                    (nerimux/workspace-model:worktree-ahead
                                     worktree))
                                 (format nil
                                         "ahead ~D"
                                         (nerimux/workspace-model:worktree-ahead
                                          worktree))))
                             (lambda (worktree)
                               (when 
                                   (plusp
                                    (nerimux/workspace-model:worktree-behind
                                     worktree))
                                 (format nil
                                         "behind ~D"
                                         (nerimux/workspace-model:worktree-behind
                                          worktree))))
                             (lambda (worktree)
                               (when 
                                   (nerimux/workspace-model:worktree-bare-p
                                    worktree)
                                 "bare"))
                             (lambda (worktree)
                               (when 
                                   (nerimux/workspace-model:worktree-locked-p
                                    worktree)
                                 "locked"))
                             (lambda (worktree)
                               (when 
                                   (nerimux/workspace-model:worktree-prunable-p
                                    worktree)
                                 "prunable"))
                             (lambda (worktree)
                               (when 
                                   (nerimux/workspace-model:worktree-missing-p
                                    worktree)
                                 "missing"))
                             #'nerimux/pane:worktree-attention-reasons)

(define-picker-search-fields *pane-search-fields*
                             "Pane-level fields folded into a picker item's search text.
   Each is a function of one PANE, returning a string or NIL."
                             #'nerimux/pane:pane-id
                             #'nerimux/pane:pane-title
                             #'nerimux/pane:pane-start-command
                             #'nerimux/pane:pane-start-path
                             #'nerimux/pane:pane-last-output
                             #'nerimux/pane:pane-notification
                             #'nerimux/pane:pane-last-output-time
                             #'nerimux/pane:pane-last-focused-time
                             #'nerimux/pane:pane-attention-reasons)

(defun %level-search-values (level-object field-fns)
  "Apply each of FIELD-FNS to LEVEL-OBJECT, or return NIL when LEVEL-OBJECT
   itself is NIL (the picker item does not reach that level)."
  (when level-object
    (mapcar
     (lambda (fn)
       (funcall fn level-object))
     field-fns)))

(defun %picker-item-search-text (item)
  (with-output-to-string (stream)
    (dolist 
        (value
         (list* (picker-item-id item)
                (picker-item-kind item)
                (picker-item-label item)
                (append
                 (%level-search-values (picker-item-organization item)
                                       *organization-search-fields*)
                 (%level-search-values (picker-item-repository item)
                                       *repository-search-fields*)
                 (%level-search-values (picker-item-worktree item)
                                       *worktree-search-fields*)
                 (%level-search-values (picker-item-pane item)
                                       *pane-search-fields*))))
      (let ((string (%picker-string value)))
        (when (plusp (length string))
          (write-string string stream)
          (write-char #\Space stream))))))

(defun %picker-regex-scanner (query)
  (handler-case (cl-regex-kit:compile-regex query
                                            :case-insensitive
                                            t
                                            :octal
                                            nil)
    (cl-regex-kit:regex-syntax-error ()
      nil)))

(defun filter-global-picker-items (items query &key regex-p)
  (check-type items list)
  (check-type query string)
  (if (zerop (length query))
      (copy-list items)
      (let ((needle (string-downcase query))
            (scanner (and regex-p (%picker-regex-scanner query))))
        (loop for item in items
              for text = (%picker-item-search-text item)
              when (if regex-p
                       (and scanner (cl-regex-kit:scan scanner text))
                       (not (null (cl:search needle (string-downcase text)))))
                collect item))))

(defun select-global-picker-item (items selection)
  (check-type items list)
  (cond
    ((and (integerp selection) (plusp selection)) (nth (1- selection) items))
    ((stringp selection)
     (or (find selection items :key #'picker-item-id :test #'string=)
         (find selection items :key #'picker-item-label :test #'string=)))
    (t nil)))

