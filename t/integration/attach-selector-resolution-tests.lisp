(in-package #:nerimux/test)

;;;; R7.6: what `nerimux attach <selector>` resolves to.
;;;;
;;;; A selector with a slash reads as a repository specification
;;;; (github.com/org/repo) or as a local path, and a workspace can hold both at
;;;; once. The requirement is that an ambiguous selector opens the picker
;;;; filtered to the candidates rather than silently picking one -- attaching to
;;;; the wrong worktree looks exactly like attaching to the right one until the
;;;; user runs a command in it.

(defun %attach-fixture (&key (specification "github.com/team/widget")
                             worktree-path)
  "An organization holding one repository, and a worktree when PATH is given."
  (let* ((organization (nerimux/model:make-organization
                        :id "org" :host "github.com" :name "team"))
         (repository (nerimux/model:make-repository
                      :id "repo"
                      :organization organization
                      :specification specification)))
    (nerimux/model:organization-add-repository organization repository)
    (when worktree-path
      (nerimux/model:repository-add-worktree
       repository
       (nerimux/model:make-worktree :id "wt"
                                    :repository repository
                                    :path worktree-path
                                    :branch "main")))
    (values (list organization) repository)))

(describe "attach-selector-suite"

  (it "r7-6-a-selector-matching-both-a-repository-and-a-worktree-opens-the-picker"
    (let* ((selector "github.com/team/widget")
           (organizations (%attach-fixture :specification selector
                                           ;; The worktree's path is the very
                                           ;; string that also names the
                                           ;; repository: both readings hit.
                                           :worktree-path selector))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-target conn) selector)
      (let ((resolved (nerimux::%client-attach-selection conn organizations)))
        (expect (null resolved)
                "ambiguous: resolved to nothing rather than guessing")
        (expect (eq :picker (nerimux::client-conn-mode conn)))
        (expect (string= selector (nerimux::client-conn-picker-query conn))
                "the picker opens with the selector already typed"))))

  (it "r7-6-an-unambiguous-worktree-selector-attaches-without-a-picker"
    (let* ((organizations (%attach-fixture :worktree-path "/tmp/only-a-worktree"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-target conn) "/tmp/only-a-worktree")
      (let ((resolved (nerimux::%client-attach-selection conn organizations)))
        (expect resolved)
        (expect (not (eq :picker (nerimux::client-conn-mode conn)))))))

  ;; Before R7.6 this reported "attach target not found" -- the attach path
  ;; matched selectors against worktrees only, so a repository the workspace
  ;; was holding resolved to nothing.
  (it "r7-6-a-repository-selector-with-no-worktree-selects-the-repository"
    (multiple-value-bind (organizations repository)
        (%attach-fixture :specification "github.com/team/widget")
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-attach-target conn) "github.com/team/widget")
        (expect (null (nerimux::%client-attach-selection conn organizations))
                "no worktree to attach to")
        (expect (eq repository (nerimux::%client-tree-object conn))
                "the overview opens on the repository instead of an error")
        (expect (not (eq :picker (nerimux::client-conn-mode conn)))
                "one reading only, so no disambiguation is needed")))))
