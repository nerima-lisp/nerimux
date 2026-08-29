(in-package #:nerimux/layout)

;;; Declarative traversal macros for the binary layout tree.

(defmacro define-layout-visitor (name (node-var) &key on-null on-leaf on-split
                                                       docstring)
  "Define a single-argument recursive layout-tree visitor NAME."
  `(defun ,name (,node-var)
     ,@(when docstring (list docstring))
     (etypecase ,node-var
       (null ,on-null)
       (layout-leaf
        (let ((pane (layout-leaf-pane ,node-var)))
          (declare (ignorable pane))
          ,on-leaf))
       (layout-split
        (let ((first (layout-split-first ,node-var))
              (second (layout-split-second ,node-var))
              (orient (layout-split-orientation ,node-var))
              (ratio (layout-split-ratio ,node-var)))
          (declare (ignorable first second orient ratio))
          ,on-split)))))

(define-layout-visitor layout-leaves (node)
  :docstring "Collect every pane in NODE's subtree, left/top-to-right/bottom."
  :on-null nil
  :on-leaf (list pane)
  :on-split (append (layout-leaves first) (layout-leaves second)))

(defmacro define-layout-fold (name (node-var &rest extra-vars) &key on-null on-leaf
                                                                    on-split docstring)
  "Define a recursive layout-tree function NAME with extra arguments."
  `(defun ,name (,node-var ,@extra-vars)
     ,@(when docstring (list docstring))
     (etypecase ,node-var
       (null ,on-null)
       (layout-leaf
        (let ((leaf-pane (layout-leaf-pane ,node-var)))
          (declare (ignorable leaf-pane))
          ,on-leaf))
       (layout-split
        (let ((split-first (layout-split-first ,node-var))
              (split-second (layout-split-second ,node-var))
              (split-orient (layout-split-orientation ,node-var))
              (split-ratio (layout-split-ratio ,node-var)))
          (declare (ignorable split-first split-second split-orient split-ratio))
          ,on-split)))))

(define-layout-fold layout-min-extent (node orient)
  :docstring "Minimum cells NODE requires along ORIENT's split axis."
  :on-null 0
  :on-leaf (%axis-floor orient)
  :on-split (let ((first-extent (layout-min-extent split-first orient))
                  (second-extent (layout-min-extent split-second orient)))
              (if (eq split-orient orient)
                  (+ first-extent 1 second-extent)
                  (max first-extent second-extent))))

(define-layout-fold layout-find-leaf (node pane)
  :docstring "Return the layout leaf in NODE that holds PANE, or NIL."
  :on-null nil
  :on-leaf (when (eq leaf-pane pane) node)
  :on-split (or (layout-find-leaf split-first pane)
                (layout-find-leaf split-second pane)))
