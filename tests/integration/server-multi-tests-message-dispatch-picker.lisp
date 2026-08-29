(in-package #:nerimux/test)

;;;; Server multi-client message dispatch tests.

(describe "server-multi-suite"

  (it "picker-arrow-key-bytes-one-at-a-time-do-not-move-the-index"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree-a
               (nerimux/workspace-model:make-worktree
                :id "a" :repository repository :path "/tmp/a" :branch "a"))
             (worktree-b
               (nerimux/workspace-model:make-worktree
                :id "b" :repository repository :path "/tmp/b" :branch "b"))
             (conn (%make-test-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree-a)
        (nerimux/workspace-model:repository-add-worktree repository worktree-b)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (expect (< 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(27)) ; ESC: closes the picker
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(91)) ; [: swallowed
        (nerimux::%handle-multi-key-message s conn #(66)) ; B: swallowed
        (expect (null (nerimux::client-conn-modal conn))
                ))))

  ;; The replacement for those arrow branches. C-p/C-n are used rather than j/k
  ;; because every other key in the picker is a character of the search query --
  ;; a letter that also moved the cursor could not be typed.
  (it "multi-picker-c-p-c-n-move-the-selection"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (worktree-a
               (nerimux/workspace-model:make-worktree
                :id "a" :repository repository :path "/tmp/a" :branch "a"))
             (worktree-b
               (nerimux/workspace-model:make-worktree
                :id "b" :repository repository :path "/tmp/b" :branch "b"))
             (conn (%make-test-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree-a)
        (nerimux/workspace-model:repository-add-worktree repository worktree-b)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items (list organization))
              (nerimux::client-conn-picker-index conn) 0)
        (expect (< 1 (length (nerimux::%client-picker-visible-items conn))))
        (nerimux::%handle-multi-key-message s conn #(14)) ; C-n
        (expect (= 1 (nerimux::client-conn-picker-index conn)))
        (expect (eq :picker (nerimux::client-conn-modal conn))
                )
        (nerimux::%handle-multi-key-message s conn #(16)) ; C-p
        (expect (= 0 (nerimux::client-conn-picker-index conn)))
        (expect (string= "" (nerimux::client-conn-picker-query conn))
                ))))

  (it "multi-picker-selects-a-worktree-pane-in-an-inactive-window"
    (with-fake-session (s :nwindows 2)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/inactive"))
             (conn (%make-test-conn))
             (inactive-window (second (nerimux/session:session-windows s)))
             (pane (nerimux/window:window-active-pane inactive-window)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux/pane:worktree-add-pane worktree pane)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
              (nerimux/picker:build-global-picker-items
               (list organization))
              (nerimux::client-conn-picker-query conn) "feature")
        (expect (nerimux::%select-client-picker-item s conn))
        (expect (eq inactive-window
                    (nerimux/session:session-active-window s)))
        (expect (eq pane (nerimux::client-conn-focus conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "multi-picker-new-window-uses-client-geometry"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org"
                :host "github.com"
                :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo"
                :organization organization
                :specification "github.com/team/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "feature"
                :repository repository
                :path "/tmp/feature"
                :branch "feature/new"))
             (conn (%make-test-conn :rows 17 :cols 63))
             (captured-geometry nil)
             (original-new-window (fdefinition 'nerimux::%workspace-new-window)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux::%set-client-modal conn :picker)
        (setf (nerimux::client-conn-picker-items conn)
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
                       (nerimux/session:session-active-window session)))
               (expect (nerimux::%select-client-picker-item s conn))
               (expect (equal '(17 63) captured-geometry)))
          (setf (fdefinition 'nerimux::%workspace-new-window)
                original-new-window)))))

  (it "picker-query-helpers-reject-invalid-input-and-wrap-selection"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null (nerimux::%set-client-picker-query conn 42)))
        (expect (null (nerimux::%append-client-picker-query-octets
                       conn #(194 32))))
        (expect (null (nerimux::%append-client-picker-query-octets
                       conn #(1))))
        (expect (null (nerimux::%delete-client-picker-query-character conn)))
        (setf (nerimux::client-conn-picker-items conn) nil
              (nerimux::client-conn-picker-index conn) 9)
        (expect (null (nerimux::%move-client-picker-index conn 1)))
        (expect (= 0 (nerimux::client-conn-picker-index conn))))))

  (it "picker-query-helpers-normalize-input-and-handle-control-keys"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (nerimux::%set-client-picker-regex conn :on t))
        (expect (nerimux::%set-client-picker-regex conn "invalid" t))
        (expect (null (nerimux::%set-client-picker-regex conn :off t)))
        (expect (nerimux::%set-client-picker-query conn "ab"))
        (expect (nerimux::%append-client-picker-query-octets conn "c"))
        (expect (string= "abc" (nerimux::client-conn-picker-query conn)))
        (expect (nerimux::%delete-client-picker-query-character conn))
        (expect (string= "ab" (nerimux::client-conn-picker-query conn)))
        (expect (nerimux::%handle-client-picker-key-payload s conn #(18)))
        (expect (null (nerimux::%handle-client-picker-key-payload s conn #(16))))
        (expect (null (nerimux::%handle-client-picker-key-payload s conn #(14))))
        (expect (nerimux::%handle-client-picker-key-payload s conn #(127))))))

  (it "picker-visible-items-deduplicate-worktrees-and-clamp-selection"
    (with-fake-session (s)
      (let* ((worktree (nerimux/workspace-model:make-worktree :id "shared" :path "/tmp/shared"))
             (first-item (nerimux/picker::%make-picker-item
                          :id "first" :kind :worktree :label "first"
                          :worktree worktree))
             (duplicate-item (nerimux/picker::%make-picker-item
                              :id "duplicate" :kind :worktree :label "duplicate"
                              :worktree worktree))
             (organization-item (nerimux/picker::%make-picker-item
                                 :id "organization" :kind :organization
                                 :label "organization"))
             (conn (%make-test-conn)))
        (setf (nerimux::client-conn-picker-items conn)
              (list first-item duplicate-item organization-item)
              (nerimux::client-conn-picker-index conn) 99)
        (let ((visible (nerimux::%client-picker-visible-items conn)))
          (expect (= 2 (length visible)))
          (expect (eq first-item (first visible)))
          (expect (eq organization-item (second visible)))
          (expect (= 1 (nerimux::client-conn-picker-index conn))))
        (setf (nerimux::client-conn-picker-index conn) -4)
        (nerimux::%client-picker-visible-items conn)
        (expect (= 0 (nerimux::client-conn-picker-index conn)))
        (setf (nerimux::client-conn-picker-items conn) nil)
        (nerimux::%client-picker-visible-items conn)
        (expect (= 0 (nerimux::client-conn-picker-index conn))))))

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
