;;;; Declarative transient menu data.
;;;; Handlers are lambdas where load order requires deferred function lookup.

;;; ── +TRANSIENT-DEFINITIONS+ (contract §2/§3) ─────────────────────────────
;;;
;;; KEY -> (TITLE ARGUMENTS ACTIONS).  ARGUMENTS is a list of (ARG-KEY . FLAG);
;;; DESCRIPTION in the rendered view reuses FLAG verbatim (a git flag already
;;; is its own clearest description -- see the Push example in the task
;;; brief, "-f  --force-with-lease"). ACTIONS is a list of (ACTION-KEY
;;; DESCRIPTION HANDLER); DESCRIPTION containing the literal two characters
;;; "~A" is treated as a FORMAT control string interpolating the selected
;;; worktree's branch (%TRANSIENT-ACTION-DISPLAY-DESCRIPTION) -- Push/Pull's
;;; only use of it, to show "push to origin/<branch>" without a separate
;;; per-render templating slot.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter +transient-definitions+
  (list
   (cons #\c
         (list "Commit" nil
               (list (list #\e "amend, keep message"
                           (list :git #\c :commit '("--amend" "--no-edit") nil nil))
                     (list #\c "commit"
                           (list :stub "commit needs a message; no text-prompt UI exists in this build")))))
   (cons #\P
         (list "Push"
               (list (cons #\f "--force-with-lease") (cons #\F "--force"))
               (list (list #\p "push to origin/~A"
                           (list :git #\P :push nil nil '("--force" "--force-with-lease")))
                     (list #\e "push to another remote"
                           (list :stub "remote selection needs a text-prompt UI, not wired in this build")))))
   (cons #\F
         (list "Pull"
               (list (cons #\r "--rebase"))
               (list (list #\p "pull from origin/~A"
                           (list :git #\F :pull nil nil nil)))))
   (cons #\b
         (list "Branch" nil
               (list (list #\l "list branches"
                           (list :git #\b :branch nil nil nil))
                     (list #\- "switch to previous branch"
                           (list :git #\b :switch '("-") nil nil))
                     (list #\c "create branch"
                           (list :stub "branch name needs a text-prompt UI, not wired in this build"))
                     (list #\D "delete branch"
                           (list :stub "branch name needs a text-prompt UI, not wired in this build")))))
   (cons #\m
         (list "Merge" nil
               (list (list #\u "merge upstream (@{u})"
                           (list :git #\m :merge '("@{u}") nil nil))
                     (list #\b "merge another branch"
                           (list :stub "branch name needs a text-prompt UI, not wired in this build")))))
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
                           (list :stub "log view is not wired -- no read pager exists in this build")))))
   (cons #\d
         (list "Diff" nil
               (list (list #\d "show diff"
                           (list :stub "diff view is not wired -- no read pager exists in this build")))))
   (cons #\f
         (list "Fetch" nil
               ;; Wrapped rather than sharp-quoted directly: :CALL hands its
               ;; function (SESSION CONN), and both of these take CONN alone.
               ;; A bare #' here is a wrong-argument-count error at the moment
               ;; the key is struck -- and no gate sees it, because the arity
               ;; only meets the callee through a FUNCALL out of this data
               ;; table. That is how `f` reached this file already broken.
               (list (list #\f "fetch this repository"
                           (list :call (lambda (session conn)
                                         (declare (ignore session))
                                         (%workspace-prefix-fetch-repository conn))))
                     (list #\F "fetch organization"
                           (list :call (lambda (session conn)
                                         (declare (ignore session))
                                         (%workspace-prefix-fetch-organization conn)))))))
   (cons #\t
         (list "Tag" nil
               (list (list #\l "list tags"
                           (list :git #\t :tag nil nil nil))
                     (list #\t "create tag"
                           (list :stub "tag name needs a text-prompt UI, not wired in this build")))))
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
   ;; These four are NOT stubs, and the difference from the name-taking git
   ;; actions above is not effort. Worktree create/delete/lock/unlock already
   ;; had working keys -- `n` `X` `L` `U` -- that the magit alignment retired,
   ;; and every one of those paths avoids a text prompt by design: create
   ;; generates its own branch name (an explicit 2026-08-27 decision against
   ;; prompting for one), and the other three pre-fill the `:` command line,
   ;; which IS the prompt. Stubbing them would have deleted four working
   ;; features while looking like an unfinished new one.
   (cons #\w
         (list "Worktree" nil
               ;; LAMBDA rather than #'%CLIENT-START-WORKTREE-CREATE, and the
               ;; reason is load order: this table is a DEFPARAMETER, so a
               ;; sharp-quote would resolve the fdefinition while this file
               ;; loads -- and these four live in
               ;; server-multi-dispatch-command-input.lisp, which loads AFTER
               ;; this one (the keymap calls %OPEN-CLIENT-TRANSIENT, so it has
               ;; to). A lambda defers the lookup to call time.
               (list (list #\c "create worktree and open its shell"
                           (list :call (lambda (session conn)
                                         (%client-start-worktree-create session conn))))
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
                     (list #\C "create with a chosen branch name"
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
                     (list #\k "help" (list :help))))))
    "KEY -> (TITLE ARGUMENTS ACTIONS); see the section comment above."))
