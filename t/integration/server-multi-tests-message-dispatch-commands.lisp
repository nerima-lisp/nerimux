(in-package #:nerimux/test)

(describe "server-multi-command-suite"

  (it "multi-client-ui-command-state-is-private"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (nerimux::%client-ui-keys-p conn))
        (expect (nerimux::%handle-client-ui-command s conn :mode nil '("copy")))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :viewport nil '("3")))
        (expect (= 3 (nerimux::client-conn-viewport conn)))
        (expect (nerimux::%handle-client-ui-command s conn :viewport nil '("-1")))
        (expect (= 2 (nerimux::client-conn-viewport conn)))
        (expect (null (nerimux::%handle-client-ui-command s conn :mode nil '("not-a-mode"))))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :focus nil '("not-a-pane")))
        (expect (nerimux::%handle-client-ui-command s conn :focus nil nil))
        (expect (eq (nerimux::window-active-pane (nerimux::session-active-window s))
                    (nerimux::client-conn-focus conn)))
        (expect (nerimux::%handle-client-ui-command s conn :viewport nil '("bad")))
        (expect (= 0 (nerimux::client-conn-viewport conn)))
        (expect (nerimux::%handle-client-ui-command s conn :cancel nil nil))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :enter-copy nil nil))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :toggle-copy nil nil))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :enter-input nil nil))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect (nerimux::%handle-client-ui-command s conn :enter-normal nil nil))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command s conn :detail nil nil))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect (nerimux::%handle-client-ui-command s conn :home nil nil))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (nerimux::%handle-client-ui-command s conn :tree-scroll nil '("bad")))
        (expect (= 0 (nerimux::client-conn-tree-scroll conn))))))

  (it "ui-command-mode-and-picker-transitions-share-a-small-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)) (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%open-client-picker (lambda (conn) (push :open calls) (setf (nerimux::client-conn-modal conn) :picker)))
             (nerimux::%close-client-picker (lambda (conn session &key keep-view) (declare (ignore session keep-view)) (push :close calls) (setf (nerimux::client-conn-modal conn) nil)))
             (nerimux::%select-client-picker-item (lambda (session conn) (declare (ignore session)) (push :select calls) (setf (nerimux::client-conn-modal conn) nil) t))
             (nerimux::%client-enter-copy-mode (lambda (session conn) (declare (ignore session)) (setf (nerimux::client-conn-modal conn) :scrollback))))
          (expect (nerimux::%handle-client-ui-command s conn :mode nil '("picker")))
          (expect (eq :picker (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :picker-close nil nil))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :mode nil '("picker")))
          (expect (nerimux::%handle-client-ui-command s conn :cancel nil nil))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :mode nil '("picker")))
          (expect (nerimux::%handle-client-ui-command s conn :accept nil nil))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :mode nil '("copy")))
          (expect (eq :scrollback (nerimux::client-conn-modal conn)))
          (dolist (mode '(:normal :input :command :tree-filter)) (expect (nerimux::%handle-client-ui-command s conn mode nil nil)))
          (expect (nerimux::%handle-client-ui-command s conn :copy nil nil))
          (expect (eq :scrollback (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :cancel nil nil))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (equal '(:select :open :close :open :close :open) calls))))))

  (it "ui-command-aliases-preserve-command-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)) (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%client-rebind-prefix (lambda (conn prefix) (declare (ignore conn)) (push (list :prefix prefix) calls)))
             (nerimux::%select-client-tree-relative (lambda (conn delta) (declare (ignore conn)) (push (list :tree delta) calls)))
             (nerimux::%move-client-tree-scroll (lambda (conn delta) (declare (ignore conn)) (push (list :scroll delta) calls))))
          (expect (nerimux::%handle-client-ui-command s conn :prefix-key "C-x" nil))
          (expect (nerimux::%handle-client-ui-command s conn :tree-prev nil '("2")))
          (expect (nerimux::%handle-client-ui-command s conn :tree-next nil nil))
          (expect (nerimux::%handle-client-ui-command s conn :tree-scroll nil '("bad")))
          (expect (equal '((:scroll 1) (:tree 1) (:tree -2) (:prefix "C-x")) calls))))))

  (it "picker-command-actions-share-a-small-dispatch-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)) (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%select-client-picker-item (lambda (session conn) (declare (ignore session conn)) (push :select calls)))
             (nerimux::%refresh-client-picker (lambda (conn) (declare (ignore conn)) (push :refresh calls)))
             (nerimux::%mark-dirty (lambda () (push :dirty calls)))
             (nerimux::%move-client-picker-index (lambda (conn delta) (declare (ignore conn)) (push (list :move delta) calls)))
             (nerimux::%delete-client-picker-query-character (lambda (conn) (declare (ignore conn)) (push :backspace calls)))
             (nerimux::%set-client-picker-query (lambda (conn value) (declare (ignore conn)) (push (list :query value) calls)))
             (nerimux::%set-client-picker-regex (lambda (conn value supplied-p) (declare (ignore conn)) (push (list :regex value supplied-p) calls))))
          (dolist (command '((:picker-accept nil nil) (:picker-refresh nil nil) (:picker-next "2" nil) (:picker-up "2" nil) (:picker-backspace nil nil) (:picker-query "needle" nil) (:picker-query nil ("from-args")) (:picker-regex "pattern" nil) (:picker-regex nil ("from-args"))))
            (destructuring-bind (name target args) command (expect (nerimux::%handle-client-ui-command s conn name target args))))
          (expect (equal '((:regex "from-args" ("from-args")) (:regex "pattern" "pattern") (:query "from-args") (:query "needle") :backspace (:move -2) (:move 2) :dirty :refresh :select) calls)))))))
(describe "server-multi-clone-command-suite"
  (it "registers a repository row and selects its default worktree"
    (with-fake-session (session)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux::*main-thread-callbacks* nil)
             (nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* nil)
             (clone-complete nil)
             (detached-repository nil)
             (worktree
               (nerimux/workspace-model:make-worktree
                :path "/tmp/nerimux-clone-checkout"
                :branch "main")))
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p
               (lambda () t))
             (nerimux/vcs:clone-bare-repository-async
               (lambda (source &key on-start on-complete on-error callback-dispatch)
                 (declare (ignore source on-error))
                 (setf clone-complete on-complete)
                 (funcall callback-dispatch
                          (lambda () (funcall on-start "github.com/team/repository")))))
             (nerimux/vcs:create-detached-worktree-async
               (lambda (repository &key on-start on-complete on-error callback-dispatch)
                 (declare (ignore on-error))
                 (setf detached-repository repository)
                 (funcall callback-dispatch on-start)
                 (funcall callback-dispatch
                          (lambda ()
                            (funcall
                             on-complete
                             (nerimux/vcs::%make-detached-worktree-result
                              :path (nerimux/workspace-model:worktree-path worktree)
                              :head "abc123"
                              :worktree worktree))))))
             (nerimux::%refresh-client-picker
               (lambda (client &key on-complete)
                 (let* ((organizations
                          (list
                           (nerimux/workspace-model:make-organization
                            :host "github.com" :name "team")))
                        (repository
                          (nerimux/workspace-model:make-repository
                           :specification "github.com/team/repository"))
                        (refreshed-worktree
                          (nerimux/workspace-model:make-worktree
                           :id "refreshed-worktree"
                           :path "/private/tmp/nerimux-clone-checkout"
                           :branch "main")))
                   (nerimux/workspace-model:organization-add-repository
                    (first organizations) repository)
                   (nerimux/workspace-model:repository-add-worktree
                    repository refreshed-worktree)
                   (progn
                     (nerimux::%rebind-client-selection client organizations)
                     (nerimux::%set-client-selected-tree-object
                      client :repositories))
                   (when on-complete (funcall on-complete organizations))))))
          (expect (nerimux::%client-clone-repository
                   conn nil '("https://github.com/team/repository")))
          (expect (functionp clone-complete))
          (nerimux::%drain-main-thread-callbacks)
          (let* ((repository
                   (loop for organization in (nerimux/vcs:workspace-organizations)
                         thereis
                         (find "github.com/team/repository"
                               (nerimux/workspace-model:organization-repositories
                                organization)
                               :key #'nerimux/workspace-model:repository-specification
                               :test #'string=)))
                 (job-key (list :repository
                                (nerimux/workspace-model:repository-id repository)
                                :clone))
                 (job (gethash job-key nerimux::*workspace-operation-jobs*))
                 (labels (nerimux::%workspace-job-labels)))
            (expect repository)
            (expect (null (nerimux/workspace-model:repository-worktrees repository)))
            (expect (eq :running (nerimux::workspace-operation-job-state job)))
            (expect (search "clone:running"
                            (gethash (list :repository
                                           (nerimux/workspace-model:repository-id repository))
                                     labels)))
            (nerimux::%enqueue-main-thread-callback
             (lambda ()
               (funcall clone-complete
                        (nerimux/vcs::%make-clone-result
                         :specification "github.com/team/repository"
                         :local-path
                         "/tmp/nerimux-ghq/github.com/team/repository.git"))))
            (nerimux::%drain-main-thread-callbacks)
            (expect (eq repository detached-repository))
            (expect (string=
                     "/tmp/nerimux-ghq/github.com/team/repository.git"
                     (nerimux/workspace-model:repository-local-path repository)))
            (with-stubbed-fdefinition
                ((nerimux::%workspace-canonical-path
                  (lambda (path)
                    (cond
                      ((string= path "/tmp/nerimux-clone-checkout") "/resolved/nerimux-clone-checkout")
                      ((string= path "/private/tmp/nerimux-clone-checkout") "/resolved/nerimux-clone-checkout")
                      (t nil)))))
              (nerimux::%drain-main-thread-callbacks))
            (expect (member worktree
                            (nerimux/workspace-model:repository-worktrees repository)
                            :test #'eq))
            (expect (string= "refreshed-worktree"
                             (nerimux/workspace-model:worktree-id
                              (nerimux::client-conn-selected-worktree
                               conn))))
            (expect (eq :succeeded (nerimux::workspace-operation-job-state job)))
            (expect (null (gethash job-key nerimux::*workspace-operation-jobs*)))
            (expect (search "worktree created"
                            (first (nerimux::client-conn-message-log conn))))))))

  (it "keeps a failed clone visible on its repository row"
    (with-fake-session (session)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux::*main-thread-callbacks* nil)
             (nerimux::*workspace-operation-jobs* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* nil)
             (clone-error-callback nil))
        (with-stubbed-fdefinition
            ((nerimux/vcs:vcs-package-available-p
               (lambda () t))
             (nerimux/vcs:clone-bare-repository-async
               (lambda (source &key on-start on-complete on-error callback-dispatch)
                 (declare (ignore source on-complete))
                 (setf clone-error-callback on-error)
                 (funcall callback-dispatch
                          (lambda ()
                            (funcall on-start "github.com/team/failed-repository"))))))
          (expect (nerimux::%client-clone-repository
                   conn nil '("https://github.com/team/failed-repository")))
          (nerimux::%drain-main-thread-callbacks)
          (let* ((repository
                   (loop for organization in (nerimux/vcs:workspace-organizations)
                         thereis
                         (find "github.com/team/failed-repository"
                               (nerimux/workspace-model:organization-repositories
                                organization)
                               :key #'nerimux/workspace-model:repository-specification
                               :test #'string=)))
                 (job-key (list :repository
                                (nerimux/workspace-model:repository-id repository)
                                :clone)))
            (nerimux::%enqueue-main-thread-callback
             (lambda ()
               (funcall clone-error-callback
                        (make-condition 'nerimux/vcs:clone-error
                                        :reason "transport rejected"))))
            (nerimux::%drain-main-thread-callbacks)
            (let ((job (gethash job-key nerimux::*workspace-operation-jobs*))
                  (label (gethash (list :repository
                                        (nerimux/workspace-model:repository-id repository))
                                  (nerimux::%workspace-job-labels))))
              (expect repository)
              (expect (eq :failed (nerimux::workspace-operation-job-state job)))
              (expect (search "clone:failed transport rejected" label))
              (expect (null (nerimux/workspace-model:repository-worktrees repository)))))))))))
