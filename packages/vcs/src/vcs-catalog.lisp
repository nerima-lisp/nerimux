(in-package #:nerimux/vcs)

(defun vcs-package-available-p ()
  (not (null (find-package :vcs-kit))))

(defun %string-value (value)
  (cond
    ((null value) "")
    ((stringp value) value)
    ((pathnamep value) (namestring value))
    (t (princ-to-string value))))

(defun %strip-control-characters (text)
  "TEXT with every control character removed -- C0 (code < 32), DEL (127) and
C1 (128-159) -- except Tab (9), which becomes a single space (F5,
CWE-150-adjacent). Applies to any text this module retains from an untrusted
VCS invocation before it reaches a renderer: safety there currently rests only
on cl-tui-kit's incidental zero-width-glyph skip, which does not cover every
render path (e.g. the exported plain-ANSI path). Non-string TEXT passes
through unchanged.

C1 is included because the client wire is UTF-8, so a branch name or commit
subject carrying U+009B arrives here as one character rather than a raw byte,
and a terminal decoding UTF-8 then treating C1 as 8-bit control introducers
reads it as CSI. Stripping C0 alone would block `ESC [` and pass its exact
8-bit equivalent."
  (if (stringp text)
      (with-output-to-string (out)
        (loop for character across text
              for code = (char-code character)
              do (cond
                   ((= code 9) (write-char #\Space out))
                   ((or (< code 32) (<= 127 code 159)))
                   (t (write-char character out)))))
      text))

(defun %specification-parts (specification)
  (let ((parts nil)
        (start 0)
        (string (%string-value specification)))
    (loop for
          end = (position #\/ string :start start)
          do (push (subseq string start end) parts)
          if
          end
          do (setf start (1+ end))
          else
            do (return))
    (remove "" (nreverse parts) :test #'string=)))

(defun %organization-and-name (specification)
  (let ((parts (%specification-parts specification)))
    (cond
      ((>= (length parts) 3) (values (first parts) (second parts)))
      ((= (length parts) 2) (values "local" (first parts)))
      ((= (length parts) 1) (values "local" "default"))
      (t (values "local" "default")))))

(defun %repository-from-entry (entry)
  (let* ((specification
          (%string-value (vcs-kit:ghq-repository-entry-specification entry)))
         (path (%string-value (vcs-kit:ghq-repository-entry-path entry)))
         (backend (vcs-kit:ghq-repository-entry-backend entry))
         (host nil)
         (name nil))
    (multiple-value-setq (host name) (%organization-and-name specification))
    (values
     (nerimux/workspace-model:make-organization :id
                                                (nerimux/workspace-model:organization-key
                                                 host
                                                 name)
                                                :host
                                                host
                                                :name
                                                name)
     (nerimux/workspace-model:make-repository :specification
                                              specification
                                              :local-path
                                              path
                                              :backend
                                              (or backend :git)))))

(declaim (ftype function list-repository-worktrees))

(declaim (ftype function %apply-repository-worktrees))

(defvar *ghq-root-cache*
  :unresolved
  "Cached result of VCS-KIT:GHQ-ROOT (FR-002/FR-004b's GHQ-ROOT-DIRECTORY).
   The ghq root does not change once nerimux has started, but
   %RENDER-CLIENT-FRAME calls GHQ-ROOT-DIRECTORY on every dirty frame for the
   empty-catalog hint -- caching here is what keeps that from shelling out to
   `ghq root` on every frame instead of only on the first one.")

(defun ghq-root-directory ()
  "The configured ghq root as a string, or NIL when ghq is unavailable or the
   lookup fails. Bootstrap code uses this domain-facing query rather than
   duplicating ghq-root lookup and failure handling."
  (when (eq *ghq-root-cache* :unresolved)
    (setf *ghq-root-cache* (and (vcs-package-available-p)
                                (handler-case (%string-value (vcs-kit:ghq-root))
                                  (error ()
                                    nil)))))
  *ghq-root-cache*)

(defvar *workspace-organizations*
  nil)

(defun workspace-organizations ()
  "Return the latest workspace catalog used by the global picker."
  (copy-list *workspace-organizations*))

(defun %catalog-worktrees (organizations)
  (loop for organization in organizations
        append (loop for repository in (nerimux/workspace-model:organization-repositories
                                        organization)
                     append (copy-list
                             (nerimux/workspace-model:repository-worktrees
                              repository)))))

(defun %worktree-by-id (worktrees id)
  (find id worktrees :key #'nerimux/workspace-model:worktree-id :test #'string=))

(defun %settle-target-worktree (worktree)
  "Resolve WORKTREE to the struct an async settlement should actually write
onto (F2): WORKTREE itself when it is still reachable from the live
catalog, else the struct in the live catalog now sharing its id (a
LIST-REPOSITORY-WORKTREES rebuild always allocates a fresh struct, even for
an otherwise-unchanged worktree), else WORKTREE itself again when its id is
not present in the catalog at all -- covering a fetch launched before any
catalog was ever published as well as a worktree since deleted, where
WORKTREE is unreachable from the render tree either way and writing onto it
is inert rather than wrong. See REFRESH-WORKTREE-COMMITS-ASYNC's caller in
vcs-inspect.lisp for the race this closes."
  (let ((live (%catalog-worktrees (workspace-organizations))))
    (if (member worktree live :test #'eq)
        worktree
        (or
         (%worktree-by-id live (nerimux/workspace-model:worktree-id worktree))
         worktree))))

(defun %worktree-association-match-p (id path worktree)
  (or
   (and (stringp id)
        (plusp (length id))
        (string= id (nerimux/workspace-model:worktree-id worktree)))
   (and (stringp path)
        (plusp (length path))
        (string= path (nerimux/workspace-model:worktree-path worktree)))))

(defun %remember-pane-associations (organizations)
  (loop for worktree in (%catalog-worktrees organizations)
        append (loop for pane in (nerimux/workspace-model:worktree-panes
                                  worktree)
                     collect (list
                              (nerimux/workspace-model:worktree-id worktree)
                              (nerimux/workspace-model:worktree-path worktree)
                              pane))))

(defun %preserve-pane-associations (previous current)
  (let ((worktrees (%catalog-worktrees current)))
    (dolist (record (%remember-pane-associations previous))
      (destructuring-bind (id path pane) record
        (let ((worktree
               (find-if
                (lambda (candidate)
                  (%worktree-association-match-p id path candidate))
                worktrees)))
          (if worktree
              (progn
                (pushnew pane
                         (nerimux/workspace-model:worktree-panes worktree)
                         :test #'eq)
                (setf (nerimux/pane:pane-worktree pane) worktree))
              (setf (nerimux/pane:pane-worktree pane) nil))))))
  current)

(defun %worktree-by-path (worktrees path)
  (find path
        worktrees
        :key
        #'nerimux/workspace-model:worktree-path
        :test
        #'string=))

(defun %preserve-worktree-state (source target)
  (setf (nerimux/workspace-model:worktree-id target)
        (nerimux/workspace-model:worktree-id source)
        (nerimux/workspace-model:worktree-commits-state target)
        (nerimux/workspace-model:worktree-commits-state source)
        (nerimux/workspace-model:worktree-recent-commits target)
        (nerimux/workspace-model:worktree-recent-commits source)
        (nerimux/workspace-model:worktree-stashes-state target)
        (nerimux/workspace-model:worktree-stashes-state source)
        (nerimux/workspace-model:worktree-stashes target)
        (nerimux/workspace-model:worktree-stashes source)
        (nerimux/workspace-model:worktree-completed-p target)
        (nerimux/workspace-model:worktree-completed-p source)
        (nerimux/workspace-model:worktree-agent-pane target)
        (nerimux/workspace-model:worktree-agent-pane source)
        (nerimux/workspace-model:worktree-waiting-p target)
        (nerimux/workspace-model:worktree-waiting-p source)
        (nerimux/workspace-model:worktree-waiting-time target)
        (nerimux/workspace-model:worktree-waiting-time source)
        (nerimux/workspace-model:worktree-waiting-message target)
        (nerimux/workspace-model:worktree-waiting-message source)
        (nerimux/workspace-model:worktree-waiting-host-notified-p target)
        (nerimux/workspace-model:worktree-waiting-host-notified-p source)))

(defun %preserve-worktree-commit-state (previous current)
  "Carry ID, COMMITS-STATE and RECENT-COMMITS from PREVIOUS's worktrees onto
CURRENT's, matched by path (F1). A full catalog rescan (SCAN-REPOSITORIES)
builds an entirely fresh ORGANIZATION/REPOSITORY/WORKTREE struct per ghq
entry, so %APPLY-REPOSITORY-WORKTREES's own old-worktree lookup -- which
only ever sees worktrees already attached to the SAME repository struct --
never finds a match there, and every full rescan silently dropped any
already-fetched commit history, and let a fresh WORKTREE-KEY-derived id
(which embeds HEAD, see worktree.lisp) replace the one a client, or a
diff/expansion cache keyed on it, may already be holding (F1b). This is
the same shape as %PRESERVE-PANE-ASSOCIATIONS above, run over the same
PREVIOUS/CURRENT pair, but keyed on path alone since a worktree carries no
stable identity of its own before its first publish.

CHANGED-FILES, and likewise its Unit MODEL partition -- STAGED-FILES,
UNSTAGED-FILES, UNTRACKED-FILES, UNMERGED-FILES -- are deliberately NOT
carried here: they come fresh from the status pass that follows every
publish, and carrying a stale value would show a client files the working
tree no longer actually has changed. STASHES/STASHES-STATE, like
COMMITS-STATE/RECENT-COMMITS, ARE carried: nothing in the status pass
repopulates them, they are only ever written by an explicit on-demand
fetch, so without this they would be silently dropped by every full
rescan exactly as commit history was before this function existed."
  (let ((previous-worktrees (%catalog-worktrees previous)))
    (dolist (worktree (%catalog-worktrees current))
      (let ((match
              (%worktree-by-path previous-worktrees
                                 (nerimux/workspace-model:worktree-path worktree))))
        (when match
          (%preserve-worktree-state match worktree)))))
  current)

(defun %valid-worktree-creation-date-p (year month day)
  (and (<= 1 year 9999)
       (<= 1 month 12)
       (let ((days (if (= month 2)
                       (if (and (zerop (mod year 4))
                                (or (not (zerop (mod year 100)))
                                    (zerop (mod year 400))))
                           29 28)
                       (if (member month '(4 6 9 11)) 30 31))))
         (<= 1 day days))))

(defun %worktree-creation-key (worktree)
  (let ((path (nerimux/workspace-model:worktree-path worktree)))
    (unless (stringp path)
      (return-from %worktree-creation-key nil))
    (let* ((trimmed (string-right-trim "/" path))
           (start (1+ (or (position #\/ trimmed :from-end t) -1)))
           (name (subseq trimmed start))
           (length (length name)))
      (unless (and (> length 16)
                   (char= (char name 8) #\T)
                   (char= (char name 15) #\-)
                   (loop for index below 15
                         always (or (= index 8)
                                    (digit-char-p (char name index) 10))))
        (return-from %worktree-creation-key nil))
      (let* ((year (parse-integer name :end 4))
             (month (parse-integer name :start 4 :end 6))
             (day (parse-integer name :start 6 :end 8))
             (hour (parse-integer name :start 9 :end 11))
             (minute (parse-integer name :start 11 :end 13))
             (second (parse-integer name :start 13 :end 15))
             (suffix-start (position #\- name :start 16))
             (sha-end (or suffix-start length)))
        (unless (and (%valid-worktree-creation-date-p year month day)
                     (< hour 24) (< minute 60) (< second 60)
                     (> sha-end 16)
                     (loop for index from 16 below sha-end
                           always (digit-char-p (char name index) 16)))
          (return-from %worktree-creation-key nil))
        (let ((suffix 1))
          (when suffix-start
            (let ((digits-start (1+ suffix-start)))
              (unless (and (< digits-start length)
                           (char/= (char name digits-start) #\0)
                           (loop for index from digits-start below length
                                 always (digit-char-p (char name index) 10)))
                (return-from %worktree-creation-key nil))
              (setf suffix (parse-integer name :start digits-start))
              (unless (>= suffix 2)
                (return-from %worktree-creation-key nil))))
          (cons (+ (* (parse-integer name :end 8) 1000000)
                   (parse-integer name :start 9 :end 15))
                suffix))))))

(defun %worktree-creation-key-newer-p (left right)
  (and left
       (or (null right)
           (> (car left) (car right))
           (and (= (car left) (car right))
                (> (cdr left) (cdr right))))))

(defun %sort-workspace-worktrees-by-creation (organizations)
  (dolist (organization organizations)
    (dolist (repository
             (nerimux/workspace-model:organization-repositories organization))
      (setf (nerimux/workspace-model:repository-worktrees repository)
            (stable-sort
             (copy-list (nerimux/workspace-model:repository-worktrees repository))
             #'%worktree-creation-key-newer-p :key #'%worktree-creation-key))))
  organizations)

(defvar *workspace-catalog-generation* nil)
(defvar *workspace-catalog-generation-lock*
  (cl-concurrent-kit:make-lock :name "workspace-catalog-generation"))

(defstruct (%repository-data-generation
            (:constructor %make-repository-data-generation))
  catalog catalog-generation worktrees)

(defvar *repository-data-generations* (make-hash-table :test #'eq :weakness :key))

(defun %begin-repository-data-generation (repository)
  (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
    (setf (gethash repository *repository-data-generations*)
          (%make-repository-data-generation
           :catalog *workspace-organizations*
           :catalog-generation *workspace-catalog-generation*
           :worktrees (nerimux/workspace-model:repository-worktrees repository)))))

(defun %repository-data-generation-current-p (repository generation &key before-apply)
  (and (eq generation (gethash repository *repository-data-generations*))
       (eq *workspace-organizations* (%repository-data-generation-catalog generation))
       (eq *workspace-catalog-generation*
           (%repository-data-generation-catalog-generation generation))
       (or (not before-apply)
           (eq (nerimux/workspace-model:repository-worktrees repository)
               (%repository-data-generation-worktrees generation)))))

(defun set-workspace-organizations (organizations)
  "Replace the workspace catalog with ORGANIZATIONS and publish a new generation."
  (check-type organizations list)
  (sb-thread:with-recursive-lock (*workspace-catalog-generation-lock*)
    (let ((previous *workspace-organizations*)
          (current (copy-list organizations)))
      (setf *workspace-organizations* current)
      (%preserve-pane-associations previous current)
      (%preserve-worktree-commit-state previous current)
      (setf *workspace-organizations*
            (%sort-workspace-worktrees-by-creation *workspace-organizations*)))))

(defun %repository-already-present-p (repository organizations)
  (let ((local-path (nerimux/workspace-model:repository-local-path repository))
        (specification
         (nerimux/workspace-model:repository-specification repository)))
    (some
     (lambda (organization)
       (find-if
        (lambda (candidate)
          (or
           (and local-path
                (equal local-path
                       (nerimux/workspace-model:repository-local-path candidate)))
           (and specification
                (equal specification
                       (nerimux/workspace-model:repository-specification
                        candidate)))))
        (nerimux/workspace-model:organization-repositories organization)))
     organizations)))

(defun merge-workspace-organizations (organizations)
  "Merge ORGANIZATIONS into *WORKSPACE-ORGANIZATIONS* (FR-002): a wholly new
   organization (by id) is added outright; for one already present, only the
   repositories it does not already hold (matched by local-path or
   specification) are added to it. Existing repositories are left untouched
   -- this exists to make a repository RESOLVE-DIRECTORY-ORGANIZATIONS just
   found visible before the next full scan reaches it, not to refresh
   anything already in the catalog. Goes through SET-WORKSPACE-ORGANIZATIONS
   so pane associations survive the merge the same way every other catalog
   mutation preserves them (%PRESERVE-PANE-ASSOCIATIONS)."
  (when organizations
    (let ((merged (copy-list (workspace-organizations)))
          (additions nil))
      (dolist (organization organizations)
        (let ((existing
               (find (nerimux/workspace-model:organization-id organization)
                     merged
                     :key
                     #'nerimux/workspace-model:organization-id
                     :test
                     #'equal)))
          (if existing
              (dolist
                  (repository
                   (nerimux/workspace-model:organization-repositories
                    organization))
                (unless (%repository-already-present-p repository merged)
                  (nerimux/workspace-model:organization-add-repository existing
                                                                       repository)))
              (push organization additions))))
      (setf merged (nconc merged (nreverse additions)))
      (set-workspace-organizations merged)))
  (workspace-organizations))
