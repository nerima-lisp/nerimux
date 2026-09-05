(in-package #:nerimux/picker)

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
