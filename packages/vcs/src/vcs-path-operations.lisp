(in-package #:nerimux/vcs)

(defun resolve-path-prefix (path)
  "Resolve existing symlinks in absolute PATH and return the resulting pathname,
preserving any missing suffix. PATH may be a string or pathname. Return NIL
when PATH is relative, a component cannot be resolved, or a `..` component
follows a missing component."
  (let* ((pathname (if (pathnamep path)
                       path
                       (uiop:parse-native-namestring path)))
         (path-string (namestring pathname))
         (separator '(#\/))
         (components (remove-if
                      (lambda (component)
                        (or (string= component "")
                            (string= component ".")))
                      (uiop:split-string path-string :separator separator)))
         (resolved nil)
         (missing-p nil)
         (symlink-count 0))
    (unless (and (plusp (length path-string))
                 (char= (char path-string 0) #\/))
      (return-from resolve-path-prefix nil))
    (loop while components
          for component = (pop components)
          do (cond
               ((string= component "..")
                (when missing-p
                  (return-from resolve-path-prefix nil))
                (setf resolved (cdr resolved)))
               (missing-p
                (push component resolved))
               (t
                (let ((candidate
                        (format nil "/~{~A~^/~}"
                                (append (reverse resolved)
                                        (list component)))))
                  (let ((stat
                          (handler-case
                              (sb-posix:lstat candidate)
                            (sb-posix:syscall-error (condition)
                              (if (= (sb-posix:syscall-errno condition)
                                     sb-posix:enoent)
                                  :missing
                                  (return-from resolve-path-prefix nil))))))
                    (cond
                      ((eq stat :missing)
                       (push component resolved)
                       (setf missing-p t))
                      ((sb-posix:s-islnk (sb-posix:stat-mode stat))
                       (let ((target
                               (handler-case
                                   (sb-posix:readlink candidate)
                                 (sb-posix:syscall-error ()
                                   (return-from resolve-path-prefix nil)))))
                         (when (zerop (length target))
                           (return-from resolve-path-prefix nil))
                         (incf symlink-count)
                         (when (> symlink-count 40)
                           (return-from resolve-path-prefix nil))
                         (when (char= (char target 0) #\/)
                           (setf resolved nil))
                         (setf components
                               (append
                                (remove-if
                                 (lambda (target-component)
                                   (or (string= target-component "")
                                       (string= target-component ".")))
                                 (uiop:split-string target :separator separator))
                                components))))
                      (t
                       (push component resolved))))))))
    (uiop:parse-native-namestring
     (format nil "/~{~A~^/~}" (reverse resolved)))))

(defun path-under-directory-p (path directory)
  "Return true when absolute PATH equals or is below absolute DIRECTORY.
Both arguments may be strings or pathnames and must already be resolved with
RESOLVE-PATH-PREFIX."
  (let* ((path (%string-value path))
         (directory (%string-value directory)))
    (when (and (plusp (length path))
               (plusp (length directory))
               (char= (char path 0) #\/)
               (char= (char directory 0) #\/))
      (let ((path (string-right-trim "/" path))
            (directory (string-right-trim "/" directory)))
        (or (string= path directory)
            (and (> (length path) (length directory))
                 (char= (char path (length directory)) #\/)
                 (string= directory path :end2 (length directory))))))))
