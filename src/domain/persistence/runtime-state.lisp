(in-package #:cl-tmux/persistence)

(defconstant +runtime-snapshot-version+ 1)

(defstruct (runtime-snapshot
            (:constructor %make-runtime-snapshot
                (&key version sessions clients worktrees tags notes)))
  (version +runtime-snapshot-version+ :type integer)
  (sessions nil :type list)
  (clients nil :type list)
  (worktrees nil :type list)
  (tags nil :type list)
  (notes nil :type list))

(defparameter +runtime-snapshot-keys+
  '(:version :sessions :clients :worktrees :tags :notes))

(defun %proper-list-p (value)
  (let ((seen (make-hash-table :test #'eq))
        (cursor value))
    (loop
      (cond
        ((null cursor) (return t))
        ((not (consp cursor)) (return nil))
        ((gethash cursor seen) (return nil))
        (t
         (setf (gethash cursor seen) t
               cursor (cdr cursor)))))))

(defun %runtime-data-p (value &optional (seen (make-hash-table :test #'eq)))
  (cond
    ((or (null value)
         (eq value t)
         (stringp value)
         (numberp value)
         (characterp value)
         (keywordp value))
     t)
    ((consp value)
     (if (gethash value seen)
         nil
         (progn
           (setf (gethash value seen) t)
           (unwind-protect
                (and (%runtime-data-p (car value) seen)
                     (%runtime-data-p (cdr value) seen))
             (remhash value seen)))))
    (t nil)))

(defun %runtime-list-p (value)
  (and (%proper-list-p value)
       (every #'%runtime-data-p value)))

(defun %validate-runtime-list (name value)
  (unless (%runtime-list-p value)
    (error "~A must be a proper reader-safe list, got ~S" name value))
  value)

(defun make-runtime-snapshot (&key (version +runtime-snapshot-version+)
                                   sessions clients worktrees tags notes)
  (unless (and (integerp version)
               (= version +runtime-snapshot-version+))
    (error "Unsupported runtime snapshot version: ~S" version))
  (%make-runtime-snapshot
   :version version
   :sessions (copy-tree (%validate-runtime-list :sessions sessions))
   :clients (copy-tree (%validate-runtime-list :clients clients))
   :worktrees (copy-tree (%validate-runtime-list :worktrees worktrees))
   :tags (copy-tree (%validate-runtime-list :tags tags))
   :notes (copy-tree (%validate-runtime-list :notes notes))))

(defun runtime-snapshot->plist (snapshot)
  (check-type snapshot runtime-snapshot)
  (list :version (runtime-snapshot-version snapshot)
        :sessions (copy-tree (runtime-snapshot-sessions snapshot))
        :clients (copy-tree (runtime-snapshot-clients snapshot))
        :worktrees (copy-tree (runtime-snapshot-worktrees snapshot))
        :tags (copy-tree (runtime-snapshot-tags snapshot))
        :notes (copy-tree (runtime-snapshot-notes snapshot))))

(defun %runtime-snapshot-plist-p (value)
  (and (%proper-list-p value)
       (evenp (length value))
       (let ((seen (make-hash-table :test #'eq)))
         (and
          (loop for (key item) on value by #'cddr
                always
                (and (member key +runtime-snapshot-keys+ :test #'eq)
                     (not (gethash key seen))
                     (setf (gethash key seen) t)
                     (if (eq key :version)
                         (and (integerp item)
                              (= item +runtime-snapshot-version+))
                         (%runtime-list-p item))))
          (every (lambda (key) (gethash key seen))
                 +runtime-snapshot-keys+)))))

(defun serialize-runtime-snapshot (snapshot)
  (check-type snapshot runtime-snapshot)
  (with-output-to-string (stream)
    (let ((*print-readably* t)
          (*print-pretty* nil)
          (*print-circle* nil))
      (write (runtime-snapshot->plist snapshot) :stream stream))))

(defun deserialize-runtime-snapshot (serialized)
  (check-type serialized string)
  (with-input-from-string (stream serialized)
    (let ((*read-eval* nil)
          (eof (gensym "EOF")))
      (let ((value (read stream nil eof)))
        (when (eq value eof)
          (error "Runtime snapshot is empty"))
        (unless (%runtime-snapshot-plist-p value)
          (error "Invalid runtime snapshot schema: ~S" value))
        (unless (eq (read stream nil eof) eof)
          (error "Runtime snapshot contains trailing input"))
        (make-runtime-snapshot
         :version (getf value :version)
         :sessions (getf value :sessions)
         :clients (getf value :clients)
         :worktrees (getf value :worktrees)
         :tags (getf value :tags)
         :notes (getf value :notes))))))

(defun save-runtime-snapshot (snapshot pathname)
  (check-type snapshot runtime-snapshot)
  (check-type pathname (or string pathname))
  (let ((target (pathname pathname)))
    (ensure-directories-exist target)
    (let ((temporary (uiop/stream:tmpize-pathname target)))
      (unwind-protect
           (progn
             (with-open-file (stream temporary
                                     :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create
                                     :external-format :utf-8)
               (write-line (serialize-runtime-snapshot snapshot) stream)
               (finish-output stream))
             (uiop/filesystem:rename-file-overwriting-target temporary target)
             target)
        (when (probe-file temporary)
          (delete-file temporary))))))

(defun load-runtime-snapshot (pathname)
  (check-type pathname (or string pathname))
  (let ((source (probe-file pathname)))
    (when source
      (with-open-file (stream source
                              :direction :input
                              :external-format :utf-8)
        (deserialize-runtime-snapshot
         (with-output-to-string (contents)
           (loop for line = (read-line stream nil nil)
                 while line
                 do (write-line line contents))))))))
