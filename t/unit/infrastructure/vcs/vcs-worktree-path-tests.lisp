(in-package #:nerimux/test)

;;;; Direct unit tests for %UNIQUE-WORKTREE-PATH / %RESOLVE-WORKTREE-PATH /
;;;; %TIMESTAMP-TOKEN (vcs.lisp:439-479), the R7.2 requirement: a new
;;;; worktree's path is fixed to
;;;;   <repo>.git/.worktrees/<created-time>-<start-point-short-sha>
;;;; (time as %Y%m%dT%H%M%S), and a name collision gets -2, -3, ... appended
;;;; -- %RESOLVE-WORKTREE-PATH's PATH-TEMPLATE argument (mentioned in the
;;;; requirements doc's own before-state snapshot) has already been removed;
;;;; the current signature takes only REPOSITORY, START-POINT-SHORT-SHA, and
;;;; an optional explicit PATH.
;;;;
;;;; %UNIQUE-WORKTREE-PATH uses real PROBE-FILE against the filesystem (not a
;;;; mocked VCS-KIT command), so these tests create real directories under
;;;; HOST-KIT:TEMPORARY-DIRECTORY, the same fixture pattern vcs-tests.lisp's
;;;; "vcs worktree status" suite already uses for a missing-worktree path.
;;;; No PTY, no real git repository -- plain directory creation to simulate
;;;; "a worktree with this name already exists".

(defvar *fake-repo-counter* 0)

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
     (format nil "nerimux-worktree-path-test-~D-~D-~D.git/"
             (get-universal-time)
             (sb-posix:getpid)
             (incf *fake-repo-counter*))
     (host-kit:temporary-directory)))))

(describe "renderer-suite/vcs-worktree-path-timestamp-format"

  ;; %Y%m%dT%H%M%S: 15 characters, digits either side of a literal T at
  ;; index 8 -- exercised against the real current time rather than a fixed
  ;; expected string, since the value is inherently time-dependent.
  (it "formats the timestamp token as YYYYMMDDTHHMMSS"
    (let ((token (nerimux/vcs::%timestamp-token)))
      (expect (= 15 (length token)))
      (expect (char= #\T (char token 8)))
      (expect (every #'digit-char-p (remove #\T token))))))

(describe "renderer-suite/vcs-worktree-path-trailing-slash"

  (it "adds a trailing slash only when the directory name lacks one"
    (expect (string= "repository/"
                     (nerimux/vcs::%ensure-trailing-slash "repository")))
    (expect (string= "repository/"
                     (nerimux/vcs::%ensure-trailing-slash "repository/")))))

(describe "renderer-suite/vcs-worktree-path-no-collision"

  ;; No existing directory of that name: the path is exactly
  ;; <repo-git-dir>.worktrees/<base-name>, no suffix.
  (it "returns the base name verbatim when nothing occupies it yet"
    (let* ((git-dir (%fresh-fake-repo-git-dir))
           (base-name "20260821T130000-abc1234")
           (path (nerimux/vcs::%unique-worktree-path git-dir base-name)))
      (expect (string= (concatenate 'string git-dir ".worktrees/" base-name)
                       path)))))

(describe "renderer-suite/vcs-worktree-path-collision-sequence"

  ;; R7.2's explicit ask: a name collision appends -2; a second collision (on
  ;; both the base name AND -2) appends -3. This is the sequential-numbering
  ;; case the R6/R7 report calls out as required.
  (it "appends -2, then -3, as each candidate name is already occupied"
    (let* ((git-dir (%fresh-fake-repo-git-dir))
           (base-name "20260821T130000-abc1234"))
      (ensure-directories-exist
       (concatenate 'string git-dir ".worktrees/" base-name "/"))
      ;; Only the base name is occupied: -2 is free.
      (expect (string= (concatenate 'string git-dir ".worktrees/" base-name "-2")
                       (nerimux/vcs::%unique-worktree-path git-dir base-name)))
      ;; Occupy -2 as well: -3 is the next free name.
      (ensure-directories-exist
       (concatenate 'string git-dir ".worktrees/" base-name "-2/"))
      (expect (string= (concatenate 'string git-dir ".worktrees/" base-name "-3")
                       (nerimux/vcs::%unique-worktree-path git-dir base-name)))
      ;; Occupy -3: -4 is next. The sequence keeps climbing, not just
      ;; stopping at -3 -- verifying this is not a hard-coded "try up to 2"
      ;; special case.
      (ensure-directories-exist
       (concatenate 'string git-dir ".worktrees/" base-name "-3/"))
      (expect (string= (concatenate 'string git-dir ".worktrees/" base-name "-4")
                       (nerimux/vcs::%unique-worktree-path git-dir base-name))))))

(describe "renderer-suite/vcs-worktree-path-resolve"

  ;; An explicit PATH argument is used verbatim, bypassing collision
  ;; resolution entirely -- this is the "no more PATH-TEMPLATE argument"
  ;; shape R7.2 asks for: only a literal override or the generated name, no
  ;; third templated mode.
  (it "uses an explicit path verbatim, without touching the filesystem"
    (let* ((repository
             (nerimux/model:make-repository
              :specification "workspace-owner/explicit-path"
              :local-path (%fresh-fake-repo-git-dir))))
      (expect (string= "/explicit/override/path"
                       (nerimux/vcs::%resolve-worktree-path
                        repository "abc1234" "/explicit/override/path")))))

  ;; With no explicit path, the resolved path is
  ;; <repo-path>.worktrees/<timestamp>-<short-sha>, ending in the exact
  ;; short-sha suffix given -- and, since nothing occupies it, with no
  ;; numeric suffix appended.
  (it "generates <repo>.worktrees/<timestamp>-<short-sha> with no explicit path"
    (let* ((git-dir (%fresh-fake-repo-git-dir))
           (repository
             (nerimux/model:make-repository
              :specification "workspace-owner/generated-path"
              :local-path git-dir))
           (path (nerimux/vcs::%resolve-worktree-path repository "def5678" nil)))
      (expect (search (concatenate 'string git-dir ".worktrees/") path))
      (expect (string= "-def5678" (subseq path (- (length path) 8))))
      ;; The middle segment (between .worktrees/ and -def5678) is the
      ;; timestamp token: 15 characters, YYYYMMDDTHHMMSS.
      (let* ((prefix-length (length (concatenate 'string git-dir ".worktrees/")))
             (timestamp (subseq path prefix-length (+ prefix-length 15))))
        (expect (= 15 (length timestamp)))
        (expect (char= #\T (char timestamp 8)))))))
