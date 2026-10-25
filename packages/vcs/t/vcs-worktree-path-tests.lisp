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
    (let* ((directory (concatenate 'string (%fresh-fake-repo-git-dir) ".worktrees/"))
           (base-name "20260821T130000-abc1234")
           (path (nerimux/vcs::%unique-worktree-path directory base-name)))
      (expect (string= (concatenate 'string directory base-name) path)))))

(describe "renderer-suite/vcs-worktree-path-collision-sequence"

  (it "appends -2, then -3, as each candidate name is already occupied"
    (let* ((directory (concatenate 'string (%fresh-fake-repo-git-dir) ".worktrees/"))
           (base-name "20260821T130000-abc1234"))
      (ensure-directories-exist (concatenate 'string directory base-name "/"))
      (expect (string= (concatenate 'string directory base-name "-2")
                       (nerimux/vcs::%unique-worktree-path directory base-name)))
      (ensure-directories-exist (concatenate 'string directory base-name "-2/"))
      (expect (string= (concatenate 'string directory base-name "-3")
                       (nerimux/vcs::%unique-worktree-path directory base-name)))
      (ensure-directories-exist (concatenate 'string directory base-name "-3/"))
      (expect (string= (concatenate 'string directory base-name "-4")
                       (nerimux/vcs::%unique-worktree-path directory base-name))))))

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

(defvar *worktree-path-test-git-environment* nil)

(defun %worktree-path-test-git-environment (bindings)
  (let ((overridden-names
          (append (mapcar #'car bindings)
                  '("GIT_DIR" "GIT_WORK_TREE"))))
    (append
     (remove-if
      (lambda (entry)
        (member (subseq entry 0 (or (position #\= entry) (length entry)))
                overridden-names
                :test #'string=))
      (sb-ext:posix-environ))
     (loop for (name . value) in bindings
           when value
             collect (format nil "~A=~A" name value)))))

(defun %signal-worktree-path-test-git-failure
    (arguments directory exit-code stderr &optional cause)
  (error "~A"
         (nerimux/vcs::%redact-clone-credentials
          (format nil
                  "fixture git failed: argv=~S cwd=~A exit-code=~S stderr=~A~@[ cause=~A~]"
                  arguments
                  (namestring directory)
                  exit-code
                  (or stderr "")
                  cause))))

(defun %run-worktree-path-test-git (arguments)
  (let ((directory (uiop:getcwd)))
    (multiple-value-bind (stdout stderr exit-code)
        (handler-case
            (uiop:run-program arguments
                              :directory directory
                              :environment *worktree-path-test-git-environment*
                              :output :string
                              :error-output :string
                              :ignore-error-status t)
          (error (condition)
            (%signal-worktree-path-test-git-failure
             arguments directory nil "" condition)))
      (unless (eql 0 exit-code)
        (%signal-worktree-path-test-git-failure
         arguments directory exit-code stderr))
      stdout)))

(defun %worktree-path-test-git (directory &rest arguments)
  (string-trim '(#\Newline #\Return)
               (%run-worktree-path-test-git
                (append (list "git" "-C" directory) arguments))))

(defun %call-with-isolated-test-git-environment (function)
  (let* ((root
           (merge-pathnames
            (format nil
                    "nerimux-test-git-environment-~D-~D-~D/"
                    (get-universal-time)
                    (sb-posix:getpid)
                    (incf *fake-repo-counter*))
            (host-kit:temporary-directory)))
         (home (merge-pathnames "home/" root))
         (xdg-config (merge-pathnames "xdg-config/" root))
         (global-config (merge-pathnames "config" root))
         (template-directory (merge-pathnames "templates/" root))
         (bindings
           (list (cons "HOME" (namestring home))
                 (cons "XDG_CONFIG_HOME" (namestring xdg-config))
                 (cons "GIT_CONFIG_GLOBAL" (namestring global-config))
                 (cons "GIT_CONFIG_NOSYSTEM" "1")
                 (cons "GIT_CONFIG_COUNT" "0")
                 (cons "GIT_CONFIG_PARAMETERS" nil)
                 (cons "GIT_TEMPLATE_DIR" (namestring template-directory))))
         (test-environment-update
           (append bindings
                   (quote (("GIT_DIR" . nil)
                           ("GIT_WORK_TREE" . nil)))))
         (environment
           (let ((nerimux/vcs::*worktree-test-environment-update*
                   test-environment-update))
             (%worktree-path-test-git-environment
              (nerimux/vcs::%worktree-operation-environment-update-for-child)))))
    (unwind-protect
         (progn
           (ensure-directories-exist home)
           (ensure-directories-exist xdg-config)
           (ensure-directories-exist template-directory)
           (with-open-file
               (stream global-config :direction :output :if-exists :error :if-does-not-exist :create)
             (declare (ignore stream)))
           (let ((*worktree-path-test-git-environment* environment)
                 (nerimux/vcs::*worktree-test-environment-update*
                   test-environment-update))
             (funcall function)))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))
(defun %call-with-worktree-path-repository (function)
  (%call-with-isolated-test-git-environment
   (lambda ()
     (let* ((root (%fresh-fake-repo-git-dir))
            (source (concatenate (quote string) root "source/"))
            (bare (concatenate (quote string) root "repository.git/")))
       (unwind-protect
            (progn
              (%run-worktree-path-test-git
               (list "git" "init" "--initial-branch=main" source))
              (%run-worktree-path-test-git
               (list "git" "-C" source "-c" "user.name=Test"
                     "-c" "user.email=test@example.invalid"
                     "-c" "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null"
                     "commit" "--allow-empty" "-m" "fixture"))
              (%run-worktree-path-test-git
               (list "git" "clone" "--bare" source bare))
              (let* ((repository
                       (nerimux/workspace-model:make-repository
                        :specification "workspace-owner/path-fixture"
                        :local-path bare))
                     (parent (nerimux/vcs:worktree-parent-directory repository)))
                (ensure-directories-exist (format nil "~Aplaceholder" parent))
                (funcall function repository (namestring (truename root)))))
         (when (probe-file root)
           (uiop:delete-directory-tree (pathname root) :validate t)))))))

(defun %check-created-worktree-path (async-p path-kind)
  (%call-with-worktree-path-repository
   (lambda (repository root)
     (declare (ignore root))
     (let* ((bare (nerimux/workspace-model:repository-local-path repository))
            (parent (nerimux/vcs:worktree-parent-directory repository))
            (linked-parent (concatenate 'string bare "linked-parent"))
            (path (ecase path-kind
                    (:relative ".worktrees/created/")
                    (:dot (concatenate 'string parent "./created/"))
                    (:symlink (concatenate 'string linked-parent "/created/"))
                    (:absolute (concatenate 'string parent "created"))))
            (expected-path (namestring (nerimux/vcs:resolve-path-prefix (concatenate 'string parent "created"))))
            (created nil)
            (errors nil)
            (completed 0))
       (ensure-directories-exist (concatenate 'string parent "placeholder"))
       (when (eq path-kind :symlink)
         (uiop:run-program (list "ln" "-s" parent linked-parent)
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
                        (%worktree-path-test-git expected-path "symbolic-ref" "--short" "HEAD")))))))

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
    (%check-created-worktree-path t :symlink))
  (it "creates and reuses a tracking branch from a remote-only branch"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (let* ((source (concatenate 'string root "source/"))
              (bare (nerimux/workspace-model:repository-local-path repository))
              (branch "feature/remote-only")
              (remote-reference "refs/remotes/origin/feature/remote-only")
              (branch-path
               (namestring
                (nerimux/vcs:resolve-path-prefix
                 (format nil "~Aremote-only-worktree"
                         (nerimux/vcs:worktree-parent-directory
                          repository)))))
              (alternate-path
                 (concatenate 'string
                              (nerimux/vcs:worktree-parent-directory repository)
                              "unused-worktree"))
              (candidates nil)
              (candidate-errors nil)
              (created nil)
              (create-errors nil)
              (reused nil)
              (reuse-errors nil))
         (%worktree-path-test-git source "checkout" "-b" branch)
         (%worktree-path-test-git
          source
          "-c" "user.name=Test"
          "-c" "user.email=test@example.invalid"
          "-c" "commit.gpgsign=false"
          "-c" "core.hooksPath=/dev/null"
          "commit" "--allow-empty" "-m" "remote-only branch fixture")
         (progn
           (%worktree-path-test-git bare "config" "remote.origin.url" source)
           (%worktree-path-test-git
            bare "config" "--replace-all" "remote.origin.fetch"
            "+refs/heads/*:refs/remotes/origin/*"))
         (%worktree-path-test-git
          bare
          "fetch"
          "origin"
          (concatenate 'string
                       "refs/heads/" branch
                       ":refs/remotes/origin/" branch))
         (expect
          (string=
           ""
           (%worktree-path-test-git
            bare
            "for-each-ref"
            "--format=%(refname)"
            "refs/heads/feature/remote-only")))
         (expect
          (string=
           remote-reference
           (%worktree-path-test-git
            bare
            "for-each-ref"
            "--format=%(refname)"
            remote-reference)))
         (sb-thread:join-thread
          (nerimux/vcs:list-worktree-branch-candidates-async
           repository
           :on-complete (lambda (result) (setf candidates result))
           :on-error (lambda (condition) (push condition candidate-errors))))
         (expect (null candidate-errors))
         (let ((candidate
                 (find remote-reference
                       candidates
                       :key (lambda (entry) (getf entry :ref))
                       :test #'string=)))
           (expect candidate)
           (expect (eq :remote (getf candidate :kind)))
           (expect (string= branch (getf candidate :branch)))
           (expect (string= "origin" (getf candidate :remote)))
           (expect (null (getf candidate :worktree))))
         (sb-thread:join-thread
          (nerimux/vcs:create-worktree-async
           repository
           :branch branch
           :path branch-path
           :on-complete (lambda (worktree) (setf created worktree))
           :on-error (lambda (condition) (push condition create-errors))))
         (expect (null create-errors))
         (expect created)
         (expect
          (string=
           branch-path
           (nerimux/workspace-model:worktree-path created)))
         (expect
          (string=
           branch
           (nerimux/workspace-model:worktree-branch created)))
         (expect
          (string=
           branch
           (%worktree-path-test-git branch-path "branch" "--show-current")))
         (expect
          (string=
           "origin/feature/remote-only"
           (%worktree-path-test-git
            branch-path
            "rev-parse"
            "--abbrev-ref"
            "--symbolic-full-name"
            "@{upstream}")))
         (expect
          (string=
           (%worktree-path-test-git bare "rev-parse" remote-reference)
           (%worktree-path-test-git
            bare
            "rev-parse"
            "refs/heads/feature/remote-only")))
         (sb-thread:join-thread
          (nerimux/vcs:create-worktree-async
           repository
           :branch branch
           :path alternate-path
           :on-complete (lambda (worktree) (setf reused worktree))
           :on-error (lambda (condition) (push condition reuse-errors))))
         (expect (null reuse-errors))
         (expect reused)
         (expect
          (string=
           branch-path
           (nerimux/workspace-model:worktree-path reused)))
         (expect (null (probe-file alternate-path))))))))

(defun %call-with-worktree-path-checkout (function)
  "Run FUNCTION on the ordinary checkout that backs the bare fixture."
  (%call-with-worktree-path-repository
   (lambda (bare-repository root)
     (declare (ignore bare-repository))
     (let ((source (concatenate 'string root "source/")))
       (funcall function
                (nerimux/workspace-model:make-repository
                 :specification "workspace-owner/source-fixture"
                 :local-path source)
                source)))))

(describe "renderer-suite/vcs-worktree-parent-directory"

  (it "keeps a bare repository's worktrees inside it"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (expect (string= (concatenate 'string
                                     (nerimux/vcs::%ensure-trailing-slash
                                      (nerimux/workspace-model:repository-local-path
                                       repository))
                                     ".worktrees/")
                        (nerimux/vcs:worktree-parent-directory repository))))))

  (it "keeps a checkout's worktrees in .worktrees by ignoring it locally"
    (%call-with-worktree-path-checkout
     (lambda (repository source)
       (expect (null (nerimux/vcs::%worktrees-directory-ignored-p repository)))
       (expect (string= (concatenate 'string source ".worktrees/")
                        (nerimux/vcs:worktree-parent-directory repository)))
       (expect (nerimux/vcs::%worktrees-directory-ignored-p repository))
       (expect (search ".worktrees/"
                       (uiop:read-file-string
                        (concatenate 'string source ".git/info/exclude"))))
       (expect (string= ""
                        (%worktree-path-test-git source "status" "--short"))))))

  (it "puts a checkout's worktrees beside it when the ignore cannot be written"
    (%call-with-worktree-path-checkout
     (lambda (repository source)
       (with-stubbed-fdefinition
           ((vcs-kit:git-check-ignore
              (lambda (&rest arguments)
                (declare (ignore arguments))
                (error "not ignored"))))
         (expect (string= (concatenate 'string
                                       (string-right-trim "/" source) "-worktrees/")
                          (nerimux/vcs:worktree-parent-directory repository))))))))

(describe "renderer-suite/vcs-default-branch"

  (it "uses the checked-out branch and its local tip when there is no origin"
    (%call-with-worktree-path-checkout
     (lambda (repository source)
       (expect (null (nerimux/vcs::%repository-origin-p repository)))
       (expect (string= "main" (nerimux/vcs::%repository-default-branch repository)))
       (%worktree-path-test-git source "branch" "-m" "trunk")
       (expect (string= "trunk" (nerimux/vcs::%repository-default-branch repository)))
       (expect (string= (%worktree-path-test-git source "rev-parse" "HEAD")
                        (nerimux/vcs::%default-branch-start-point repository)))
       (expect (null (nerimux/vcs::%fetch-default-branch repository "trunk"))))))

  (it "reads the default branch a bare clone's origin/HEAD names"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (expect (nerimux/vcs::%repository-origin-p repository))
       (expect (string= "main" (nerimux/vcs::%repository-default-branch repository)))))))

(describe "vcs worktrees exclude rule"
  (it "detects a .worktrees/ rule already present so it is not appended twice"
    (let ((exclude (merge-pathnames
                    (format nil "nerimux-exclude-test-~D-~D"
                            (sb-posix:getpid) (incf *fake-repo-counter*))
                    (host-kit:temporary-directory))))
      (unwind-protect
           (progn
             (expect (null (nerimux/vcs::%worktrees-exclude-rule-present-p exclude)))
             (with-open-file (stream exclude :direction :output
                                             :if-exists :supersede
                                             :if-does-not-exist :create)
               (write-line "*.log" stream)
               (write-line ".worktrees/" stream))
             (expect (nerimux/vcs::%worktrees-exclude-rule-present-p exclude)))
        (ignore-errors (delete-file exclude))))))

(describe "vcs worktree branch and path integration"
  (it "rejects a remote-qualified name that is also another remote branch name"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (let* ((source (concatenate 'string root "source/"))
              (bare (nerimux/workspace-model:repository-local-path repository))
              (branch-path
                (concatenate 'string
                             (nerimux/vcs:worktree-parent-directory repository)
                             "ambiguous"))
              (completed nil)
              (errors nil))
         (%worktree-path-test-git source "checkout" "-b" "topic")
         (%worktree-path-test-git source "checkout" "main")
         (%worktree-path-test-git source "checkout" "-b" "origin/topic")
         (%worktree-path-test-git bare "config" "remote.origin.url" source)
         (%worktree-path-test-git
          bare "fetch" "origin"
          "refs/heads/topic:refs/remotes/origin/topic"
          "refs/heads/origin/topic:refs/remotes/origin/origin/topic")
         (expect
          (string=
           "refs/remotes/origin/topic"
           (%worktree-path-test-git bare "for-each-ref" "--format=%(refname)"
                            "refs/remotes/origin/topic")))
         (expect
          (string=
           "refs/remotes/origin/origin/topic"
           (%worktree-path-test-git bare "for-each-ref" "--format=%(refname)"
                            "refs/remotes/origin/origin/topic")))
         (sb-thread:join-thread
          (nerimux/vcs:create-worktree-async
           repository :branch "origin/topic" :path branch-path
           :on-complete (lambda (worktree) (setf completed worktree))
           :on-error (lambda (condition) (push condition errors))))
         (expect (null completed))
         (expect (first errors))
         (expect
          (string=
           ""
           (%worktree-path-test-git bare "for-each-ref" "--format=%(refname)"
                            "refs/heads/origin/topic")))
         (expect (null (probe-file branch-path))))))
  )
  (it "creates an unmatched branch and worktree with the requested start point"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (let* ((bare (nerimux/workspace-model:repository-local-path repository))
              (branch "feature/unmatched-integration")
              (branch-path
                (concatenate 'string
                             (nerimux/vcs:worktree-parent-directory repository)
                             "unmatched"))
              (created nil)
              (errors nil))
         (sb-thread:join-thread
          (nerimux/vcs:create-worktree-async
           repository :branch branch :path branch-path :start-point "HEAD"
           :on-complete (lambda (worktree) (setf created worktree))
           :on-error (lambda (condition) (push condition errors))))
         (expect (null errors))
         (expect created)
         (expect (string= branch
                          (nerimux/workspace-model:worktree-branch created)))
         (expect
          (string=
           (concatenate 'string "refs/heads/" branch)
           (%worktree-path-test-git bare "for-each-ref" "--format=%(refname)"
                            (concatenate 'string "refs/heads/" branch))))
         (expect
          (string=
           ""
           (%worktree-path-test-git bare "for-each-ref" "--format=%(upstream)"
                            (concatenate 'string "refs/heads/" branch)))))))
  )
  (it "rejects empty and outside paths before creating branches"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (let* ((bare (nerimux/workspace-model:repository-local-path repository))
              (empty-errors nil)
              (outside-errors nil))
         (sb-thread:join-thread
          (nerimux/vcs:create-worktree-async
           repository :branch "empty-path" :path "" :start-point "HEAD"
           :on-complete (lambda (worktree) (declare (ignore worktree)))
           :on-error (lambda (condition) (push condition empty-errors))))
         (sb-thread:join-thread
          (nerimux/vcs:create-worktree-async
           repository :branch "outside-path"
           :path (concatenate 'string root "outside-worktree")
           :start-point "HEAD"
           :on-complete (lambda (worktree) (declare (ignore worktree)))
           :on-error (lambda (condition) (push condition outside-errors))))
         (expect (first empty-errors))
         (expect (first outside-errors))
         (dolist (branch '("empty-path" "outside-path"))
           (expect
            (string=
             ""
             (%worktree-path-test-git
              bare "for-each-ref" "--format=%(refname)"
              (concatenate 'string "refs/heads/" branch)))))))))
  (it "removes a newly created branch when attaching its worktree fails"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (let* ((bare (nerimux/workspace-model:repository-local-path repository))
              (parent (nerimux/vcs:worktree-parent-directory repository))
              (branch "feature/failed-attachment")
              (branch-path (concatenate 'string parent "occupied"))
              (marker (concatenate 'string branch-path "/marker"))
              (errors nil))
         (ensure-directories-exist marker)
         (with-open-file (stream marker :direction :output :if-exists :supersede)
           (write-line "fixture" stream))
         (sb-thread:join-thread
          (nerimux/vcs:create-worktree-async
           repository :branch branch :path branch-path :start-point "HEAD"
           :on-complete (lambda (worktree) (declare (ignore worktree)))
           :on-error (lambda (condition) (push condition errors))))
         (expect (first errors))
         (expect
          (string=
           ""
           (%worktree-path-test-git bare "for-each-ref" "--format=%(refname)"
                            (concatenate 'string "refs/heads/" branch))))
         (expect (string= "fixture"
                          (string-right-trim '(#\Newline #\Return)
                                              (uiop:read-file-string marker))))
         (expect (not (probe-file
                       (concatenate 'string branch-path "/.git")))))))
  (it "fails candidate reads rather than parsing a capped ref listing"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (declare (ignore root))
       (let* ((bare (nerimux/workspace-model:repository-local-path repository))
              (remote-output (%worktree-path-test-git bare "remote"))
              (ref-output
                (%worktree-path-test-git
                 bare "for-each-ref" "--format=%(refname)%00%(symref)"
                 "refs/heads/" "refs/remotes/"))
              (limit (1+ (length remote-output)))
              (nerimux/vcs::*git-read-output-limit* limit)
              (condition-seen nil))
         (expect (> (length ref-output) limit))
         (handler-case
             (nerimux/vcs::%read-worktree-branch-candidates repository)
           (error (condition)
             (setf condition-seen condition)))
         (expect (typep condition-seen 'nerimux/vcs::%git-read-error)))))))

)

(describe "vcs exported canonical path helpers"
  (it "resolves symlinks and preserves an unresolved suffix"
    (let* ((root (%fresh-fake-repo-git-dir))
           (target (concatenate 'string root "target/"))
           (link (concatenate 'string root "link"))
           (resolved nil))
      (unwind-protect
           (progn
             (ensure-directories-exist (concatenate 'string target "marker"))
             (uiop:run-program (list "ln" "-s" target link)
                               :output :string :error-output :string)
             (setf resolved
                   (nerimux/vcs:resolve-path-prefix
                    (concatenate 'string link "/missing/child")))
             (expect (pathnamep resolved))
             (expect
              (string=
               (concatenate
                'string
                (namestring (uiop:ensure-directory-pathname (truename target)))
                "missing/child")
               (namestring resolved))))
        (when (probe-file root)
          (uiop:delete-directory-tree (pathname root) :validate t)))))
  (it "checks path containment on directory boundaries"
    (expect (nerimux/vcs:path-under-directory-p
             "/ghq/owner/project" "/ghq"))
    (expect (nerimux/vcs:path-under-directory-p
             "/ghq" "/ghq"))
    (expect (null (nerimux/vcs:path-under-directory-p
                   "/ghq-other/project" "/ghq")))
    (expect (null (nerimux/vcs:path-under-directory-p
                   "relative/project" "/ghq")))))
(describe "vcs remote candidate checkout identity"
          (it "reuses only a checkout tracking the selected remote ref"
              (%call-with-worktree-path-repository
               (lambda (repository root)
                 (let* ((source (concatenate 'string root "source/"))
                        (bare (nerimux/workspace-model:repository-local-path repository))
                        (worktree-path
                         (concatenate 'string
                                      (nerimux/vcs:worktree-parent-directory repository)
                                      "foo-checkout"))
                        (candidates nil)
                        (errors nil))
                   (%worktree-path-test-git source "checkout" "-b" "foo")
                   (%worktree-path-test-git
                    source
                    "-c" "user.name=Test"
                    "-c" "user.email=test@example.invalid"
                    "-c" "commit.gpgsign=false"
                    "-c" "core.hooksPath=/dev/null"
                    "commit" "--allow-empty" "-m" "remote checkout identity fixture")
                   (dolist (remote '("origin" "upstream"))
                     (if (string= remote "origin")
                         (%worktree-path-test-git bare "remote" "set-url" remote source)
                       (%worktree-path-test-git bare "remote" "add" remote source))
                     (%worktree-path-test-git
                      bare "config" "--replace-all"
                      (format nil "remote.~A.fetch" remote)
                      (format nil "+refs/heads/*:refs/remotes/~A/*" remote))
                     (%worktree-path-test-git
                      bare "fetch" remote
                      (format nil "refs/heads/foo:refs/remotes/~A/foo" remote)))
                   (%worktree-path-test-git bare "branch" "foo" "refs/remotes/origin/foo")
                   (%worktree-path-test-git bare "config" "branch.foo.remote" "origin")
                   (%worktree-path-test-git bare "config" "branch.foo.merge" "refs/heads/foo")
                   (%worktree-path-test-git bare "worktree" "add" worktree-path "foo")
                   (sb-thread:join-thread
                    (nerimux/vcs:list-worktree-branch-candidates-async
                     repository
                     :on-complete (lambda (result) (setf candidates result))
                     :on-error (lambda (condition) (push condition errors))))
                   (expect (null errors))
                   (let ((origin-candidate
                          (find "refs/remotes/origin/foo" candidates
                                :key (lambda (entry) (getf entry :ref))
                                :test #'string=))
                         (upstream-candidate
                          (find "refs/remotes/upstream/foo" candidates
                                :key (lambda (entry) (getf entry :ref))
                                :test #'string=)))
                     (expect origin-candidate)
                     (expect upstream-candidate)
                     (expect
                      (string= (namestring (nerimux/vcs:resolve-path-prefix worktree-path)) (nerimux/workspace-model:worktree-path (getf origin-candidate :worktree))))
                     (expect (null (getf upstream-candidate :worktree)))))))))
(describe "vcs remote branch name collision"
  (it "explains when a qualified remote branch conflicts with an untracked local branch"
    (%call-with-worktree-path-repository
     (lambda (repository root)
       (let* ((source (concatenate 'string root "source/"))
              (bare (nerimux/workspace-model:repository-local-path repository))
              (branch-path (concatenate 'string
                                        (nerimux/vcs:worktree-parent-directory repository)
                                        "foo-checkout"))
              (errors nil)
              (created nil))
         (%worktree-path-test-git source "checkout" "-b" "foo")
         (%worktree-path-test-git
          source
          "-c" "user.name=Test"
          "-c" "user.email=test@example.invalid"
          "-c" "commit.gpgsign=false"
          "-c" "core.hooksPath=/dev/null"
          "commit" "--allow-empty" "-m" "remote foo fixture")
         (%worktree-path-test-git bare "remote" "set-url" "origin" source)
         (%worktree-path-test-git
          bare "config" "--replace-all" "remote.origin.fetch"
          "+refs/heads/*:refs/remotes/origin/*")
         (%worktree-path-test-git bare "fetch" "origin" "refs/heads/foo:refs/remotes/origin/foo")
         (%worktree-path-test-git bare "branch" "foo")
         (expect
          (string=
           "refs/heads/foo"
           (%worktree-path-test-git bare "for-each-ref" "--format=%(refname)"
                            "refs/heads/foo")))
         (expect
          (string=
           ""
           (%worktree-path-test-git bare "for-each-ref" "--format=%(upstream)"
                            "refs/heads/foo")))
         (sb-thread:join-thread
          (nerimux/vcs:create-worktree-async
           repository
           :branch "origin/foo"
           :path branch-path
           :on-complete (lambda (worktree) (setf created worktree))
           :on-error (lambda (condition) (push condition errors))))
         (expect (null created))
         (expect (first errors))
         (expect (string= "Cannot create a worktree from remote branch origin/foo because local branch foo already exists. Select foo to use the local branch, or rename/remove it first." (princ-to-string (first errors))))
         (expect (null (probe-file branch-path)))
         (expect
          (string=
           "refs/remotes/origin/foo"
           (%worktree-path-test-git bare "for-each-ref" "--format=%(refname)"
                            "refs/remotes/origin/foo"))))))))

