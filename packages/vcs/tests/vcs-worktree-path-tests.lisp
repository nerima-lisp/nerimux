(in-package #:nerimux/test/vcs)

(defvar *fake-repo-counter*
  0)

(defun %fresh-fake-repo-git-dir ()
  "A repository.git/-shaped directory path (with a trailing slash, as
   %RESOLVE-WORKTREE-PATH's callers already ensure via %ENSURE-TRAILING-SLASH)
   under the temp directory.

   The name has to differ between PROCESSES, not just between calls: these tests
   create real directories and never remove them, and what they assert is which
   suffix is free. RANDOM alone does not give that, SBCL's initial
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

(defun %call-with-worktree-path-repository (function)
  (let* ((root (%fresh-fake-repo-git-dir))
         (source (concatenate 'string root "source/"))
         (bare (concatenate 'string root "repository.git/")))
    (unwind-protect
         (progn
           (uiop:run-program (list "git" "init" "--initial-branch=main" source)
                             :output :string :error-output :string)
           (uiop:run-program
            (list "git" "-C" source "-c" "user.name=Test"
                  "-c" "user.email=test@example.invalid"
                  "-c" "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null"
                  "commit" "--allow-empty" "-m" "fixture")
            :output :string :error-output :string)
           (uiop:run-program (list "git" "clone" "--bare" source bare)
                             :output :string :error-output :string)
           (funcall function
                    (nerimux/workspace-model:make-repository
                     :specification "workspace-owner/path-fixture"
                     :local-path bare)
                    (namestring (truename root))))
      (when (probe-file root)
        (uiop:delete-directory-tree (pathname root) :validate t)))))

(defun %check-created-worktree-path (async-p path-kind)
  (%call-with-worktree-path-repository
   (lambda (repository root)
     (let* ((path (ecase path-kind
                    (:relative "../created/")
                    (:dot (concatenate 'string root "repository.git/../created/"))
                    (:symlink (concatenate 'string root "linked-parent/created/"))
                    (:absolute (concatenate 'string root "created"))))
            (expected-path (concatenate 'string root "created"))
            (created nil)
            (errors nil)
            (completed 0))
       (when (eq path-kind :symlink)
         (uiop:run-program (list "ln" "-s" root
                                 (concatenate 'string root "linked-parent"))
                           :output :string :error-output :string)
         (expect (not (string= path expected-path))))
       (expect (null (probe-file expected-path)))
       (if async-p
           (sb-thread:join-thread
            (nerimux/vcs:create-worktree-async
             repository :branch "path-test" :path path :start-point "HEAD"
             :on-complete (lambda (value) (setf created value) (incf completed))
             :on-error (lambda (condition) (push condition errors))))
           (progn
             (setf created (nerimux/vcs:create-worktree
                            repository :branch "path-test" :path path
                            :start-point "HEAD"))
             (incf completed)))
       (expect (null errors))
       (expect (= 1 completed))
       (expect created)
       (expect (string= expected-path
                        (nerimux/workspace-model:worktree-path created)))
       (expect (eq created (nerimux/workspace-model:repository-worktree-by-path
                            repository expected-path)))
       (expect (string= "path-test"
                        (string-trim '(#\Newline #\Return)
                                     (uiop:run-program
                                      (list "git" "-C" expected-path
                                            "symbolic-ref" "--short" "HEAD")
                                      :output :string :error-output :string))))))))

(describe "renderer-suite/vcs-worktree-path-real-git"
  (it "returns the canonical model for a relative synchronous path"
    (%check-created-worktree-path nil :relative))
  (it "returns the canonical model for a dot-containing synchronous path"
    (%check-created-worktree-path nil :dot))
  (it "returns the canonical model for an absolute synchronous path"
    (%check-created-worktree-path nil :absolute))
  (it "returns the canonical model through a symlink parent synchronously"
    (%check-created-worktree-path nil :symlink))
  (it "returns the canonical model for a relative asynchronous path"
    (%check-created-worktree-path t :relative))
  (it "returns the canonical model for a dot-containing asynchronous path"
    (%check-created-worktree-path t :dot))
  (it "returns the canonical model for an absolute asynchronous path"
    (%check-created-worktree-path t :absolute))
  (it "returns the canonical model through a symlink parent asynchronously"
    (%check-created-worktree-path t :symlink)))
