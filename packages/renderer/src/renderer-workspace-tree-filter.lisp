(in-package #:nerimux/renderer)

(defun %workspace-tree-node-search-text (kind object &optional label)
  "Lowercased text FILTER is matched against for one tree row: label for an
   organization, specification+name for a repository, branch+path for a
   worktree, title+start-command for a pane. Window rows have no fields of
   their own to search, so they fall back to their own label.

   Inline expansion rows match through their own visible text. Diff rows use
   LABEL because their OBJECT contains only stable identity data."
  (string-downcase
   (case kind
     (:organization (%organization-tree-label object))
     (:repository
      (format nil "~A ~A"
              (repository-specification object)
              (%repository-tree-label object)))
     (:worktree
      (format nil "~A ~A"
              (or (worktree-branch object) "")
              (worktree-path object)))
     (:window (%window-tree-label object))
     (:pane
      (format nil "~A ~A" (pane-title object) (pane-start-command object)))
     (:file (format nil "~A ~A" (third object) (fourth object)))
     (:commit
      (format nil "~A ~A"
              (if (stringp (third object)) (third object) "")
              (or (fourth object) "")))
     ((:diff-line :diff-more) (or label ""))
     (t ""))))

(defun %workspace-tree-node-matches-filter-p (kind object
                                                   downcased-filter
                                                   &optional
                                                   label)
  "T when OBJECT's search text contains DOWNCASED-FILTER."
  (and downcased-filter
       (plusp (length downcased-filter))
       (search downcased-filter
               (%workspace-tree-node-search-text kind object label))
       t))

(defun %workspace-filter-tree-entries (entries filter)
  "Keep tree ENTRIES whose own node or a descendant matches FILTER.
   ANCESTORS tracks the pre-order path so a matching row retains its parents."
  (if (or (null filter) (zerop (length (string-trim " " filter))))
      entries
      (let* ((downcased-filter (string-downcase filter))
             (vector (coerce entries 'vector))
             (count (length vector))
             (keep (make-array count :initial-element nil))
             (ancestors nil))
        (dotimes (index count)
          (let* ((entry (aref vector index))
                 (level (first entry)))
            (loop while (and ancestors
                             (>= (first (aref vector (car ancestors))) level))
                  do (pop ancestors))
            (when (%workspace-tree-node-matches-filter-p
                   (fourth entry) (third entry) downcased-filter (second entry))
              (setf (aref keep index) t)
              (dolist (ancestor-index ancestors)
                (setf (aref keep ancestor-index) t)))
            (push index ancestors)))
        (loop for index below count
              when (aref keep index)
                collect (aref vector index)))))
