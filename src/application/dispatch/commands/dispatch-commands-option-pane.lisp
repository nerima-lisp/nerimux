(in-package #:nerimux)

;;;; Loader for the rename/select command family.
;;;; Keep the family split in source files without changing ASDF registration.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (let* ((root (ignore-errors (asdf:system-source-directory :nerimux)))
         (src (or (and root (merge-pathnames #P"src/" root))
                  (and *load-pathname*
                       (host-kit:pathname-directory-pathname *load-pathname*))
                  (and *compile-file-pathname*
                       (host-kit:pathname-directory-pathname *compile-file-pathname*))
                  *default-pathname-defaults*))
         ;; Directory hoisted out of the two LOADs below so that neither source
         ;; line exceeds 100 columns; a #P"..." literal cannot be split.
         (dir (merge-pathnames #P"application/dispatch/commands/" src)))
    (load (merge-pathnames #P"dispatch-commands-option-pane-window.lisp" dir))
    (load (merge-pathnames #P"dispatch-commands-option-pane-pane.lisp" dir))))
