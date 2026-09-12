(in-package #:nerimux)

(defconstant +max-process-log-entries+
  20
  "Maximum number of process-log entries retained per client.")

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter +transient-definitions+
  (list
   (cons #\c
         (list "Commit" nil
               (list (list #\e "amend, keep message"
                           (list :git #\c :commit '("--amend" "--no-edit") nil nil))
                     (list #\c "commit"
                           (list :prompt :commit-message)))))
   (cons #\P
         (list "Push"
               (list (cons #\f "--force-with-lease") (cons #\F "--force"))
               (list (list #\p "push to upstream"
                           (list :git #\P :push nil nil '("--force" "--force-with-lease")))
                     (list #\e "push to another remote"
                           (list :prompt :remote-push)))))
   (cons #\F
         (list "Pull"
               (list (cons #\r "--rebase"))
               (list (list #\p "pull from upstream"
                           (list :git #\F :pull nil nil nil)))))
   (cons #\b
         (list "Branch" nil
               (list (list #\l "list branches"
                           (list :read-view :branches))
                     (list #\- "switch to previous branch"
                           (list :git #\b :switch '("-") nil nil))
                     (list #\c "create branch"
                           (list :prompt :branch-create))
                     (list #\D "delete branch"
                           (list :prompt :branch-delete)))))
   (cons #\m
         (list "Merge" nil
               (list (list #\u "merge upstream (@{u})"
                           (list :git #\m :merge '("@{u}") nil nil))
                     (list #\b "merge another branch"
                           (list :prompt :merge-branch)))))
   (cons #\r
         (list "Rebase" nil
               (list (list #\u "rebase onto upstream (@{u})"
                           (list :git #\r :rebase '("@{u}") t nil))
                     (list #\a "abort rebase"
                           (list :git #\r :rebase '("--abort") nil nil)))))
   (cons #\z
         (list "Stash" nil
               (list (list #\z "stash changes"
                           (list :git #\z :stash '("push") nil nil))
                     (list #\p "pop latest stash"
                           (list :git #\z :stash '("pop") nil nil)))))
   (cons #\l
         (list "Log" nil
               (list (list #\l "show log"
                           (list :read-view :log)))))
   (cons #\d
         (list "Diff" nil
               (list (list #\d "show diff"
                           (list :read-view :diff)))))
   (cons #\f
         (list "Fetch" nil
               (list (list #\f "fetch this repository"
                           (list :call (lambda (session conn)
                                         (declare (ignore session))
                                         (%workspace-fetch-repository conn))))
                     (list #\F "fetch organization"
                           (list :call (lambda (session conn)
                                         (declare (ignore session))
                                         (%workspace-fetch-organization conn)))))))
   (cons #\t
         (list "Tag" nil
               (list (list #\l "list tags"
                           (list :read-view :tags))
                     (list #\t "create tag"
                           (list :prompt :tag-create)))))
   (cons #\X
         (list "Reset" nil
               (list (list #\s "reset --soft HEAD"
                           (list :git #\X :reset '("--soft" "HEAD") nil nil))
                     (list #\h "reset --hard HEAD"
                           (list :git #\X :reset '("--hard" "HEAD") t nil))
                     (list #\c "clean untracked files (-fd)"
                           (list :git #\X :clean '("-fd") t nil)))))
   (cons #\!
         (list "Shell command" nil
               (list (list #\! "run a shell command"
                           (list :stub "arbitrary shell execution is deliberately not wired -- it is its own trust-boundary decision")))))
   (cons #\w
         (list "Worktree" nil
               (list (list #\c "create worktree and open its shell"
                           (list :call (lambda (session conn)
                                         (%client-start-worktree-create session conn :mode :shell))))
                     (list #\n "create worktree and assign an agent"
                           (list :call (lambda (session conn)
                                         (%client-start-worktree-create session conn))))
                     (list #\a "assign an agent to this worktree"
                           (list :call (lambda (session conn)
                                         (%client-assign-worktree session conn))))
                     (list #\k "delete worktree"
                           (list :call (lambda (session conn)
                                         (declare (ignore session))
                                         (%client-start-worktree-delete conn))))
                     (list #\l "lock worktree"
                           (list :call (lambda (session conn)
                                         (declare (ignore session))
                                         (%client-start-worktree-lock conn))))
                     (list #\u "unlock worktree"
                           (list :call (lambda (session conn)
                                         (declare (ignore session))
                                         (%client-start-worktree-unlock conn))))
                     (list #\C "toggle complete"
                           (list :call (lambda (session conn)
                                         (declare (ignore session))
                                         (%client-complete-workspace conn))))
                     (list #\p "prune this workspace"
                           (list :call (lambda (session conn)
                                         (declare (ignore session))
                                         (%confirm-client-prune-workspaces conn nil))))
                     (list #\P "prune all workspaces"
                           (list :call (lambda (session conn)
                                         (declare (ignore session))
                                         (%confirm-client-prune-workspaces conn t))))
                     (list #\b "create with a chosen branch name"
                           (list :stub "use `: wt-create --branch <name> --confirm`")))))
   (cons #\?
         (list "Dispatch" nil
               (list (list #\c "Commit" (list :open-transient #\c))
                     (list #\P "Push" (list :open-transient #\P))
                     (list #\F "Pull" (list :open-transient #\F))
                     (list #\b "Branch" (list :open-transient #\b))
                     (list #\m "Merge" (list :open-transient #\m))
                     (list #\r "Rebase" (list :open-transient #\r))
                     (list #\z "Stash" (list :open-transient #\z))
                     (list #\l "Log" (list :open-transient #\l))
                     (list #\d "Diff" (list :open-transient #\d))
                     (list #\f "Fetch" (list :open-transient #\f))
                     (list #\t "Tag" (list :open-transient #\t))
                     (list #\X "Reset" (list :open-transient #\X))
                     (list #\! "Shell command" (list :open-transient #\!))
                     (list #\w "Worktree" (list :open-transient #\w))
                     (list #\k "Help (all keys)" (list :help))))))
    "KEY -> (TITLE ARGUMENTS ACTIONS); see the section comment above."))
