(in-package #:nerimux/picker)

(defstruct 
    (picker-item
     (:constructor %make-picker-item
                   (&key id kind label organization repository worktree pane)))
  id
  kind
  label
  organization
  repository
  worktree
  pane)

(defun %picker-string (value)
  (cond
    ((null value) "")
    ((stringp value) value)
    ((pathnamep value) (namestring value))
    (t (princ-to-string value))))

(defun %first-picker-string (&rest values)
  (loop for value in values
        for string = (%picker-string value)
        when (plusp (length string))
          do (return string)
        finally (return "")))

(defun %organization-label (organization)
  (let ((host
         (%picker-string
          (nerimux/workspace-model:organization-host organization)))
        (name
         (%picker-string
          (nerimux/workspace-model:organization-name organization))))
    (cond
      ((and (plusp (length host)) (plusp (length name)))
       (format nil "~A/~A" host name))
      ((plusp (length host)) host)
      ((plusp (length name)) name)
      (t
       (%picker-string (nerimux/workspace-model:organization-id organization))))))

(defun %repository-label (repository)
  (%first-picker-string
   (nerimux/workspace-model:repository-specification repository)
   (nerimux/workspace-model:repository-local-path repository)
   (nerimux/workspace-model:repository-id repository)))

(defun %worktree-label (worktree)
  (let ((branch
         (%picker-string (nerimux/workspace-model:worktree-branch worktree)))
        (path (%picker-string (nerimux/workspace-model:worktree-path worktree))))
    (cond
      ((and (plusp (length branch)) (plusp (length path)))
       (format nil "~A — ~A" branch path))
      ((plusp (length branch)) branch)
      ((plusp (length path)) path)
      (t (%picker-string (nerimux/workspace-model:worktree-id worktree))))))

(defun %organization-id (organization)
  (format nil
          "organization/~A"
          (%first-picker-string
           (nerimux/workspace-model:organization-id organization)
           (%organization-label organization))))

(defun %repository-id (organization repository)
  (format nil
          "~A/repository/~A"
          (%organization-id organization)
          (%first-picker-string
           (nerimux/workspace-model:repository-id repository)
           (%repository-label repository))))

(defun %worktree-id (organization repository worktree)
  (format nil
          "~A/worktree/~A"
          (%repository-id organization repository)
          (%first-picker-string (nerimux/workspace-model:worktree-id worktree)
                                (%worktree-label worktree))))

(defun %pane-label (pane)
  (format nil
          "pane/~D ~A"
          (nerimux/pane:pane-id pane)
          (%first-picker-string (nerimux/pane:pane-title pane)
                                (nerimux/pane:pane-start-command pane)
                                "shell")))

(defun %pane-id (organization repository worktree pane)
  (format nil
          "~A/pane/~D"
          (%worktree-id organization repository worktree)
          (nerimux/pane:pane-id pane)))

(defun %make-organization-item (organization)
  (%make-picker-item :id
                     (%organization-id organization)
                     :kind
                     :organization
                     :label
                     (%organization-label organization)
                     :organization
                     organization))

(defun %make-repository-item (organization repository)
  (%make-picker-item :id
                     (%repository-id organization repository)
                     :kind
                     :repository
                     :label
                     (%repository-label repository)
                     :organization
                     organization
                     :repository
                     repository))

(defun %make-worktree-item (organization repository worktree)
  (%make-picker-item :id
                     (%worktree-id organization repository worktree)
                     :kind
                     :worktree
                     :label
                     (%worktree-label worktree)
                     :organization
                     organization
                     :repository
                     repository
                     :worktree
                     worktree))

(defun %make-pane-item (organization repository worktree pane)
  (%make-picker-item :id
                     (%pane-id organization repository worktree pane)
                     :kind
                     :pane
                     :label
                     (%pane-label pane)
                     :organization
                     organization
                     :repository
                     repository
                     :worktree
                     worktree
                     :pane
                     pane))

(defun build-global-picker-items (organizations)
  (check-type organizations list)
  (let ((items nil))
    (dolist (organization (reverse organizations) items)
      (dolist 
          (repository
           (reverse
            (nerimux/workspace-model:organization-repositories organization)))
        (dolist 
            (worktree
             (reverse (nerimux/workspace-model:repository-worktrees repository)))
          (dolist 
              (pane (reverse (nerimux/workspace-model:worktree-panes worktree)))
            (push (%make-pane-item organization repository worktree pane) items))
          (push (%make-worktree-item organization repository worktree) items))
        (push (%make-repository-item organization repository) items))
      (push (%make-organization-item organization) items))))

(defun %repository-attention-p (repository)
  (or (nerimux/workspace-model:repository-dirty-p repository)
      (nerimux/workspace-model:repository-conflict-p repository)
      (plusp (nerimux/workspace-model:repository-ahead repository))
      (plusp (nerimux/workspace-model:repository-behind repository))
      (nerimux/workspace-model:repository-missing-p repository)
      (some #'nerimux/workspace-model:worktree-attention-p
            (nerimux/workspace-model:repository-worktrees repository))))

(defun picker-item-attention-p (item)
  (check-type item picker-item)
  (case (picker-item-kind item)
    (:organization
     (or
      (nerimux/workspace-model:organization-missing-p
       (picker-item-organization item))
      (plusp
       (nerimux/workspace-model:organization-attention-count
        (picker-item-organization item)))
      (some #'%repository-attention-p
            (nerimux/workspace-model:organization-repositories
             (picker-item-organization item)))))
    (:repository (%repository-attention-p (picker-item-repository item)))
    (:worktree
     (nerimux/workspace-model:worktree-attention-p (picker-item-worktree item)))
    (:pane (nerimux/pane:pane-attention-p (picker-item-pane item)))
    (otherwise nil)))

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

(defun %benchmark-organizations (organization-count repository-count
                                                    worktree-count
                                                    pane-count)
  (when 
      (and (zerop organization-count)
           (plusp (+ repository-count worktree-count pane-count)))
    (error
     "Cannot distribute repositories, worktrees, or panes across zero organizations"))
  (when (and (zerop repository-count) (plusp (+ worktree-count pane-count)))
    (error "Cannot distribute worktrees or panes across zero repositories"))
  (when (and (zerop worktree-count) (plusp pane-count))
    (error "Cannot distribute panes across zero worktrees"))
  (let* ((organizations
          (coerce
           (loop for organization-index below organization-count
                 collect (nerimux/workspace-model:make-organization :id
                                                                    (format nil
                                                                            "org-~4,'0D"
                                                                            organization-index)
                                                                    :host
                                                                    "github.com"
                                                                    :name
                                                                    (format nil
                                                                            "org-~4,'0D"
                                                                            organization-index)))
           'vector))
         (repositories-by-organization
          (make-array organization-count :initial-element nil))
         (worktree-base
          (if (plusp repository-count)
              (floor worktree-count repository-count)
              0))
         (worktree-remainder
          (if (plusp repository-count)
              (mod worktree-count repository-count)
              0))
         (all-worktrees nil))
    (dotimes (repository-index repository-count)
      (let* ((organization-index (mod repository-index organization-count))
             (organization (aref organizations organization-index))
             (repository-worktree-count
              (+ worktree-base
                 (if (< repository-index worktree-remainder)
                     1
                     0)))
             (repository
              (nerimux/workspace-model:make-repository :id
                                                       (format nil
                                                               "repo-~4,'0D"
                                                               repository-index)
                                                       :organization
                                                       organization
                                                       :specification
                                                       (format nil
                                                               "github.com/org-~4,'0D/repo-~4,'0D"
                                                               organization-index
                                                               repository-index)
                                                       :local-path
                                                       (format nil
                                                               "/tmp/org-~4,'0D/repo-~4,'0D"
                                                               organization-index
                                                               repository-index)))
             (worktrees nil))
        (dotimes (worktree-index repository-worktree-count)
          (let ((worktree
                 (nerimux/workspace-model:make-worktree :id
                                                        (format nil
                                                                "worktree-~4,'0D-~4,'0D"
                                                                repository-index
                                                                worktree-index)
                                                        :repository
                                                        repository
                                                        :path
                                                        (format nil
                                                                "/tmp/org-~4,'0D/repo-~4,'0D/worktree-~4,'0D"
                                                                organization-index
                                                                repository-index
                                                                worktree-index)
                                                        :branch
                                                        (format nil
                                                                "branch-~4,'0D-~4,'0D"
                                                                repository-index
                                                                worktree-index)
                                                        :head
                                                        (format nil
                                                                "head-~4,'0D-~4,'0D"
                                                                repository-index
                                                                worktree-index))))
            (push worktree worktrees)
            (push worktree all-worktrees)))
        (setf (nerimux/workspace-model:repository-worktrees repository) (nreverse
                                                                         worktrees)
              (nerimux/workspace-model:repository-main-worktree repository) (first
                                                                             (nerimux/workspace-model:repository-worktrees
                                                                              repository)))
        (push repository (aref repositories-by-organization organization-index))))
    (setf all-worktrees (nreverse all-worktrees))
    (loop for organization across organizations
          for organization-index below organization-count
          do (let ((repositories
                    (nreverse
                     (aref repositories-by-organization organization-index))))
               (setf (nerimux/workspace-model:organization-repositories
                      organization) repositories
                     (nerimux/workspace-model:organization-active-worktree-count
                      organization) (loop for repository in repositories
                                          sum (length
                                               (nerimux/workspace-model:repository-worktrees
                                                repository)))
                     (nerimux/workspace-model:organization-attention-count
                      organization) 0)))
    (let* ((worktree-vector (coerce all-worktrees 'vector))
           (worktree-count (length worktree-vector)))
      (dotimes (pane-index pane-count)
        (let* ((worktree (aref worktree-vector (mod pane-index worktree-count)))
               (pane
                (nerimux/pane:make-pane :id
                                        (1+ pane-index)
                                        :title
                                        (format nil "pane-~4,'0D" pane-index)
                                        :start-command
                                        "shell"
                                        :start-path
                                        (nerimux/workspace-model:worktree-path
                                         worktree))))
          (nerimux/pane:worktree-add-pane worktree pane))))
    (coerce organizations 'list)))

(defun benchmark-global-picker (&key (organization-count 1000)
                                     (repository-count organization-count)
                                     pane-count
                                     worktree-count
                                     (query ""))
  (unless (and (integerp organization-count) (not (minusp organization-count)))
    (error "ORGANIZATION-COUNT must be a non-negative integer"))
  (unless (and (integerp repository-count) (not (minusp repository-count)))
    (error "REPOSITORY-COUNT must be a non-negative integer"))
  (when (not (null pane-count))
    (unless (and (integerp pane-count) (not (minusp pane-count)))
      (error "PANE-COUNT must be a non-negative integer")))
  (when (not (null worktree-count))
    (unless (and (integerp worktree-count) (not (minusp worktree-count)))
      (error "WORKTREE-COUNT must be a non-negative integer")))
  (check-type query string)
  (let* ((worktree-count
          (if (null worktree-count)
              (or pane-count 5000)
              worktree-count))
         (pane-count
          (if (null pane-count)
              worktree-count
              pane-count))
         (start (get-internal-real-time)))
    (let* ((organizations
            (%benchmark-organizations organization-count
                                      repository-count
                                      worktree-count
                                      pane-count))
           (items (build-global-picker-items organizations))
           (matches (filter-global-picker-items items query))
           (end (get-internal-real-time)))
      (list :organization-count
            organization-count
            :repository-count
            repository-count
            :pane-count
            pane-count
            :worktree-count
            worktree-count
            :item-count
            (length items)
            :match-count
            (length matches)
            :elapsed-ms
            (floor (* 1000 (- end start)) internal-time-units-per-second)))))
