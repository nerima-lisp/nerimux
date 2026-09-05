(in-package #:nerimux/test/vcs)

(defvar *fake-repo-counter*
  0)

(defun %fresh-fake-repo-git-dir ()
  "A repository.git/-shaped directory path (with a trailing slash, as
   %RESOLVE-WORKTREE-PATH's callers already ensure via %ENSURE-TRAILING-SLASH)
   under the temp directory.

   The name has to differ between PROCESSES, not just between calls: these tests
   create real directories and never remove them, and what they assert is which
   suffix is free. RANDOM alone does not give that — SBCL's initial
   *RANDOM-STATE* is fixed, so every process draws the same first number, finds
   the previous run's leftovers, and gets -4 where it expects -2. The clock and
   the process id are what actually vary; the counter keeps calls within one
   process apart."
  (nerimux/vcs::%ensure-trailing-slash
   (namestring
    (merge-pathnames
     (format nil
             "nerimux-worktree-path-test-~D-~D-~D.git/"
             (get-universal-time)
             (sb-posix:getpid)
             (incf *fake-repo-counter*))
     (host-kit:temporary-directory)))))

(describe "renderer-suite/vcs-worktree-path-timestamp-format"

  (it "formats the timestamp token as YYYYMMDDTHHMMSS"
    (let ((token (nerimux/vcs::%timestamp-token)))
      (expect (= 15 (length token)))
      (expect (char= #\T (char token 8)))
      (expect (every #'digit-char-p (remove #\T token))))))

(describe "renderer-suite/vcs-worktree-path-trailing-slash"
          (it "adds a trailing slash only when the directory name lacks one"
              (expect
               (string= "repository/"
                        (nerimux/vcs::%ensure-trailing-slash "repository")))
              (expect
               (string= "repository/"
                        (nerimux/vcs::%ensure-trailing-slash "repository/")))))

(describe "renderer-suite/vcs-worktree-path-no-collision"

  (it "returns the base name verbatim when nothing occupies it yet"
    (let* ((git-dir (%fresh-fake-repo-git-dir))
           (base-name "20260821T130000-abc1234")
           (path (nerimux/vcs::%unique-worktree-path git-dir base-name)))
      (expect (string= (concatenate 'string git-dir ".worktrees/" base-name)
                       path)))))

(describe "renderer-suite/vcs-worktree-path-collision-sequence"

  (it "appends -2, then -3, as each candidate name is already occupied"
    (let* ((git-dir (%fresh-fake-repo-git-dir))
           (base-name "20260821T130000-abc1234"))
      (ensure-directories-exist
       (concatenate 'string git-dir ".worktrees/" base-name "/"))
      (expect (string= (concatenate 'string git-dir ".worktrees/" base-name "-2")
                       (nerimux/vcs::%unique-worktree-path git-dir base-name)))
      (ensure-directories-exist
       (concatenate 'string git-dir ".worktrees/" base-name "-2/"))
      (expect (string= (concatenate 'string git-dir ".worktrees/" base-name "-3")
                       (nerimux/vcs::%unique-worktree-path git-dir base-name)))
      (ensure-directories-exist
       (concatenate 'string git-dir ".worktrees/" base-name "-3/"))
      (expect (string= (concatenate 'string git-dir ".worktrees/" base-name "-4")
                       (nerimux/vcs::%unique-worktree-path git-dir base-name))))))

(describe "renderer-suite/vcs-worktree-path-resolve"

  (it "uses an explicit path verbatim, without touching the filesystem"
    (let* ((repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/explicit-path"
              :local-path (%fresh-fake-repo-git-dir))))
      (expect (string= "/explicit/override/path"
                       (nerimux/vcs::%resolve-worktree-path
                        repository "abc1234" "/explicit/override/path")))))

  (it "generates <repo>.worktrees/<timestamp>-<short-sha> with no explicit path"
    (let* ((git-dir (%fresh-fake-repo-git-dir))
           (repository
             (nerimux/workspace-model:make-repository
              :specification "workspace-owner/generated-path"
              :local-path git-dir))
           (path (nerimux/vcs::%resolve-worktree-path repository "def5678" nil)))
      (expect (search (concatenate 'string git-dir ".worktrees/") path))
      (expect (string= "-def5678" (subseq path (- (length path) 8))))
      (let* ((prefix-length (length (concatenate 'string git-dir ".worktrees/")))
             (timestamp (subseq path prefix-length (+ prefix-length 15))))
        (expect (= 15 (length timestamp)))
        (expect (char= #\T (char timestamp 8)))))))
