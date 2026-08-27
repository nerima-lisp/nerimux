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
                )
        (expect (eq :picker (nerimux::client-conn-mode conn)))
        (expect (string= selector (nerimux::client-conn-picker-query conn))
                ))))

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
                )
        (expect (eq repository (nerimux::%client-tree-object conn))
                )
        (expect (not (eq :picker (nerimux::client-conn-mode conn)))
                ))))

  ;; cwd auto-selection (kept out of R7.6's scope, unchanged by it) has its own
  ;; containment direction: the worktree's path must be a prefix of cwd, since
  ;; cwd is the client's own directory and may sit anywhere inside a worktree.
  (it "cwd-inside-a-worktree-selects-that-worktree"
    (let* ((nerimux::*last-selected-worktree-token* nil)
           (organizations
             (%attach-fixture
              :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-cwd conn)
            "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1/src")
      (let ((resolved (nerimux::%client-attach-selection conn organizations)))
        (expect resolved)
        (expect (string= "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1"
                         (nerimux/model:worktree-path resolved))))))

  ;; The regression this fixes: testing the prefix in the attach-target
  ;; direction (worktree path as the shorter, cwd-as-token as the prefix
  ;; candidate) let an ANCESTOR of every worktree -- the ghq root, $HOME --
  ;; match every worktree path as a "prefix" of itself and silently
  ;; pre-select whichever worktree the scan reached first.
  (it "cwd-that-is-an-ancestor-of-a-worktree-selects-nothing"
    (let* ((nerimux::*last-selected-worktree-token* nil)
           (organizations
             (%attach-fixture
              :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-cwd conn) "/tmp/nerimux-cwd-fixture")
      (let ((resolved (nerimux::%client-attach-selection conn organizations)))
        (expect (null resolved))
        (expect (null (nerimux::client-conn-selected-worktree conn))))))

  ;; /tmp/.../repo is a string-prefix of /tmp/.../repo-extra, but not a
  ;; directory-prefix -- the boundary check must require the "/" that follows
  ;; a real path component, not just character-wise agreement.
  (it "cwd-sharing-a-string-prefix-with-a-sibling-path-does-not-match"
    (let* ((nerimux::*last-selected-worktree-token* nil)
           (organizations
             (%attach-fixture :worktree-path "/tmp/nerimux-cwd-fixture/repo"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-cwd conn)
            "/tmp/nerimux-cwd-fixture/repo-extra/src")
      (expect (null (nerimux::%client-attach-selection conn organizations)))))

  ;; Worktrees can nest (one's path a prefix of another's); cwd inside both
  ;; must resolve to the more specific -- longest matching path -- one, not
  ;; whichever the scan happens to reach first.
  (it "cwd-inside-a-nested-worktree-selects-the-most-specific-one"
    (let* ((nerimux::*last-selected-worktree-token* nil)
           (organization (nerimux/model:make-organization
                          :id "org" :host "github.com" :name "team"))
           (repository (nerimux/model:make-repository
                        :id "repo"
                        :organization organization
                        :specification "github.com/team/widget"))
           (outer (nerimux/model:make-worktree
                   :id "outer"
                   :repository repository
                   :path "/tmp/nerimux-cwd-fixture/repo/.worktrees/outer"
                   :branch "main"))
           (inner (nerimux/model:make-worktree
                   :id "inner"
                   :repository repository
                   :path "/tmp/nerimux-cwd-fixture/repo/.worktrees/outer/nested"
                   :branch "nested"))
           (conn (%make-test-conn)))
      (nerimux/model:organization-add-repository organization repository)
      (nerimux/model:repository-add-worktree repository outer)
      (nerimux/model:repository-add-worktree repository inner)
      (setf (nerimux::client-conn-attach-cwd conn)
            "/tmp/nerimux-cwd-fixture/repo/.worktrees/outer/nested/deep")
      (let ((resolved
              (nerimux::%client-attach-selection conn (list organization))))
        (expect (eq inner resolved))))))

;;;; FR-002: %client-attach-selection's second value says which of the three
;;;; match kinds resolved the worktree (:explicit / :cwd / :previous, or NIL
;;;; when nothing matched). %client-attach-target needs to know specifically
;;;; that a CWD match is why the worktree was found, so it can jump the
;;;; client straight to the worktree's detail pane only in that case -- an
;;;; :explicit selector or a :previous selection lands on the overview
;;;; instead, per spec.

(describe "attach-selector-source-suite"

  (it "r7-2-source-is-explicit-for-an-explicit-selector-match"
    (let* ((organizations (%attach-fixture :worktree-path "/tmp/only-a-worktree"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-target conn) "/tmp/only-a-worktree")
      (multiple-value-bind (worktree source)
          (nerimux::%client-attach-selection conn organizations)
        (expect worktree)
        (expect (eq :explicit source)))))

  (it "r7-2-source-is-cwd-for-a-cwd-match"
    (let* ((nerimux::*last-selected-worktree-token* nil)
           (organizations
             (%attach-fixture
              :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1"))
           (conn (%make-test-conn)))
      (setf (nerimux::client-conn-attach-cwd conn)
            "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt1/src")
      (multiple-value-bind (worktree source)
          (nerimux::%client-attach-selection conn organizations)
        (expect worktree)
        (expect (eq :cwd source)))))

  ;; No explicit selector, no cwd at all: the only thing left that can match
  ;; is a remembered previous selection (the worktree fixture's id, "wt").
  (it "r7-2-source-is-previous-for-a-remembered-selection-with-no-explicit-or-cwd-match"
    (let* ((organizations (%attach-fixture :worktree-path "/tmp/only-a-worktree"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* "wt"))
      (multiple-value-bind (worktree source)
          (nerimux::%client-attach-selection conn organizations)
        (expect worktree)
        (expect (eq :previous source)))))

  ;; Nothing at all matches: both values come back NIL, not some other
  ;; falsy-but-wrong source keyword.
  (it "r7-2-source-is-nil-when-nothing-matches"
    (let* ((organizations (%attach-fixture :worktree-path "/tmp/only-a-worktree"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* nil))
      (multiple-value-bind (worktree source)
          (nerimux::%client-attach-selection conn organizations)
        (expect (null worktree))
        (expect (null source))))))

(describe "attach-target-cwd-detail-jump-suite"

  ;; FR-002: only a CWD match jumps the client straight to the worktree's
  ;; detail pane -- this drives %client-attach-target itself (not
  ;; %client-attach-selection directly), through a registered *server-
  ;; sessions* entry and a real pane already linked to the worktree, so the
  ;; client-conn-view assertion exercises the actual jump-to-detail path
  ;; (%focus-selected-client-worktree -> %client-worktree-pane -> %set-
  ;; client-focus) rather than assuming %client-attach-selection's source
  ;; value alone is sufficient.
  (it "r7-2-a-cwd-match-through-client-attach-target-jumps-straight-to-detail"
    (let ((nerimux::*last-selected-worktree-token* nil))
      (multiple-value-bind (organizations)
          (%attach-fixture
           :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-cwd")
        (let ((worktree
                (first (nerimux/model:repository-worktrees
                        (first (nerimux/model:organization-repositories
                                (first organizations)))))))
          (multiple-value-bind (session)
              (make-single-pane-session)
            (let ((pane (first (nerimux/model:all-panes session))))
              ;; %focus-selected-client-worktree only takes the direct
              ;; %client-worktree-pane branch (%set-client-focus, which sets
              ;; the :detail view) when the pane is PANE-LIVE-P (fd > 0); a
              ;; not-live pane falls through to %open-client-worktree-pane,
              ;; which does a real WORKTREE-MISSING-P filesystem check this
              ;; fixture's path cannot pass. No PTY I/O happens on this path,
              ;; so a fake positive fd is enough to select the branch under
              ;; test without spawning a real process.
              (setf (nerimux/model:pane-fd pane) 999)
              (nerimux/model:worktree-add-pane worktree pane)
              (let ((conn (%make-test-conn))
                    (nerimux::*server-sessions* (list (cons "0" session)))
                    (nerimux/vcs::*workspace-organizations* organizations))
                (setf (nerimux::client-conn-view conn) :overview)
                (nerimux::%client-attach-target
                 conn (list nil "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-cwd/src"))
                (expect (eq :detail (nerimux::client-conn-view conn))))))))))

  ;; Coverage gap flagged by test/security review: when no session is
  ;; registered at all (*server-sessions* empty -- e.g. attach racing the
  ;; server's own startup, or a request arriving before run-server has
  ;; registered its session), %client-attach-target's own "(and session
  ;; (eq source :cwd))" guard must skip the jump-to-detail branch entirely,
  ;; leaving the client on the overview. Same cwd-match fixture as the test
  ;; above (source resolves to :cwd), but with *server-sessions* bound to
  ;; NIL instead of a registered entry.
  (it "r7-2-a-cwd-match-with-no-registered-session-does-not-jump-to-detail"
    (let ((nerimux::*last-selected-worktree-token* nil))
      (multiple-value-bind (organizations)
          (%attach-fixture
           :worktree-path "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-no-session")
        (let ((conn (%make-test-conn))
              (nerimux::*server-sessions* nil)
              (nerimux/vcs::*workspace-organizations* organizations))
          (setf (nerimux::client-conn-view conn) :overview)
          (nerimux::%client-attach-target
           conn (list nil "/tmp/nerimux-cwd-fixture/repo/.worktrees/wt-no-session/src"))
          (expect (eq :overview (nerimux::client-conn-view conn))))))))
