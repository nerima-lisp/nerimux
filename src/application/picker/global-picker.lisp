(in-package #:nerimux/picker)

(defstruct (picker-item
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
  (let ((host (%picker-string (nerimux/model:organization-host organization)))
        (name (%picker-string (nerimux/model:organization-name organization))))
    (cond
      ((and (plusp (length host)) (plusp (length name)))
       (format nil "~A/~A" host name))
      ((plusp (length host)) host)
      ((plusp (length name)) name)
      (t (%picker-string (nerimux/model:organization-id organization))))))

(defun %repository-label (repository)
  (%first-picker-string
   (nerimux/model:repository-specification repository)
   (nerimux/model:repository-local-path repository)
   (nerimux/model:repository-id repository)))

(defun %worktree-label (worktree)
  (let ((branch (%picker-string (nerimux/model:worktree-branch worktree)))
        (path (%picker-string (nerimux/model:worktree-path worktree))))
    (cond
      ((and (plusp (length branch)) (plusp (length path)))
       (format nil "~A — ~A" branch path))
      ((plusp (length branch)) branch)
      ((plusp (length path)) path)
      (t (%picker-string (nerimux/model:worktree-id worktree))))))

(defun %organization-id (organization)
  (format nil "organization/~A"
          (%first-picker-string
           (nerimux/model:organization-id organization)
           (%organization-label organization))))

(defun %repository-id (organization repository)
  (format nil "~A/repository/~A"
          (%organization-id organization)
          (%first-picker-string
           (nerimux/model:repository-id repository)
           (%repository-label repository))))

(defun %worktree-id (organization repository worktree)
  (format nil "~A/worktree/~A"
          (%repository-id organization repository)
          (%first-picker-string
           (nerimux/model:worktree-id worktree)
           (%worktree-label worktree))))

(defun %pane-label (pane)
  (format nil "pane/~D ~A"
          (nerimux/model:pane-id pane)
          (%first-picker-string
           (nerimux/model:pane-title pane)
           (nerimux/model:pane-start-command pane)
           "shell")))

(defun %pane-id (organization repository worktree pane)
  (format nil "~A/pane/~D"
          (%worktree-id organization repository worktree)
          (nerimux/model:pane-id pane)))

(defun %make-organization-item (organization)
  (%make-picker-item
   :id (%organization-id organization)
   :kind :organization
   :label (%organization-label organization)
   :organization organization))

(defun %make-repository-item (organization repository)
  (%make-picker-item
   :id (%repository-id organization repository)
   :kind :repository
   :label (%repository-label repository)
   :organization organization
   :repository repository))

(defun %make-worktree-item (organization repository worktree)
  (%make-picker-item
   :id (%worktree-id organization repository worktree)
   :kind :worktree
   :label (%worktree-label worktree)
   :organization organization
   :repository repository
   :worktree worktree))

(defun %make-pane-item (organization repository worktree pane)
  (%make-picker-item
   :id (%pane-id organization repository worktree pane)
   :kind :pane
   :label (%pane-label pane)
   :organization organization
   :repository repository
   :worktree worktree
   :pane pane))

(defun build-global-picker-items (organizations)
  (check-type organizations list)
  (let ((items nil))
    (dolist (organization (reverse organizations) items)
      (dolist (repository
               (reverse (nerimux/model:organization-repositories organization)))
        (dolist (worktree
                 (reverse (nerimux/model:repository-worktrees repository)))
          (dolist (pane (reverse (nerimux/model:worktree-panes worktree)))
            (push (%make-pane-item organization repository worktree pane)
                  items))
          (push (%make-worktree-item organization repository worktree) items))
        (push (%make-repository-item organization repository) items))
      (push (%make-organization-item organization) items))))

(defun %repository-attention-p (repository)
  (or (nerimux/model:repository-dirty-p repository)
      (nerimux/model:repository-conflict-p repository)
      (plusp (nerimux/model:repository-ahead repository))
      (plusp (nerimux/model:repository-behind repository))
      (nerimux/model:repository-missing-p repository)
      (some #'nerimux/model:worktree-attention-p
            (nerimux/model:repository-worktrees repository))))

(defun picker-item-attention-p (item)
  (check-type item picker-item)
  (case (picker-item-kind item)
    (:organization
     (or (nerimux/model:organization-missing-p
          (picker-item-organization item))
         (plusp (nerimux/model:organization-attention-count
                 (picker-item-organization item)))
         (some #'%repository-attention-p
               (nerimux/model:organization-repositories
                (picker-item-organization item)))))
    (:repository (%repository-attention-p (picker-item-repository item)))
    (:worktree (nerimux/model:worktree-attention-p
                (picker-item-worktree item)))
    (:pane (nerimux/model:pane-attention-p (picker-item-pane item)))
    (otherwise nil)))

(defparameter *organization-search-fields*
  (list #'nerimux/model:organization-id
        #'nerimux/model:organization-host
        #'nerimux/model:organization-name
        (lambda (organization)
          (when (nerimux/model:organization-missing-p organization)
            "missing"))
        (lambda (organization)
          (when (plusp (nerimux/model:organization-attention-count organization))
            (format nil "attention ~D"
                    (nerimux/model:organization-attention-count organization))))
        (lambda (organization)
          (format nil "repositories ~D worktrees ~D"
                  (length (nerimux/model:organization-repositories organization))
                  (nerimux/model:organization-active-worktree-count organization))))
  "Organization-level fields folded into a picker item's search text.
   Each is a function of one ORGANIZATION, returning a string or NIL.")

(defparameter *repository-search-fields*
  (list #'nerimux/model:repository-id
        #'nerimux/model:repository-specification
        #'nerimux/model:repository-local-path
        #'nerimux/model:repository-remote
        #'nerimux/model:repository-backend
        (lambda (repository)
          (when (nerimux/model:repository-dirty-p repository) "dirty"))
        (lambda (repository)
          (when (nerimux/model:repository-conflict-p repository) "conflict"))
        (lambda (repository)
          (when (plusp (nerimux/model:repository-ahead repository))
            (format nil "ahead ~D" (nerimux/model:repository-ahead repository))))
        (lambda (repository)
          (when (plusp (nerimux/model:repository-behind repository))
            (format nil "behind ~D" (nerimux/model:repository-behind repository))))
        (lambda (repository)
          (when (nerimux/model:repository-missing-p repository) "missing")))
  "Repository-level fields folded into a picker item's search text.
   Each is a function of one REPOSITORY, returning a string or NIL.")

(defparameter *worktree-search-fields*
  (list #'nerimux/model:worktree-id
        #'nerimux/model:worktree-branch
        #'nerimux/model:worktree-path
        #'nerimux/model:worktree-head
        #'nerimux/model:worktree-status
        (lambda (worktree)
          (when (nerimux/model:worktree-dirty-p worktree) "dirty"))
        (lambda (worktree)
          (when (nerimux/model:worktree-conflict-p worktree) "conflict"))
        (lambda (worktree)
          (when (plusp (nerimux/model:worktree-ahead worktree))
            (format nil "ahead ~D" (nerimux/model:worktree-ahead worktree))))
        (lambda (worktree)
          (when (plusp (nerimux/model:worktree-behind worktree))
            (format nil "behind ~D" (nerimux/model:worktree-behind worktree))))
        (lambda (worktree)
          (when (nerimux/model:worktree-bare-p worktree) "bare"))
        (lambda (worktree)
          (when (nerimux/model:worktree-locked-p worktree) "locked"))
        (lambda (worktree)
          (when (nerimux/model:worktree-prunable-p worktree) "prunable"))
        (lambda (worktree)
          (when (nerimux/model:worktree-missing-p worktree) "missing"))
        #'nerimux/model:worktree-attention-reasons)
  "Worktree-level fields folded into a picker item's search text.
   Each is a function of one WORKTREE, returning a string or NIL.")

(defparameter *pane-search-fields*
  (list #'nerimux/model:pane-id
        #'nerimux/model:pane-title
        #'nerimux/model:pane-start-command
        #'nerimux/model:pane-start-path
        #'nerimux/model:pane-last-output
        #'nerimux/model:pane-notification
        #'nerimux/model:pane-last-output-time
        #'nerimux/model:pane-last-focused-time
        #'nerimux/model:pane-attention-reasons)
  "Pane-level fields folded into a picker item's search text.
   Each is a function of one PANE, returning a string or NIL.")

(defun %level-search-values (level-object field-fns)
  "Apply each of FIELD-FNS to LEVEL-OBJECT, or return NIL when LEVEL-OBJECT
   itself is NIL (the picker item does not reach that level)."
  (when level-object (mapcar (lambda (fn) (funcall fn level-object)) field-fns)))

(defun %picker-item-search-text (item)
  (with-output-to-string (stream)
    (dolist (value
             (list* (picker-item-id item)
                    (picker-item-kind item)
                    (picker-item-label item)
                    (append
                     (%level-search-values
                      (picker-item-organization item) *organization-search-fields*)
                     (%level-search-values
                      (picker-item-repository item) *repository-search-fields*)
                     (%level-search-values
                      (picker-item-worktree item) *worktree-search-fields*)
                     (%level-search-values
                      (picker-item-pane item) *pane-search-fields*))))
      (let ((string (%picker-string value)))
        (when (plusp (length string))
          (write-string string stream)
          (write-char #\Space stream))))))

(defun %picker-regex-scanner (query)
  (handler-case
      (cl-regex-kit:compile-regex query
                                 :case-insensitive t
                                 :octal nil)
    (cl-regex-kit:regex-syntax-error () nil)))

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
                       (not (null
                             (cl:search needle (string-downcase text)))))
                collect item))))

(defun select-global-picker-item (items selection)
  (check-type items list)
  (cond
    ((and (integerp selection) (plusp selection))
     (nth (1- selection) items))
    ((stringp selection)
     (or (find selection items
               :key #'picker-item-id
               :test #'string=)
         (find selection items
               :key #'picker-item-label
               :test #'string=)))
    (t nil)))

(defun %benchmark-organizations
    (organization-count repository-count worktree-count pane-count)
  (when (and (zerop organization-count)
             (plusp (+ repository-count worktree-count pane-count)))
    (error "Cannot distribute repositories, worktrees, or panes across zero organizations"))
  (when (and (zerop repository-count)
             (plusp (+ worktree-count pane-count)))
    (error "Cannot distribute worktrees or panes across zero repositories"))
  (when (and (zerop worktree-count) (plusp pane-count))
    (error "Cannot distribute panes across zero worktrees"))
  (let* ((organizations
           (coerce
            (loop for organization-index below organization-count
                  collect
                  (nerimux/model:make-organization
                   :id (format nil "org-~4,'0D" organization-index)
                   :host "github.com"
                   :name (format nil "org-~4,'0D" organization-index)))
            'vector))
         (repositories-by-organization
           (make-array organization-count :initial-element nil))
         (worktree-base (if (plusp repository-count)
                            (floor worktree-count repository-count)
                        0))
         (worktree-remainder (if (plusp repository-count)
                                 (mod worktree-count repository-count)
                                 0))
         (all-worktrees nil))
    (dotimes (repository-index repository-count)
      (let* ((organization-index (mod repository-index organization-count))
             (organization (aref organizations organization-index))
             (repository-worktree-count
               (+ worktree-base
                  (if (< repository-index worktree-remainder) 1 0)))
             (repository
               (nerimux/model:make-repository
                :id (format nil "repo-~4,'0D" repository-index)
                :organization organization
                :specification
                (format nil "github.com/org-~4,'0D/repo-~4,'0D"
                        organization-index repository-index)
                :local-path
                (format nil "/tmp/org-~4,'0D/repo-~4,'0D"
                        organization-index repository-index)))
             (worktrees nil))
        (dotimes (worktree-index repository-worktree-count)
          (let ((worktree
                  (nerimux/model:make-worktree
                   :id (format nil "worktree-~4,'0D-~4,'0D"
                               repository-index worktree-index)
                   :repository repository
                   :path (format nil
                                 "/tmp/org-~4,'0D/repo-~4,'0D/worktree-~4,'0D"
                                 organization-index repository-index worktree-index)
                   :branch (format nil "branch-~4,'0D-~4,'0D"
                                   repository-index worktree-index)
                   :head (format nil "head-~4,'0D-~4,'0D"
                                 repository-index worktree-index))))
            (push worktree worktrees)
            (push worktree all-worktrees)))
        (setf (nerimux/model:repository-worktrees repository)
              (nreverse worktrees)
              (nerimux/model:repository-main-worktree repository)
              (first (nerimux/model:repository-worktrees repository)))
        (push repository (aref repositories-by-organization organization-index))))
    (setf all-worktrees (nreverse all-worktrees))
    (loop for organization across organizations
          for organization-index below organization-count
          do (let ((repositories
                     (nreverse (aref repositories-by-organization
                                     organization-index))))
               (setf (nerimux/model:organization-repositories organization)
                     repositories
                     (nerimux/model:organization-active-worktree-count organization)
                     (loop for repository in repositories
                           sum (length (nerimux/model:repository-worktrees
                                        repository)))
                     (nerimux/model:organization-attention-count organization)
                     0)))
    (let* ((worktree-vector (coerce all-worktrees 'vector))
           (worktree-count (length worktree-vector)))
      (dotimes (pane-index pane-count)
        (let* ((worktree (aref worktree-vector
                               (mod pane-index worktree-count)))
               (pane
                 (nerimux/model:make-pane
                  :id (1+ pane-index)
                  :title (format nil "pane-~4,'0D" pane-index)
                  :start-command "shell"
                  :start-path (nerimux/model:worktree-path worktree))))
          (nerimux/model:worktree-add-pane worktree pane))))
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
  (let* ((worktree-count (if (null worktree-count)
                             (or pane-count 5000)
                             worktree-count))
         (pane-count (if (null pane-count)
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
      (list :organization-count organization-count
            :repository-count repository-count
            :pane-count pane-count
            :worktree-count worktree-count
            :item-count (length items)
            :match-count (length matches)
            :elapsed-ms
            (floor (* 1000 (- end start)) internal-time-units-per-second)))))
