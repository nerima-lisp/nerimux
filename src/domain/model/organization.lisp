(in-package #:nerimux/model)

(defun %model-string (value)
  (cond
    ((null value) "")
    ((stringp value) value)
    ((pathnamep value) (namestring value))
    (t (princ-to-string value))))

(defstruct (organization
            (:constructor %make-organization
                (&key id host name repositories active-worktree-count
                      attention-count missing-p tags notes recent-activity
                      counts-derived-p)))
  (id "" :type string)
  (host "" :type string)
  (name "" :type string)
  (repositories nil :type list)
  (active-worktree-count 0 :type fixnum)
  (attention-count 0 :type fixnum)
  (missing-p nil :type boolean)
  (tags nil :type list)
  (notes "" :type string)
  (recent-activity nil :type list)
  (counts-derived-p nil :type boolean))

(defun organization-key (host name)
  (format nil "~A/~A"
          (if (and host (plusp (length (%model-string host))))
              (%model-string host)
              "local")
          (if (and name (plusp (length (%model-string name))))
              (%model-string name)
              "default")))

(defun make-organization (&key id host name repositories
                             (active-worktree-count 0)
                             (attention-count 0)
                             missing-p tags (notes "") recent-activity)
  (let* ((host-string (%model-string host))
         (name-string (%model-string name)))
    (%make-organization
     :id (or id (organization-key host-string name-string))
     :host host-string
     :name name-string
     :repositories (copy-list repositories)
     :active-worktree-count active-worktree-count
     :attention-count attention-count
     :missing-p (not (null missing-p))
     :tags (copy-list tags)
     :notes (%model-string notes)
     :recent-activity (copy-list recent-activity)
     :counts-derived-p nil)))

(defun organization-repository-count (organization)
  (length (organization-repositories organization)))
