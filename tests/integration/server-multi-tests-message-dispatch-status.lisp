(in-package #:nerimux/test)

(describe "server-multi-status-suite"

  (it "status-view-stage-unstage-and-discard-keys-do-not-crash-the-dispatcher"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree
               ;; u writes only for a staged path and s only for one with
               ;; worktree changes left, so this path carries both.
               (nerimux/workspace-model:make-worktree
                :id "wt-crash-guard" :repository repository
                :path "/tmp/wt-crash-guard" :branch "main"
                :staged-files '(("M" . "src/foo.lisp"))
                :unstaged-files '(("M" . "src/foo.lisp"))))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (calls nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :status
              (nerimux::client-conn-selected-worktree conn) worktree)
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () nil))
             (nerimux/vcs:git-write-operation-async
               (lambda (received-repository operation arguments
                        &key callback-dispatch on-complete on-error)
                 (declare (ignore callback-dispatch on-error))
                 (push (list received-repository operation arguments) calls)
                 (when on-complete (funcall on-complete t ""))
                 t)))
          (dolist (key '("S" "U"))
            (finishes (nerimux::%handle-multi-key-message s conn key)))
          (dolist (key '("s" "u" "k"))
            (nerimux::%set-client-selected-tree-object
             conn (list :file "wt-crash-guard" "src/foo.lisp" " M"))
            (finishes (nerimux::%handle-multi-key-message s conn key))))
        (expect (= 4 (length calls)))
        (expect (every (lambda (call) (eq repository (first call))) calls))
        (expect (eq :confirm (nerimux::client-conn-modal conn)))))))

  (describe "status-view-confirmation-suite"

    (it "status-view-discard-key-confirms-before-writing"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-discard-confirm" :repository repository
                :path "/tmp/wt-discard-confirm" :branch "main"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (calls nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :status
              (nerimux::client-conn-selected-worktree conn) worktree)
        (nerimux::%set-client-selected-tree-object
         conn (list :file "wt-discard-confirm" "src/foo.lisp" " M"))
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p (lambda () nil))
             (nerimux/vcs:git-write-operation-async
               (lambda (received-repository operation arguments
                        &key callback-dispatch on-complete on-error)
                 (declare (ignore callback-dispatch on-error))
                 (push (list received-repository operation arguments) calls)
                 (when on-complete (funcall on-complete t ""))
                 t)))
          (nerimux::%handle-multi-key-message s conn "k")
          (expect (null calls))
          (expect (eq :confirm (nerimux::client-conn-modal conn)))
          (expect (nerimux::client-conn-confirm-action conn))
          (nerimux::%handle-multi-key-message s conn "y")
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (equal (list (list repository :restore (list "--" "src/foo.lisp")))
                         calls)))))))

(defun %make-status-selection-fixture (&key staged unstaged untracked)
  "A status view showing one worktree, with the change lists the keys read."
  (let* ((organization
           (nerimux/workspace-model:make-organization
            :id "org-status" :host "github.com" :name "team-status"))
         (repository
           (nerimux/workspace-model:make-repository
            :id "repo-status" :organization organization
            :specification "github.com/team-status/repo-status"))
         (worktree
           (nerimux/workspace-model:make-worktree
            :id "wt-status" :repository repository
            :path "/tmp/wt-status" :branch "main" :head "main"
            :staged-files staged :unstaged-files unstaged
            :untracked-files untracked))
         (conn (%make-test-conn)))
    (nerimux/workspace-model:organization-add-repository organization repository)
    (nerimux/workspace-model:repository-add-worktree repository worktree)
    (setf (nerimux::client-conn-view conn) :status
          (nerimux::client-conn-selected-worktree conn) worktree)
    (values organization repository worktree conn)))

(defun %select-status-file-row (conn path code)
  "Select PATH's file row the way the status view does -- through
   SELECTED-TREE-OBJECT alone, so SELECTED-WORKTREE keeps naming the view's
   own worktree."
  (setf (nerimux::client-conn-selected-tree-object conn)
        (list :file "wt-status" path code)))

