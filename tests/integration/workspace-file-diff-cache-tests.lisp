(in-package #:nerimux/test)

(describe "vcs workspace file-diff cache eviction (F4)"
  (it "evicts the oldest entry once a new key would push the cache past its limit"
    (let ((previous-table nerimux::*workspace-file-diffs*)
          (previous-order nerimux::*workspace-file-diffs-order*))
      (unwind-protect
           (let ((limit nerimux::*workspace-file-diffs-cache-limit*))
             (setf nerimux::*workspace-file-diffs* (make-hash-table :test #'equal)
                   nerimux::*workspace-file-diffs-order* nil)
             (dotimes (index (1+ limit))
               (nerimux::%set-workspace-file-diff
                (list "wt-cache" (format nil "file-~D.lisp" index))
                (list :ready index nil)))
             (expect (= limit (hash-table-count nerimux::*workspace-file-diffs*)))
             (expect (null (nth-value 1 (gethash (list "wt-cache" "file-0.lisp")
                                                 nerimux::*workspace-file-diffs*))))
             (loop for index from 1 to limit
                   do (expect (nth-value 1 (gethash (list "wt-cache"
                                                          (format nil "file-~D.lisp" index))
                                                    nerimux::*workspace-file-diffs*)))))
        (setf nerimux::*workspace-file-diffs* previous-table
              nerimux::*workspace-file-diffs-order* previous-order))))

  (it "updating an already-cached key never evicts"
    (let ((previous-table nerimux::*workspace-file-diffs*)
          (previous-order nerimux::*workspace-file-diffs-order*))
      (unwind-protect
           (progn
             (setf nerimux::*workspace-file-diffs* (make-hash-table :test #'equal)
                   nerimux::*workspace-file-diffs-order* nil)
             (nerimux::%set-workspace-file-diff
              (list "wt-cache" "only.lisp") (list :pending 0 nil))
             (nerimux::%set-workspace-file-diff
              (list "wt-cache" "only.lisp") (list :ready 1 "+one line"))
             (expect (= 1 (hash-table-count nerimux::*workspace-file-diffs*)))
             (expect (equal (list :ready 1 "+one line")
                            (gethash (list "wt-cache" "only.lisp")
                                    nerimux::*workspace-file-diffs*))))
        (setf nerimux::*workspace-file-diffs* previous-table
              nerimux::*workspace-file-diffs-order* previous-order))))

  (it "keeps a full table intact when its eviction order is empty"
    (let ((previous-table nerimux::*workspace-file-diffs*)
          (previous-order nerimux::*workspace-file-diffs-order*))
      (unwind-protect
           (let ((limit nerimux::*workspace-file-diffs-cache-limit*)
                 (table (make-hash-table :test #'equal)))
             (dotimes (index limit)
               (setf (gethash (list "wt-cache" (format nil "pre-~D" index)) table)
                     (list :ready index nil)))
             (setf nerimux::*workspace-file-diffs* table
                   nerimux::*workspace-file-diffs-order* nil)
             (nerimux::%set-workspace-file-diff
              (list "wt-cache" "new.lisp") (list :ready limit nil))
             (expect (= (1+ limit)
                        (hash-table-count nerimux::*workspace-file-diffs*))))
        (setf nerimux::*workspace-file-diffs* previous-table
              nerimux::*workspace-file-diffs-order* previous-order)))))
