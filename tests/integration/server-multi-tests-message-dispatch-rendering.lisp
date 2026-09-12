(in-package #:nerimux/test)

(describe "server-multi-rendering-suite"

  (it "multi-handle-resize-updates-conn-and-effective-size"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn :rows 24 :cols 80))
             (nerimux::*clients* (list conn))
             (payload (nerimux/protocol::u16-octets-pair 40 100)))
        (nerimux::%handle-multi-client-message nerimux::+msg-resize+ payload s conn)
        (check-table (list (list (nerimux::client-conn-rows conn) 40 "conn rows updated from the resize")
                           (list (nerimux::client-conn-cols conn) 100 "conn cols updated from the resize")
                           (list nerimux::*term-rows* 40 "effective rows applied to *term-rows*")
                           (list nerimux::*term-cols* 100 "effective cols applied to *term-cols*"))))))

  (it "multi-render-keeps-client-frame-and-ui-state-independent"
    (with-fake-session (s)
      (let ((wide (%make-test-conn :rows 10 :cols 40))
            (narrow (%make-test-conn :rows 6 :cols 20))
            (renderer (fdefinition 'nerimux/renderer:render-session-to-string))
            (calls nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/renderer:render-session-to-string)
                     (lambda (session rows cols &key focus-pane viewport mode
                                           messages
                                           picker-items picker-query picker-index
                                           picker-regex-p command-buffer)
                       (declare (ignore session))
                       (declare (ignore messages picker-items picker-query
                                        picker-index picker-regex-p
                                        command-buffer))
                       (push (list rows cols focus-pane viewport mode) calls)
                       (make-string (* rows cols) :initial-element #\x)))
               (setf (nerimux::client-conn-view wide) :pane
                     (nerimux::client-conn-view narrow) :pane)
               (let ((wide-frame (nerimux::%render-client-frame s wide))
                     (narrow-frame (nerimux::%render-client-frame s narrow)))
                 (expect (eq wide-frame (nerimux::client-conn-frame wide)))
                 (expect (eq narrow-frame (nerimux::client-conn-frame narrow)))
                 (expect (/= (length wide-frame) (length narrow-frame)))
                 (setf (nerimux::client-conn-focus wide) :wide-pane
                       (nerimux::client-conn-viewport wide) 3
                       (nerimux::client-conn-modal wide) :scrollback)
                 (nerimux::%render-client-frame s wide)
                 (expect (equal '(10 40 :wide-pane 3 :scrollback) (first calls)))
                 (expect (eq :wide-pane (nerimux::client-conn-focus wide)))
                 (expect (= 3 (nerimux::client-conn-viewport wide)))
                 (expect (eq :scrollback (nerimux::client-conn-modal wide)))
                 (expect (null (nerimux::client-conn-focus narrow)))
                 (expect (= 0 (nerimux::client-conn-viewport narrow)))
                 (expect (null (nerimux::client-conn-modal narrow)))))
          (setf (fdefinition 'nerimux/renderer:render-session-to-string) renderer)))))

  (it "message-strip-drops-a-notification-on-a-view-switch-and-never-restores-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist
              (nerimux::client-conn-message-log conn)
              (list "pane too small to split"))
        (expect (equal '("pane too small to split")
                       (nerimux::%client-render-messages s conn)))
        (expect (equal '("pane too small to split")
                       (nerimux::%client-render-messages s conn)))
        (setf (nerimux::client-conn-view conn) :status)
        (expect (null (nerimux::%client-render-messages s conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (expect (null (nerimux::%client-render-messages s conn))))))

  (it "message-strip-clears-on-the-next-keystroke-and-when-its-window-closes"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-message-log conn)
              (list "workspace refresh complete"))
        (expect (equal '("workspace refresh complete")
                       (nerimux::%client-render-messages s conn)))
        (nerimux::%client-note-keystroke conn)
        (expect (null (nerimux::%client-render-messages s conn)))
        (setf (nerimux::client-conn-message-log conn)
              (list "workspace refresh started"))
        (expect (equal '("workspace refresh started")
                       (nerimux::%client-render-messages s conn)))
        (expect (null (nerimux::%client-message-expired-p conn)))
        (decf (second (gethash conn nerimux::*client-message-display*))
              (1+ nerimux::+message-display-seconds+))
        (expect (nerimux::%client-message-expired-p conn))
        (expect (null (nerimux::%client-render-messages s conn)))
        (expect (null (nerimux::%client-message-expired-p conn))))))

  (it "repolist-frame-expands-the-ancestors-of-a-selection-folded-out-of-sight"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore organization main-worktree))
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux::*workspace-collapsed-node-ids*
              (make-hash-table :test #'equal))
            (nerimux::*workspace-expanded-node-ids*
              (make-hash-table :test #'equal))
            (nerimux/vcs::*workspace-organizations* organizations))
        (nerimux::%set-client-selected-tree-object conn feature-worktree)
        (expect (null (position feature-worktree
                                (nerimux::%workspace-tree-objects organizations)
                                :test #'equal)))
        (nerimux::%client-reveal-tree-selection conn)
        (expect (gethash (list :repository
                               (nerimux/workspace-model:repository-id repository))
                         nerimux::*workspace-expanded-node-ids*))
        (expect (position feature-worktree
                          (nerimux::%workspace-tree-objects organizations)
                          :test #'equal)))))

  (it "visibility-level-folds-the-tables-navigation-reads-not-the-drawn-rows-alone"
    (multiple-value-bind (organizations organization repository main-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore organization main-worktree))
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux::*workspace-collapsed-node-ids*
              (make-hash-table :test #'equal))
            (nerimux::*workspace-expanded-node-ids*
              (make-hash-table :test #'equal))
            (nerimux/vcs::*workspace-organizations* organizations))
        (nerimux::%client-apply-visibility-level conn organizations)
        (expect (zerop (hash-table-count
                        nerimux::*workspace-collapsed-node-ids*)))
        (setf (nerimux::client-conn-visibility-level conn) 1)
        (nerimux::%client-apply-visibility-level conn organizations)
        (expect (every #'keywordp
                       (nerimux::%workspace-tree-objects organizations)))
        (setf (nerimux::client-conn-visibility-level conn) 3)
        (nerimux::%client-apply-visibility-level conn organizations)
        (let ((objects (nerimux::%workspace-tree-objects organizations)))
          (expect (position repository objects :test #'equal))
          (expect (find-if (lambda (object)
                             (typep object
                                    'nerimux/workspace-model:worktree))
                           objects))))))

  (it "modal-frame-retires-an-expired-notification-so-the-loop-stops-spinning"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (nerimux::*dirty* nil))
        (setf (nerimux::client-conn-message-log conn)
              (list "workspace refresh started"))
        (expect (equal '("workspace refresh started")
                       (nerimux::%client-render-messages s conn)))
        (setf (nerimux::client-conn-modal conn) :help)
        (decf (second (gethash conn nerimux::*client-message-display*))
              (1+ nerimux::+message-display-seconds+))
        (expect (nerimux::%client-message-expired-p conn))
        (nerimux::%render-client-frame s conn)
        (expect (null (nerimux::%client-message-expired-p conn)))
        (setf (second (gethash conn nerimux::*client-message-display*))
              (- (get-universal-time)
                 (1+ nerimux::+message-display-seconds+)))
        (with-stubbed-fdefinition
            ((nerimux/transport:send-frame
              (lambda (stream frame) (declare (ignore stream frame)) nil)))
          (nerimux::%broadcast-frame s)
          (expect (null nerimux::*dirty*))
          (expect (notany #'nerimux::%client-message-expired-p
                          nerimux::*clients*))))))

  (it "moves-a-selection-a-visibility-level-hid-onto-a-row-that-is-drawn"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore organization repository main-worktree))
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux::*workspace-collapsed-node-ids*
              (make-hash-table :test #'equal))
            (nerimux::*workspace-expanded-node-ids*
              (make-hash-table :test #'equal))
            (nerimux/vcs::*workspace-organizations* organizations))
        (nerimux::%set-client-selected-tree-object conn feature-worktree)
        (nerimux::%apply-visibility-level 1 organizations)
        (expect (null (position feature-worktree
                                (nerimux::%workspace-tree-objects organizations)
                                :test #'equal)))
        (nerimux::%client-reveal-or-move-selection conn)
        (expect (position (nerimux::client-conn-selected-tree-object conn)
                          (nerimux::%workspace-tree-objects organizations)
                          :test #'equal)))))

  (it "level-4-requests-the-history-it-just-expanded-a-worktree-onto"
    (multiple-value-bind (organizations organization repository main-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore organization repository))
      (let ((requested nil)
            (nerimux::*workspace-collapsed-node-ids*
              (make-hash-table :test #'equal))
            (nerimux::*workspace-expanded-node-ids*
              (make-hash-table :test #'equal)))
        (expect (null (nerimux/workspace-model:worktree-commits-state
                       main-worktree)))
        (with-stubbed-fdefinition
            ((nerimux::%client-start-worktree-commits-refresh
              (lambda (worktree) (push worktree requested))))
          (nerimux::%apply-visibility-level 4 organizations))
        (expect (eq :pending
                    (nerimux/workspace-model:worktree-commits-state
                     main-worktree)))
        (expect (member main-worktree requested))
        (setf requested nil)
        (with-stubbed-fdefinition
            ((nerimux::%client-start-worktree-commits-refresh
              (lambda (worktree) (push worktree requested))))
          (nerimux::%apply-visibility-level 4 organizations))
        (expect (null requested)))))

  (it "repolist-frame-flattens-the-tree-exactly-once"
    (multiple-value-bind (organizations organization repository main-worktree
                          feature-worktree)
        (%make-server-dispatch-helper-fixture)
      (declare (ignore organization repository main-worktree feature-worktree))
      (with-fake-session (s)
        (let* ((conn (%make-test-conn))
               (nerimux::*workspace-collapsed-node-ids*
                 (make-hash-table :test #'equal))
               (nerimux::*workspace-expanded-node-ids*
                 (make-hash-table :test #'equal))
               (nerimux/vcs::*workspace-organizations* organizations)
               (original (fdefinition 'nerimux/renderer:workspace-flat-tree-entries))
               (calls 0))
          (setf (nerimux::client-conn-view conn) :repolist)
          (unwind-protect
               (progn
                 (setf (fdefinition 'nerimux/renderer:workspace-flat-tree-entries)
                       (lambda (&rest arguments)
                         (incf calls)
                         (apply original arguments)))
                 (nerimux::%render-client-frame s conn)
                 (expect (= 1 calls)))
            (setf (fdefinition 'nerimux/renderer:workspace-flat-tree-entries)
                  original)))))))
