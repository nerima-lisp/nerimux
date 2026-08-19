(in-package #:nerimux)

;;;; Shared dispatch command registry data.
;;;; Loaded by dispatch-core-commands.lisp so the registry stays in one place.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let* ((root (or (ignore-errors (asdf:system-source-directory :nerimux))
                   *load-pathname*
                   *compile-file-pathname*
                   *default-pathname-defaults*))
         (src (merge-pathnames #P"src/" root))
         ;; Directory hoisted out of the LOADs below so that no source line
         ;; exceeds 100 columns; a #p"..." literal cannot be split.
         (core (merge-pathnames #p"application/dispatch/core/" src)))
    (load (merge-pathnames #p"dispatch-command-specs-common.lisp" core))
    (load (merge-pathnames #p"dispatch-command-specs-core-session.lisp" core))
    (load (merge-pathnames #p"dispatch-command-specs-core-window.lisp" core))
    (load (merge-pathnames #p"dispatch-command-specs-core-pane.lisp" core))
    (load (merge-pathnames #p"dispatch-command-specs-core-misc.lisp" core))))

(defun %dispatch-command-specs-core-from-entries (entries)
  (%dispatch-command-specs-from-entries entries #'%make-dispatch-command-spec))

(defparameter *dispatch-command-specs-core*
  (append (%dispatch-command-specs-core-from-entries
           *dispatch-command-specs-core-session-entries*)
          (%dispatch-command-specs-core-from-entries
           *dispatch-command-specs-core-window-entries*)
          (%dispatch-command-specs-core-from-entries
           *dispatch-command-specs-core-pane-entries*)
          (%dispatch-command-specs-core-from-entries
           *dispatch-command-specs-core-misc-entries*)))