(describe "status-view-write-selection-suite"

  (it "discards a staged change from the index and the worktree"
    (with-fake-session (s)
      (multiple-value-bind (organization repository worktree conn)
          (%make-status-selection-fixture :staged '(("M" . "a.txt")))
        (declare (ignore worktree))
        (let ((nerimux::*clients* (list conn))
              (nerimux/vcs::*workspace-organizations* (list organization))
              (calls nil))
          (%select-status-file-row conn "a.txt" "M")
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () nil))
               (nerimux/vcs:git-write-operation-async
                 (lambda (received-repository operation arguments
                          &key callback-dispatch on-complete on-error)
                   (declare (ignore callback-dispatch on-error))
                   (push (list received-repository operation arguments) calls)
                   (when on-complete (funcall on-complete t ""))
                   t)))
            (nerimux::%handle-multi-key-message s conn "k")
            (expect (string= "git restore --staged --worktree -- a.txt"
                             (nerimux/renderer:confirm-view-operation
                              (nerimux::client-conn-confirm-view conn))))
            (expect (null calls))
            (nerimux::%handle-multi-key-message s conn "y")
            (expect (equal (list (list repository
                                       :restore
                                       (list "--staged" "--worktree"
                                             "--" "a.txt")))
                           calls)))))))

  (it "deletes an untracked file after naming it in the confirmation"
    (with-fake-session (s)
      (multiple-value-bind (organization repository worktree conn)
          (%make-status-selection-fixture
           :untracked '(("??" . "untracked.txt")))
        (declare (ignore worktree))
        (let ((nerimux::*clients* (list conn))
              (nerimux/vcs::*workspace-organizations* (list organization))
              (calls nil))
          (%select-status-file-row conn "untracked.txt" "??")
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () nil))
               (nerimux/vcs:git-write-operation-async
                 (lambda (received-repository operation arguments
                          &key callback-dispatch on-complete on-error)
                   (declare (ignore callback-dispatch on-error))
                   (push (list received-repository operation arguments) calls)
                   (when on-complete (funcall on-complete t ""))
                   t)))
            (nerimux::%handle-multi-key-message s conn "k")
            (expect (string= "delete untracked file"
                             (nerimux/renderer:confirm-view-operation
                              (nerimux::client-conn-confirm-view conn))))
            (expect (equal (cons "path" "untracked.txt")
                           (assoc "path"
                                  (nerimux/renderer:confirm-view-fields
                                   (nerimux::client-conn-confirm-view conn))
                                  :test #'string=)))
            (nerimux::%handle-multi-key-message s conn "y")
            (expect (equal (list (list repository
                                       :clean
                                       (list "-fd" "--" "untracked.txt")))
                           calls)))))))

  (it "refuses to unstage a file that was never staged"
    (with-fake-session (s)
      (multiple-value-bind (organization repository worktree conn)
          (%make-status-selection-fixture
           :untracked '(("??" . "untracked.txt")))
        (declare (ignore repository worktree))
        (let ((nerimux::*clients* (list conn))
              (nerimux/vcs::*workspace-organizations* (list organization))
              (calls nil))
          (%select-status-file-row conn "untracked.txt" "??")
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () nil))
               (nerimux/vcs:git-write-operation-async
                 (lambda (received-repository operation arguments
                          &key callback-dispatch on-complete on-error)
                   (declare (ignore callback-dispatch on-error))
                   (push (list received-repository operation arguments) calls)
                   (when on-complete (funcall on-complete t ""))
                   t)))
            (nerimux::%handle-multi-key-message s conn "u")
            (expect (null calls))
            (expect (string= "nothing to unstage"
                             (first (nerimux::client-conn-message-log conn)))))))))

  (it "reports a row that is already staged instead of staging it again"
    (with-fake-session (s)
      (multiple-value-bind (organization repository worktree conn)
          (%make-status-selection-fixture :staged '(("A" . "new.txt")))
        (declare (ignore repository worktree))
        (let ((nerimux::*clients* (list conn))
              (nerimux/vcs::*workspace-organizations* (list organization))
              (calls nil))
          (%select-status-file-row conn "new.txt" "A")
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () nil))
               (nerimux/vcs:git-write-operation-async
                 (lambda (received-repository operation arguments
                          &key callback-dispatch on-complete on-error)
                   (declare (ignore callback-dispatch on-error))
                   (push (list received-repository operation arguments) calls)
                   (when on-complete (funcall on-complete t ""))
                   t)))
            (nerimux::%handle-multi-key-message s conn "s")
            (expect (null calls))
            (expect (string= "already staged"
                             (first (nerimux::client-conn-message-log conn))))
            (%select-status-file-row conn "new.txt" "A")
            (setf (nerimux/workspace-model:worktree-unstaged-files
                   (nerimux::client-conn-selected-worktree conn))
                  '(("M" . "new.txt")))
            (nerimux::%handle-multi-key-message s conn "s")
            (expect (= 1 (length calls))))))))

  (it "runs a transient git action from the status view's own worktree"
    (with-fake-session (s)
      (multiple-value-bind (organization repository worktree conn)
          (%make-status-selection-fixture :unstaged '(("M" . "g.txt")))
        (declare (ignore worktree))
        (let ((nerimux::*clients* (list conn))
              (nerimux/vcs::*workspace-organizations* (list organization))
              (calls nil))
          (%select-status-file-row conn "g.txt" "M")
          (with-stubbed-fdefinition
              ((nerimux/vcs:vcs-package-available-p (lambda () t))
               (nerimux::%refresh-client-picker
                 (lambda (ignored-connection)
                   (declare (ignore ignored-connection))))
               (nerimux/vcs:git-write-operation-async
                 (lambda (received-repository operation arguments
                          &key callback-dispatch on-complete on-error)
                   (declare (ignore callback-dispatch on-error))
                   (push (list received-repository operation arguments) calls)
                   (when on-complete (funcall on-complete t ""))
                   t)))
            (nerimux::%handle-multi-key-message s conn "F")
            (expect (string= "Pull"
                             (nerimux/renderer:transient-view-title
                              (nerimux::client-conn-transient-view conn))))
            (expect (nerimux/renderer:transient-view-subtitle
                     (nerimux::client-conn-transient-view conn)))
            (nerimux::%handle-multi-key-message s conn "p")
            (expect (equal (list (list repository :pull nil)) calls))))))))
