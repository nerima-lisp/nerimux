(in-package #:nerimux/test)

;;;; source-file directive flags, glob expansion, missing-file diagnostics

(describe "config-directives-suite"

  ;;; ── source-file: -q flags, glob patterns, multiple paths ─────────────────────

  ;; %glob-expand returns a non-glob path unchanged as a one-element list.
  (it "glob-expand-passthrough-non-glob"
    (expect (equal '("/etc/foo.conf") (nerimux/config::%glob-expand "/etc/foo.conf"))))

  ;; %glob-expand returns NIL for a glob that matches nothing.
  (it "glob-expand-empty-for-no-matches"
    (expect (null (nerimux/config::%glob-expand "/nonexistent-nerimux-xyz-dir/*.conf"))))

  ;; source-files skips -q/-n/-v flags and ignores missing files under -q.
  (it "source-files-skips-flags-and-tolerates-missing"
    (expect (eq t (nerimux/config:source-files '("-q" "/no/such/nerimux-file.conf")))))

  ;; source-file with a glob loads every matching file; %glob-expand finds them.
  (it "source-files-glob-expands-and-loads-matching-files"
    (let ((dir (host-kit:ensure-directory-pathname
                (merge-pathnames "nerimux-glob-tests/" (host-kit:temporary-directory)))))
      (ensure-directories-exist dir)
      (unwind-protect
           (progn
             (with-open-file (f (merge-pathnames "a.conf" dir)
                                :direction :output :if-exists :supersede)
               (write-line "# nerimux glob test (no global mutation)" f))
             (with-open-file (f (merge-pathnames "b.conf" dir)
                                :direction :output :if-exists :supersede)
               (write-line "# nerimux glob test (no global mutation)" f))
             (let ((matches (nerimux/config::%glob-expand
                             (namestring (merge-pathnames "*.conf" dir)))))
               (expect (= 2 (length matches)))
               (expect (eq t (nerimux/config:source-files
                          (list (namestring (merge-pathnames "*.conf" dir))))))))
        (ignore-errors (host-kit:delete-directory-tree dir :validate t)))))

  ;; source-file on a missing path or unmatched glob (no -q) logs
  ;; 'No such file or directory: PATH' and returns NIL.
  ;; Each row: (path description).
  (it "source-files-missing-path-logs-message-table"
    (dolist (row '(("/no/such/nerimux-srcfile-abc.conf"
                    "plain missing path logs No such file or directory")
                   ("/nonexistent-nerimux-glob-dir/*.conf"
                    "unmatched glob logs No such file or directory")))
      (destructuring-bind (path desc) row
        (declare (ignore desc))
        (let ((nerimux::*message-log* nil))
          (expect (null (nerimux/config:source-files (list path))))
          (expect (= 1 (length nerimux::*message-log*)))
          (expect (search "No such file or directory" (cdr (first nerimux::*message-log*))))
          (expect (search path (cdr (first nerimux::*message-log*))))))))

  ;; With -q, a missing file logs NOTHING (tmux CMD_PARSE_QUIET) and returns T.
  (it "source-files-q-suppresses-missing-file-message"
    (let ((nerimux::*message-log* nil))
      (expect (eq t (nerimux/config:source-files
                 '("-q" "/no/such/nerimux-srcfile-xyz.conf"))))
      (expect (null nerimux::*message-log*))))

  ;; A successfully loaded file produces NO 'missing' diagnostic.
  (it "source-files-existing-file-logs-no-message"
    (with-isolated-config
      (let ((nerimux::*message-log* nil))
        (with-temp-config-file (p "bind z next-window")
          (expect (eq t (nerimux/config:source-files (list (namestring p)))))
          (expect (null nerimux::*message-log*)))))))
