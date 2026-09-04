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
               (nerimux/workspace-model:make-worktree
                :id "wt-crash-guard" :repository repository
                :path "/tmp/wt-crash-guard" :branch "main"))
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
