(in-package #:nerimux/window)

(defmacro define-window-records (&body records)
  "Define the record types that make up the window model."
  `(progn
     ,@(mapcar (lambda (record) `(defstruct ,@record)) records)))

(defconstant +pane-separator-width+ 1
  "Width in cells of the separator drawn between panes in a split layout.")

(defconstant +pane-base-index+ 1
  "First pane id in a window (§1.4: window / pane numbering starts at 1).")

(define-window-records
  (window
   "A named collection of panes with one active (focused) pane.
TREE is the binary split-tree layout. PANES is the derived flat list of leaves,
kept in tree order via window-refresh-panes."
   (id 0 :type fixnum)
   (name "" :type string)
   (width 80 :type fixnum)
   (height 24 :type fixnum)
   (panes nil :type list)
   (active nil)
   (tree nil)
   (local-options (make-hash-table :test #'equal) :type hash-table)
   (zoom-p nil :type boolean)
   (zoom-tree nil)
   (last-active nil)
   (last-active-time 0 :type integer)
   (automatic-rename-p t :type boolean)
   (layout-cycle-index 0 :type fixnum)
   (lock (make-lock :name "window") :read-only t))
  ((%split-spec (:constructor %make-split-spec))
   "Configuration for a window split, collected into one value."
   (no-focus nil)
   (size nil)
   (start-dir nil)
   (before nil)
   (full nil)
   (input-only nil)
   (input-bytes nil)))
