(in-package #:nerimux/test)

;;;; Server multi-client message dispatch tests.

(describe "server-multi-suite"

  (it "picker-arrow-key-bytes-one-at-a-time-do-not-move-the-index"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree-a
               (nerimux/model:make-worktree
                :id "a" :repository repository :path "/tmp/a" :branch "a"))
             (worktree-b
               (nerimux/model:make-worktree
                :id "b" :repository repository :path "/tmp/b" :branch "b"))
             (conn (%make-test-conn)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree-a)
        (nerimux/model:repository-add-worktree repository worktree-b)
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (expect (< 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC: closes the picker
        (expect (eq :normal (nerimux::client-conn-mode conn)))
        (nerimux::%handle-multi-key-message s conn #(91)) ; [: swallowed
        (nerimux::%handle-multi-key-message s conn #(66)) ; B: swallowed
        (expect (eq :normal (nerimux::client-conn-mode conn))
                ))))

  ;; The replacement for those arrow branches. C-p/C-n are used rather than j/k
  ;; because every other key in the picker is a character of the search query --
  ;; a letter that also moved the cursor could not be typed.
  (it "multi-picker-c-p-c-n-move-the-selection"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree-a
               (nerimux/model:make-worktree
                :id "a" :repository repository :path "/tmp/a" :branch "a"))
             (worktree-b
               (nerimux/model:make-worktree
                :id "b" :repository repository :path "/tmp/b" :branch "b"))
             (conn (%make-test-conn)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree-a)
        (nerimux/model:repository-add-worktree repository worktree-b)
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (expect (< 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(14)) ; C-n
        (expect (= 1 (nerimux::client-conn-picker-index conn)))
        (expect (eq :picker (nerimux::client-conn-mode conn))
                )
        (nerimux::%handle-multi-key-message s conn #(16)) ; C-p
        (expect (= 0 (nerimux::client-conn-picker-index conn)))
        (expect (string= "" (nerimux::client-conn-picker-query conn))
                ))))

  (it "multi-picker-selects-a-worktree-pane-in-an-inactive-window"
    (with-fake-session (s :nwindows 2)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/inactive"))
             (conn (%make-test-conn))
             (inactive-window (second (nerimux/model:session-windows s)))
             (pane (nerimux/model:window-active-pane inactive-window)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (nerimux/model:worktree-add-pane worktree pane)
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-query conn) "feature")
        (expect (nerimux::%select-client-picker-item s conn))
        (expect (eq inactive-window
                    (nerimux/model:session-active-window s)))
        (expect (eq pane (nerimux::client-conn-focus conn)))
        (expect (eq :normal (nerimux::client-conn-mode conn))))))

  (it "multi-picker-new-window-uses-client-geometry"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/new"))
             (conn (%make-test-conn :rows 17 :cols 63))
             (captured-geometry nil)
             (original-new-window (fdefinition 'nerimux::%workspace-new-window)))
        (nerimux/model:organization-add-repository organization repository)
        (nerimux/model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-mode conn) :picker
              (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-query conn) "feature")
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux::%workspace-new-window)
                     (lambda (session &rest args)
                       (declare (ignore args))
                       (setf captured-geometry
                             (list nerimux::*term-rows* nerimux::*term-cols*))
                       (nerimux/model:session-active-window session)))
               (expect (nerimux::%select-client-picker-item s conn))
               (expect (equal '(17 63) captured-geometry)))
          (setf (fdefinition 'nerimux::%workspace-new-window)
                original-new-window)))))

  ;; The workspace->tmux command vocabulary translation
  ;; (%canonical-client-command: :close -> :kill-pane, :split -> :split-window,
  ;; and so on) was deleted with the tmux command table it fed.  Its only
  ;; consumer was %dispatch-forwarded-command; once that went, the translation
  ;; had nothing to translate for, and this test was the only thing still
  ;; calling it.

  ;; A resize updates the resized client's own geometry and immediately
  ;; re-applies the effective shared size, which §1.4 / R8.4 fix to the
  ;; smallest attached client — not the just-resized one.  window-size
  ;; "latest" (and "largest"/"manual") went away with domain/options (R2.2).
)
