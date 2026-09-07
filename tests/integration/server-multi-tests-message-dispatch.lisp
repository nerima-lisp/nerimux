(in-package #:nerimux/test)

(defclass row-delta-output-stream (sb-gray:fundamental-binary-output-stream)
  ((bytes :initform (make-array 0 :element-type '(unsigned-byte 8)
                               :adjustable t :fill-pointer 0)
          :reader row-delta-output-bytes)
   (fail-flush :initform nil :accessor row-delta-fail-flush)
   (flush-count :initform 0 :accessor row-delta-flush-count)))

(defmethod stream-element-type ((stream row-delta-output-stream))
  '(unsigned-byte 8))

(defmethod sb-gray:stream-write-byte ((stream row-delta-output-stream) byte)
  (vector-push-extend byte (row-delta-output-bytes stream))
  byte)

(defmethod sb-gray:stream-finish-output ((stream row-delta-output-stream))
  (incf (row-delta-flush-count stream))
  (when (row-delta-fail-flush stream) (error "row-delta injected flush failure")))

(defun %row-delta-take-output (stream)
  (let ((bytes (row-delta-output-bytes stream)))
    (multiple-value-bind (type payload next) (nerimux/protocol:decode-frame bytes)
      (assert type)
      (assert (= next (length bytes)))
      (setf (fill-pointer bytes) 0)
      (cl-codec-kit:octets-to-string payload :encoding :utf-8))))

(defun %row-delta-test-candidate (conn text &optional (title ""))
  (let ((surface (cl-tui-kit/core:make-surface
                  (nerimux::client-conn-cols conn) (nerimux::client-conn-rows conn))))
    (cl-tui-kit/core:surface-draw-text surface 0 1 text)
    (multiple-value-bind (full snapshot) (nerimux/renderer::%surface-to-ansi-frame surface)
      (multiple-value-bind (titled titled-snapshot)
          (nerimux/renderer::%ansi-frame-with-title full snapshot title)
        (let ((frame (nerimux/protocol:msg-frame titled)))
          (setf (nerimux::client-conn-frame conn) frame
                (nerimux::client-conn-row-frame-candidate conn)
                (list frame (nerimux::%client-row-frame-key conn) titled-snapshot))
          frame)))))

(describe "server-multi-suite"

  (it "row-delta sends first full then one row and suppresses identical retransmission"
    (let* ((stream (make-instance 'row-delta-output-stream))
           (conn (nerimux::%make-client-conn :stream stream :rows 3 :cols 10))
           (a (%row-delta-test-candidate conn "A")))
      (nerimux::%send-client-frame conn a)
      (let ((full (%row-delta-take-output stream))
            (b (%row-delta-test-candidate conn "B")))
        (expect (search (format nil "~C[2J" #\Escape) full))
        (nerimux::%send-client-frame conn b)
        (let ((delta (%row-delta-take-output stream)))
          (expect (< (length delta) (length full)))
          (expect (null (search (format nil "~C[2J" #\Escape) delta)))
          (expect (search (format nil "~C[2;1H" #\Escape) delta))
          (expect (null (search (format nil "~C[1;1H" #\Escape) delta)))
          (expect (null (search (format nil "~C[3;1H" #\Escape) delta))))
        (nerimux::%send-client-frame conn b)
        (expect (zerop (length (row-delta-output-bytes stream))))
        (expect (= 2 (row-delta-flush-count stream))))))

  (it "row-delta commits only successful sends and retries partial flush failure with full frame"
    (let* ((stream (make-instance 'row-delta-output-stream))
           (conn (nerimux::%make-client-conn :stream stream :rows 3 :cols 10)))
      (nerimux::%send-client-frame conn (%row-delta-test-candidate conn "A"))
      (%row-delta-take-output stream)
      (let* ((baseline (nerimux::client-conn-sent-row-frame conn))
             (b (%row-delta-test-candidate conn "B")))
        (expect (eq baseline (nerimux::client-conn-sent-row-frame conn)))
        (setf (row-delta-fail-flush stream) t)
        (expect (handler-case (progn (nerimux::%send-client-frame conn b) nil)
                  (error () t)))
        (expect (plusp (length (row-delta-output-bytes stream))))
        (expect (null (nerimux::client-conn-sent-row-frame conn)))
        (setf (fill-pointer (row-delta-output-bytes stream)) 0
              (row-delta-fail-flush stream) nil)
        (nerimux::%send-client-frame conn b)
        (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream)))
        (expect (eq b (first (nerimux::client-conn-sent-row-frame conn)))))))

  (it "row-delta invalidates geometry view modal and arbitrary-frame baselines"
    (let* ((stream (make-instance 'row-delta-output-stream))
           (conn (nerimux::%make-client-conn :stream stream :rows 3 :cols 10)))
      (nerimux::%send-client-frame conn (%row-delta-test-candidate conn "A"))
      (%row-delta-take-output stream)
      (dolist (change (list (lambda () (incf (nerimux::client-conn-cols conn)))
                           (lambda () (setf (nerimux::client-conn-view conn) :status))
                           (lambda () (setf (nerimux::client-conn-modal conn) :help))))
        (funcall change)
        (nerimux::%send-client-frame conn (%row-delta-test-candidate conn "B"))
        (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream))))
      (nerimux::%send-client-frame conn (nerimux/protocol:msg-frame "arbitrary"))
      (expect (string= "arbitrary" (%row-delta-take-output stream)))
      (expect (null (nerimux::client-conn-sent-row-frame conn)))
      (setf (nerimux::client-conn-modal conn) nil)
      (nerimux::%send-client-frame conn (%row-delta-test-candidate conn "B"))
      (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream)))))

  (it "row-delta isolates clients and transmits title-only OSC"
    (let* ((stream-a (make-instance 'row-delta-output-stream))
           (stream-b (make-instance 'row-delta-output-stream))
           (a (nerimux::%make-client-conn :stream stream-a :rows 3 :cols 10))
           (b (nerimux::%make-client-conn :stream stream-b :rows 3 :cols 10))
           (title-a (format nil "~C]2;A~C" #\Escape #\Bel))
           (title-b (format nil "~C]2;B~C" #\Escape #\Bel)))
      (nerimux::%send-client-frame a (%row-delta-test-candidate a "A" title-a))
      (%row-delta-take-output stream-a)
      (nerimux::%send-client-frame a (%row-delta-test-candidate a "A" title-b))
      (expect (string= title-b (%row-delta-take-output stream-a)))
      (nerimux::%send-client-frame b (%row-delta-test-candidate b "A" title-b))
      (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream-b)))
      (expect (not (eq (nerimux::client-conn-sent-row-frame a)
                       (nerimux::client-conn-sent-row-frame b))))))

  (it "row-delta real overview status and modal rendering respect sent cache ownership"
    (with-fake-session (session)
      (let* ((organization
               (nerimux/workspace-model:make-organization :id "row-delta-org"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "row-delta-repo" :organization organization
                :specification "row-delta/repo"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "row-delta-worktree" :repository repository
                :path "row-delta-worktree" :branch "main"))
             (stream (make-instance 'row-delta-output-stream))
             (conn (nerimux::%make-client-conn :stream stream :rows 10 :cols 40))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (let ((frame (nerimux::%render-client-frame session conn)))
          (expect (nerimux::client-conn-row-frame-candidate conn))
          (expect (null (nerimux::client-conn-sent-row-frame conn)))
          (nerimux::%send-client-frame conn frame)
          (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream))))
        (let ((baseline (nerimux::client-conn-sent-row-frame conn)))
          (nerimux::%render-client-frame session conn)
          (expect (eq baseline (nerimux::client-conn-sent-row-frame conn))))
        (setf (nerimux::client-conn-view conn) :status
              (nerimux::client-conn-selected-worktree conn) worktree)
        (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))
        (nerimux::%send-client-frame conn (nerimux::%render-client-frame session conn))
        (expect (nerimux::client-conn-row-frame-candidate conn))
        (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream)))
        (setf (nerimux::client-conn-modal conn) :help)
        (nerimux::%send-client-frame conn (nerimux::%render-client-frame session conn))
        (expect (null (nerimux::client-conn-row-frame-candidate conn)))
        (expect (null (nerimux::client-conn-sent-row-frame conn)))
        (%row-delta-take-output stream)
        (setf (nerimux::client-conn-modal conn) nil)
        (nerimux::%send-client-frame conn (nerimux::%render-client-frame session conn))
        (expect (search (format nil "~C[2J" #\Escape) (%row-delta-take-output stream))))))

  (it "resolves picker worktrees through repository and organization fallbacks"
    (let* ((empty-organization
             (nerimux/workspace-model:make-organization))
           (repository
             (nerimux/workspace-model:make-repository))
           (worktree
             (nerimux/workspace-model:make-worktree :path "/tmp/nerimux-wt"))
           (organization
             (nerimux/workspace-model:make-organization)))
      (nerimux/workspace-model:organization-add-repository
       organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (setf (nerimux/workspace-model:repository-main-worktree repository) nil)
      (expect (eq worktree
                  (nerimux::%picker-item-worktree
                   (nerimux/picker::%make-picker-item
                    :repository repository))))
      (expect (null (nerimux::%picker-item-worktree
                     (nerimux/picker::%make-picker-item
                      :organization empty-organization))))
      (expect (eq worktree
                  (nerimux::%picker-item-worktree
                   (nerimux/picker::%make-picker-item
                    :organization organization))))))

  (it "does not search panes when picker worktree is absent"
    (let ((session (make-session :id 1 :name "0")))
      (expect (null (nerimux::%client-worktree-pane session nil)))))

  (it "returns no pane when picker worktree is not attached"
    (let* ((session (make-session :id 1 :name "0"))
           (worktree (nerimux/workspace-model:make-worktree)))
      (expect (null (nerimux::%client-worktree-pane session worktree)))))

  (it "main-thread-callback-queue-preserves-order"
    (let ((events nil)
          (nerimux::*main-thread-callbacks* nil))
      (nerimux::%enqueue-main-thread-callback
       (lambda () (setf events (nconc events (list :first)))))
      (nerimux::%enqueue-main-thread-callback
       (lambda () (setf events (nconc events (list :second)))))
      (nerimux::%drain-main-thread-callbacks)
      (expect (equal '(:first :second) events))))

  (it "main-thread-callback-queue-continues-after-callback-error"
    (let ((events nil)
          (nerimux::*main-thread-callbacks* nil))
      (nerimux::%enqueue-main-thread-callback
       (lambda () (error "expected callback failure")))
      (nerimux::%enqueue-main-thread-callback
       (lambda () (push :after-error events)))
      (nerimux::%drain-main-thread-callbacks)
      (expect (equal '(:after-error) events))))

  (it "tree-selection-helpers-cover-boundaries"
    (check-table
      (list (list (nerimux::%tree-selection-index 'a '(a b) 1)
                  0
                  "preserve an existing selection")
            (list (nerimux::%tree-selection-index nil '(a b) -1)
                  0
                  "start before the first item when moving backward")
            (list (nerimux::%tree-selection-index nil '(a b) 1)
                  -1
                  "keep the invalid forward sentinel")
            (list (nerimux::%tree-selection-scroll 2 3 5)
                  2
                  "scroll upward to the selected item")
            (list (nerimux::%tree-selection-scroll 8 3 5)
                  4
                  "scroll downward when the selection leaves the viewport")
            (list (nerimux::%tree-selection-scroll 10 0 0)
                  11
                  "advance even when the visible height is empty")
            (list (nerimux::%tree-selection-scroll 5 0 10)
                  0
                  "retain the viewport while the selection is visible"))))


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
                                           picker-items picker-query picker-index
                                           picker-regex-p command-buffer)
                       (declare (ignore session))
                       (declare (ignore picker-items picker-query picker-index
                                        picker-regex-p command-buffer))
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
        (expect (null (nerimux::%handle-client-ui-command
                       s conn :mode nil '("not-a-mode"))))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux::%handle-client-ui-command
                 s conn :focus nil '("not-a-pane")))
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
      (let ((conn (%make-test-conn))
            (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%open-client-picker
              (lambda (conn)
                (push :open calls)
                (setf (nerimux::client-conn-modal conn) :picker)))
             (nerimux::%close-client-picker
              (lambda (conn)
                (push :close calls)
                (setf (nerimux::client-conn-modal conn) nil)))
             (nerimux::%select-client-picker-item
              (lambda (session conn)
                (declare (ignore session))
                (push :select calls)
                (setf (nerimux::client-conn-modal conn) nil)
                t))
             (nerimux::%client-enter-copy-mode
              (lambda (session conn)
                (declare (ignore session))
                (setf (nerimux::client-conn-modal conn) :scrollback))))
          (expect (nerimux::%handle-client-ui-command s conn :mode nil '("picker")))
          (expect (eq :picker (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :picker-close nil nil))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :mode nil '("picker")))
          (expect (nerimux::%handle-client-ui-command s conn :accept nil nil))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :mode nil '("copy")))
          (expect (eq :scrollback (nerimux::client-conn-modal conn)))
          (dolist (mode '(:normal :input :command :tree-filter))
            (expect (nerimux::%handle-client-ui-command s conn mode nil nil)))
          (expect (nerimux::%handle-client-ui-command s conn :copy nil nil))
          (expect (eq :scrollback (nerimux::client-conn-modal conn)))
          (expect (nerimux::%handle-client-ui-command s conn :cancel nil nil))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (equal '(:select :open :close :open) calls))))))

  (it "ui-command-dispatch-rejects-prune-arguments-and-cancels-picker"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (calls nil)
            (notifications nil))
        (setf (nerimux::client-conn-modal conn) :picker)
        (with-stubbed-fdefinition
            ((nerimux::%client-notify
              (lambda (client message)
                (declare (ignore client))
                (push message notifications)))
             (nerimux::%client-prune-workspaces
              (lambda (&rest arguments)
                (push arguments calls)))
             (nerimux::%close-client-picker
              (lambda (client)
                (declare (ignore client))
                (push :close calls))))
          (expect (nerimux::%handle-client-ui-command
                   s conn :workspace-prune "unexpected" nil))
          (expect (null calls))
          (expect (equal '("workspace prune takes no arguments") notifications))
          (expect (nerimux::%handle-client-ui-command
                   s conn :cancel nil nil))
          (expect (equal '(:close) calls))))))

  (it "ui-command-dispatches-single-and-all-workspace-prune"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%client-prune-workspaces
              (lambda (client &key all)
                (push (list client all) calls)
                t)))
          (expect (nerimux::%handle-client-ui-command
                   s conn :workspace-prune nil nil))
          (expect (nerimux::%handle-client-ui-command
                   s conn :workspace-prune-all nil nil))
          (expect (equal (list (list conn t) (list conn nil)) calls))))))

  (it "pending-worktree-guards-preserve-command-and-focus-state"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (window (nerimux/session:session-active-window s))
             (pane (nerimux/window:window-active-pane window))
             (worktree (nerimux/workspace-model:make-worktree
                        :id "pending-focus"
                        :path "/tmp/pending-focus")))
        (setf (nerimux::client-conn-view conn) :command
              (nerimux::client-conn-command-return-view conn) :pane)
        (with-stubbed-fdefinition
            ((nerimux::%reject-pending-worktree-attachment
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 t)))
          (expect (null (nerimux::%client-restore-command-view conn)))
          (expect (eq :pane (nerimux::client-conn-command-return-view conn)))
          (nerimux::%set-client-selected-tree-object conn pane)
          (nerimux::%set-client-focus conn pane)
          (expect (null (nerimux::%focus-selected-client-worktree s conn)))
          (expect (eq :command (nerimux::client-conn-view conn)))
          (nerimux::%set-client-selected-tree-object conn window)
          (expect (null (nerimux::%focus-selected-client-worktree s conn)))
          (expect (eq :command (nerimux::client-conn-view conn)))
          (nerimux::%set-client-selected-tree-object conn worktree)
          (setf (nerimux::client-conn-selected-worktree conn) worktree)
          (expect (null (nerimux::%focus-selected-client-worktree s conn)))
          (expect (null (nerimux::%client-select-pane-direction s conn :left)))))))

  (it "ui-command-aliases-preserve-command-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%client-rebind-prefix
              (lambda (conn prefix)
                (declare (ignore conn))
                (push (list :prefix prefix) calls)))
             (nerimux::%select-client-tree-relative
              (lambda (conn delta)
                (declare (ignore conn))
                (push (list :tree delta) calls)))
             (nerimux::%move-client-tree-scroll
              (lambda (conn delta)
                (declare (ignore conn))
                (push (list :scroll delta) calls))))
          (expect (nerimux::%handle-client-ui-command
                   s conn :prefix-key "C-x" nil))
          (expect (nerimux::%handle-client-ui-command
                   s conn :tree-prev nil '("2")))
          (expect (nerimux::%handle-client-ui-command
                   s conn :tree-next nil nil))
          (expect (nerimux::%handle-client-ui-command
                   s conn :tree-scroll nil '("bad")))
          (expect (equal '((:scroll 1) (:tree 1) (:tree -2) (:prefix "C-x"))
                         calls))))))

  (it "picker-command-actions-share-a-small-dispatch-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (calls nil))
        (with-stubbed-fdefinition
            ((nerimux::%select-client-picker-item
              (lambda (session conn)
                (declare (ignore session conn))
                (push :select calls)))
             (nerimux::%refresh-client-picker
              (lambda (conn)
                (declare (ignore conn))
                (push :refresh calls)))
             (nerimux::%mark-dirty
              (lambda ()
                (push :dirty calls)))
             (nerimux::%move-client-picker-index
              (lambda (conn delta)
                (declare (ignore conn))
                (push (list :move delta) calls)))
             (nerimux::%delete-client-picker-query-character
              (lambda (conn)
                (declare (ignore conn))
                (push :backspace calls)))
             (nerimux::%set-client-picker-query
              (lambda (conn value)
                (declare (ignore conn))
                (push (list :query value) calls)))
             (nerimux::%set-client-picker-regex
              (lambda (conn value supplied-p)
                (declare (ignore conn))
                (push (list :regex value supplied-p) calls))))
          (dolist (command '((:picker-accept nil nil)
                             (:picker-refresh nil nil)
                             (:picker-next "2" nil)
                             (:picker-up "2" nil)
                             (:picker-backspace nil nil)
                             (:picker-query "needle" nil)
                             (:picker-query nil ("from-args"))
                             (:picker-regex "pattern" nil)
                             (:picker-regex nil ("from-args"))))
            (destructuring-bind (name target args) command
              (expect (nerimux::%handle-client-ui-command
                       s conn name target args))))
          (expect (equal '((:regex "from-args" ("from-args"))
                           (:regex "pattern" "pattern")
                           (:query "from-args")
                           (:query "needle")
                           :backspace
                           (:move -2)
                           (:move 2)
                           :dirty
                           :refresh
                           :select)
                         calls))))))

  (it "forwarded-command-message-keeps-ui-and-rejects-unknown-commands"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload :home))))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload :not-a-ui-command))))
        (let ((nerimux::*dirty* nil))
          (expect (null
                   (nerimux::%handle-multi-command-message
                    s conn nil)))
          (expect nerimux::*dirty*)))))

  (it "forwarded-command-message-applies-focus-and-viewport"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload
                   :viewport :args '("4")))))
        (expect (= 4 (nerimux::client-conn-viewport conn)))
        (expect (null
                 (nerimux::%handle-multi-command-message
                  s conn
                  (nerimux/protocol::encode-command-payload
                   :focus))))
        (expect (eq (nerimux::window-active-pane
                     (nerimux::session-active-window s))
                    (nerimux::client-conn-focus conn))))))

  (it "kill-command-replies-drops-client-and-forwards-success"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (requests nil)
            (frames nil)
            (drops nil))
        (with-stubbed-fdefinition
            ((nerimux::%server-kill-request
              (lambda (session force)
                (push (list session force) requests)
                (values :ok nil)))
             (nerimux::send-frame
              (lambda (stream frame)
                (push (list stream frame) frames)))
             (nerimux::%drop-client
              (lambda (client)
                (push client drops))))
          (expect (eq :quit
                      (nerimux::%handle-client-ui-command
                       s conn :kill nil '("--force"))))
          (expect (equal (list (list s t)) requests))
          (expect (equal (list conn) drops))
          (expect (= 1 (length frames)))))))

  (it "kill-command-replies-denied-and-still-drops-client"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (frames nil)
            (drops nil))
        (with-stubbed-fdefinition
            ((nerimux::%server-kill-request
              (lambda (session force)
                (declare (ignore session force))
                (values :denied '("active clients remain"))))
             (nerimux::send-frame
              (lambda (stream frame)
                (declare (ignore stream))
                (push frame frames)))
             (nerimux::%drop-client
              (lambda (client)
                (push client drops))))
          (expect (eq t
                      (nerimux::%handle-client-ui-command
                       s conn :kill nil nil)))
          (expect (= 1 (length frames)))
          (multiple-value-bind (type payload)
              (nerimux/protocol::decode-frame (first frames))
            (expect (= nerimux::+msg-reply+ type))
            (expect (search "DENIED" (nerimux/protocol::decode-text payload))))
          (expect (equal (list conn) drops))))))

  (it "forwarded-kill-command-propagates-quit-disposition"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (with-stubbed-fdefinition
            ((nerimux::%handle-client-kill-command
              (lambda (session client args)
                (declare (ignore session client args))
                :quit)))
          (expect (eq :quit
                      (nerimux::%handle-multi-command-message
                       s conn
                       (nerimux/protocol::encode-command-payload :kill))))))))

  (it "overview-shortcut-opens-worktree-picker"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (refresh (fdefinition
                       'nerimux/vcs:refresh-workspace-organizations-async))
             (organizations (fdefinition 'nerimux/vcs:workspace-organizations)))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:workspace-organizations)
                     (lambda () nil)
                     (fdefinition
                      'nerimux/vcs:refresh-workspace-organizations-async)
                     (lambda (&key on-complete on-error callback-dispatch &allow-other-keys)
                       (declare (ignore on-error callback-dispatch))
                       (funcall on-complete nil)))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%handle-multi-key-message s conn #(16))
               (expect (eq :picker (nerimux::client-conn-modal conn)))
               (expect (string= ""
                                (nerimux::client-conn-picker-query conn))))
          (setf (fdefinition 'nerimux/vcs:refresh-workspace-organizations-async)
                refresh
                (fdefinition 'nerimux/vcs:workspace-organizations)
                organizations)))))

  (it "wt-create-command-with-an-explicit-branch-reaches-the-vcs-layer"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo" :organization organization
                :specification "github.com/team/repo"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (create (fdefinition 'nerimux/vcs:create-worktree-async))
             (call nil))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:create-worktree-async)
                     (lambda (received-repository
                              &key branch path force on-complete on-error
                                callback-dispatch &allow-other-keys)
                       (declare (ignore path force on-complete on-error
                                       callback-dispatch))
                       (setf call (list received-repository branch))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58)) ; :
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-create --branch feature/explicit --confirm"
                 :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository "feature/explicit") call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:create-worktree-async) create)))))

  (it "overview-worktree-delete-dispatches-and-restores-overview"
    (with-fake-session (s)
      (let* ((nerimux::*worktree-delete-reservations* (make-hash-table :test #'equal))
             (organization
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
                :branch "feature/doomed"))
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree
                              &key force on-complete on-error on-result callback-dispatch)
                       (declare (ignore on-complete on-error on-result callback-dispatch))
                       (setf call (list received-worktree force))
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58)) ; :
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-delete --confirm" :encoding :utf-8))
               (expect (eq :command (nerimux::client-conn-modal conn)))
               (expect (string= "wt-delete --confirm"
                                (nerimux::client-conn-command-buffer conn)))
               (nerimux::%handle-multi-key-message s conn #(127))
               (expect (string= "wt-delete --confir"
                                (nerimux::client-conn-command-buffer conn)))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "m" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list worktree nil) call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn)))
               (expect (string= "" (nerimux::client-conn-command-buffer conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

  (it "overview-worktree-delete-without-confirm-is-rejected"
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
                :branch "feature/no-confirm"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree
                              &key force on-complete on-error callback-dispatch)
                       (declare (ignore force on-complete on-error
                                       callback-dispatch))
                       (setf call received-worktree)
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-delete" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (string= "worktree delete requires --confirm"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))

  (it "overview-worktree-delete-without-selection-is-rejected"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (delete-fn (fdefinition 'nerimux/vcs:delete-worktree-async))
             (call nil))
        (unwind-protect
             (progn
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:delete-worktree-async)
                     (lambda (received-worktree
                              &key force on-complete on-error callback-dispatch)
                       (declare (ignore force on-complete on-error
                                       callback-dispatch))
                       (setf call received-worktree)
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-delete --confirm"
                 :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (null call))
               (expect (string= "worktree delete requires a worktree"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:delete-worktree-async) delete-fn)))))


  (it "wt-lock-and-wt-unlock-commands-reach-the-vcs-layer"
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
                :id "feature" :repository repository
                :path "/tmp/feature" :branch "feature/lockme"))
             (conn (%make-test-conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (lock-fn (fdefinition 'nerimux/vcs:lock-worktree-async))
             (unlock-fn (fdefinition 'nerimux/vcs:unlock-worktree-async))
             (lock-call nil)
             (unlock-call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:lock-worktree-async)
                     (lambda (received-worktree
                              &key reason on-complete on-error callback-dispatch)
                       (declare (ignore on-error callback-dispatch))
                       (setf lock-call (list received-worktree reason))
                       (funcall on-complete t)
                       t)
                     (fdefinition 'nerimux/vcs:unlock-worktree-async)
                     (lambda (received-worktree
                              &key on-complete on-error callback-dispatch)
                       (declare (ignore on-error callback-dispatch))
                       (setf unlock-call received-worktree)
                       (funcall on-complete t)
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58)) ; :
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-lock --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list worktree nil) lock-call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn)))
               (nerimux::%set-client-selected-tree-object conn worktree)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-unlock --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (eq worktree unlock-call))
               (expect (null (nerimux::client-conn-modal conn)))
               (expect (eq :repolist (nerimux::client-conn-view conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:lock-worktree-async) lock-fn
                (fdefinition 'nerimux/vcs:unlock-worktree-async) unlock-fn)))))

  (it "the-w-transient-reaches-the-real-worktree-operations"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil))
        (setf nerimux::*clients* (list conn))
        (setf (nerimux::client-conn-view conn) :status)
        (dolist (probe '((#(99)  . "select a repository first")   ; w c
                         (#(107) . "select a worktree to delete") ; w k
                         (#(108) . "select a worktree to lock")   ; w l
                         (#(117) . "select a worktree to unlock"))) ; w u
          (destructuring-bind (key . expected) probe
            (nerimux::%handle-multi-key-message
             s conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
            (expect (eq :transient (nerimux::client-conn-modal conn)))
            (nerimux::%handle-multi-key-message s conn key)
            (expect (string= expected
                             (first (nerimux::client-conn-message-log conn))))
            (expect (null (nerimux::client-conn-modal conn)))))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "w" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(67)) ; C
        (expect (search "wt-create"
                        (first (nerimux::client-conn-message-log conn)))))))

  (it "every-transient-call-handler-accepts-the-arguments-the-dispatcher-passes"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (checked 0))
        (setf nerimux::*clients* (list conn))
        (dolist (definition nerimux::+transient-definitions+)
          (destructuring-bind (title arguments actions) (cdr definition)
            (declare (ignore title arguments))
            (dolist (action actions)
              (let ((handler (third action)))
                (when (eq :call (first handler))
                  (incf checked)
                  (funcall (second handler) s conn))))))
        (expect (plusp checked)))))

  (it "overview-worktree-prune-preview-does-not-mutate"
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
                :id "stale"
                :repository repository
                :path "/tmp/stale"
                :branch "feature/stale"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (prune-fn (fdefinition 'nerimux/vcs:prune-worktrees-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error
                                callback-dispatch)
                       (declare (ignore verbose on-error callback-dispatch))
                       (setf call (list received-repository dry-run))
                       (unless dry-run
                         (setf (nerimux/workspace-model:repository-worktrees
                                received-repository)
                               nil))
                       (funcall on-complete "Would remove /tmp/stale")
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-prune" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository t) call))
               (expect (equal (list worktree)
                              (nerimux/workspace-model:repository-worktrees repository)))
               (expect (string= "worktree prune preview: Would remove /tmp/stale"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  (it "overview-worktree-prune-confirm-mutates"
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
                :id "stale"
                :repository repository
                :path "/tmp/stale"
                :branch "feature/stale"))
             (conn (%make-test-conn))
             (nerimux::*clients* (list conn))
             (available (fdefinition 'nerimux/vcs:vcs-package-available-p))
             (prune-fn (fdefinition 'nerimux/vcs:prune-worktrees-async))
             (call nil))
        (unwind-protect
             (progn
               (nerimux/workspace-model:organization-add-repository organization repository)
               (nerimux/workspace-model:repository-add-worktree repository worktree)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t)
                     (fdefinition 'nerimux/vcs:prune-worktrees-async)
                     (lambda (received-repository
                              &key dry-run verbose on-complete on-error
                                callback-dispatch)
                       (declare (ignore verbose on-error callback-dispatch))
                       (setf call (list received-repository dry-run))
                       (unless dry-run
                         (setf (nerimux/workspace-model:repository-worktrees
                                received-repository)
                               nil))
                       (funcall on-complete "")
                       t))
               (setf (nerimux::client-conn-view conn) :repolist)
               (nerimux::%set-client-selected-tree-object conn repository)
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets "wt-prune" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository t) call))
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn
                (cl-codec-kit:string-to-octets
                 "wt-prune-confirm --confirm" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (equal (list repository nil) call))
               (expect (null (nerimux/workspace-model:repository-worktrees repository)))
               (expect (string= "worktrees pruned"
                                (first (nerimux::client-conn-message-log conn))))
               (expect (null (nerimux::client-conn-modal conn))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available
                (fdefinition 'nerimux/vcs:prune-worktrees-async) prune-fn)))))

  (it "overview-tree-filter-key-enters-filter-mode-without-forcing-pane-view"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :filter (nerimux::client-conn-modal conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (setf (nerimux::client-conn-tree-scroll conn) 7)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "ab" :encoding :utf-8))
        (expect (string= "ab" (nerimux::client-conn-tree-filter conn)))
        (expect (zerop (nerimux::client-conn-tree-scroll conn)))
        (setf (nerimux::client-conn-tree-scroll conn) 3)
        (nerimux::%handle-multi-key-message s conn #(8))
        (expect (string= "a" (nerimux::client-conn-tree-filter conn)))
        (expect (zerop (nerimux::client-conn-tree-scroll conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message s conn #(0))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "xyz" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (string= "xyz" (nerimux::client-conn-tree-filter conn))))))

  (it "overview-tree-filter-key-starts-empty-again-after-a-previous-accept"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "abc" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (string= "abc" (nerimux::client-conn-tree-filter conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :filter (nerimux::client-conn-modal conn)))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "z" :encoding :utf-8))
        (expect (string= "z" (nerimux::client-conn-tree-filter conn))))))

  (it "overview-tree-filter-mode-absorbs-np-as-query-text-not-navigation"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-np-absorb" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-np-absorb" :organization organization
                :specification "github.com/team/repo-np-absorb"))
             (conn (%make-test-conn))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn repository)
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "/" :encoding :utf-8))
        (expect (eq :filter (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "np" :encoding :utf-8))
        (expect (string= "np" (nerimux::client-conn-tree-filter conn)))
        (expect (eq repository (nerimux::client-conn-selected-tree-object conn))))))

  (it "overview-tree-filter-editing-rejects-invalid-input-and-respects-the-cap"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-tree-filter conn) nil
              (nerimux::client-conn-tree-scroll conn) 4)
        (expect (null (nerimux::%client-tree-filter-buffer-delete-character conn)))
        (expect (null (nerimux::%client-tree-filter-buffer-append conn #(1))))
        (expect (null (nerimux::%client-tree-filter-buffer-append conn #(10))))
        (expect (null (nerimux::client-conn-tree-filter conn)))
        (setf (nerimux::client-conn-tree-filter conn)
              (make-string nerimux::+max-tree-filter-length+
                           :initial-element #\x))
        (expect (null (nerimux::%client-tree-filter-buffer-append conn #(121))))
        (expect (= nerimux::+max-tree-filter-length+
                   (length (nerimux::client-conn-tree-filter conn)))))))


  (it "tree-top-and-tree-bottom-commands-use-the-filtered-row-set"
    (with-fake-session (s)
      (let* ((org-noise
               (nerimux/workspace-model:make-organization
                :id "org-top-bottom-noise" :host "github.com" :name "noise"))
             (org-buried
               (nerimux/workspace-model:make-organization
                :id "org-top-bottom-buried" :host "github.com" :name "buried"))
             (repo-noise
               (nerimux/workspace-model:make-repository
                :id "repo-top-bottom-noise" :organization org-noise
                :specification "github.com/noise/repo"))
             (repo-buried
               (nerimux/workspace-model:make-repository
                :id "repo-top-bottom-buried" :organization org-buried
                :specification "github.com/buried/repo"))
             (worktree-noise
               (nerimux/workspace-model:make-worktree
                :id "wt-top-bottom-noise" :repository repo-noise
                :path "/tmp/top-bottom-noise" :branch "attention-noise"
                :dirty-p t))
             (worktree-buried
               (nerimux/workspace-model:make-worktree
                :id "wt-top-bottom-buried" :repository repo-buried
                :path "/tmp/top-bottom-buried" :branch "only-match"))
             (conn (%make-test-conn))
             (nerimux/vcs::*workspace-organizations*
               (list org-noise org-buried)))
        (nerimux/workspace-model:organization-add-repository org-noise repo-noise)
        (nerimux/workspace-model:organization-add-repository org-buried repo-buried)
        (nerimux/workspace-model:repository-add-worktree repo-noise worktree-noise)
        (nerimux/workspace-model:repository-add-worktree repo-buried worktree-buried)
        (expect (nerimux::%handle-client-ui-command s conn :tree-top nil nil))
        (expect (eq :attention (nerimux::client-conn-selected-tree-object conn)))
        (expect (nerimux::%handle-client-ui-command s conn :tree-bottom nil nil))
        (expect (eq repo-buried (nerimux::client-conn-selected-tree-object conn)))
        (setf (nerimux::client-conn-tree-filter conn) "only-match")
        (expect (nerimux::%handle-client-ui-command s conn :tree-top nil nil))
        (expect (eq :repositories (nerimux::client-conn-selected-tree-object conn)))
        (expect (nerimux::%handle-client-ui-command s conn :tree-bottom nil nil))
        (expect (eq worktree-buried (nerimux::client-conn-selected-tree-object conn))))))

  (it "workspace-context-and-operation-worktree-fall-back-to-focused-pane"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-focus-fallback" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-focus-fallback" :organization organization
                :specification "github.com/team/repo-focus-fallback"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-focus-fallback" :repository repository
                :path "/tmp/focus-fallback" :branch "focus-fallback"))
             (conn (%make-test-conn))
             (pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s))))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux/pane:worktree-add-pane worktree pane)
        (nerimux::%set-client-selected-tree-object conn nil)
        (setf (nerimux::client-conn-selected-worktree conn) nil
              (nerimux::client-conn-focus conn) pane)
        (expect (eq worktree (nerimux::%client-context-object conn nil)))
        (expect (eq worktree (nerimux::%client-operation-worktree conn nil))))))

  (it "tab-key-toggles-the-selected-section-header-and-repository-row"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-tab" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-tab" :organization organization
                :specification "github.com/team/repo-tab"))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn :repositories)
        (nerimux::%handle-multi-key-message s conn #(9))
        (expect (gethash (list :section :repositories)
                         nerimux::*workspace-collapsed-node-ids*))
        (nerimux::%handle-multi-key-message s conn #(9))
        (expect (null (gethash (list :section :repositories)
                               nerimux::*workspace-collapsed-node-ids*)))
        (nerimux::%set-client-selected-tree-object conn repository)
        (nerimux::%handle-multi-key-message s conn #(9))
        (expect (gethash (list :repository (nerimux/workspace-model:repository-id repository))
                         nerimux::*workspace-expanded-node-ids*)))))

  (it "h-and-l-toggle-the-selected-organization-row"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-hl" :host "github.com" :name "team"))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn organization)
        (nerimux::%client-tree-collapse-selected conn)
        (expect (gethash (list :organization
                               (nerimux/workspace-model:organization-id organization))
                         nerimux::*workspace-collapsed-node-ids*))
        (nerimux::%client-tree-expand-selected conn)
        (expect (null (gethash (list :organization
                                     (nerimux/workspace-model:organization-id organization))
                               nerimux::*workspace-collapsed-node-ids*))))))

  (it "meta-n-and-meta-p-jump-the-selection-across-section-headers"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-mnp-keys" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-mnp-keys" :organization organization
                :specification "github.com/team/repo-mnp-keys"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-mnp-keys" :repository repository :path "/tmp/mnp-keys"
                :branch "mnp-keys" :dirty-p t))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (nerimux::%handle-multi-key-message s conn #(27))
        (nerimux::%handle-multi-key-message s conn #(110))
        (expect (eq :repositories (nerimux::client-conn-selected-tree-object conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (nerimux::%handle-multi-key-message s conn #(112))
        (expect (eq :attention (nerimux::client-conn-selected-tree-object conn))))))

  (it "section-navigation-initializes-and-clamps-tree-scroll"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-section-scroll" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-section-scroll" :organization organization
                :specification "github.com/team/repo-section-scroll"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-section-scroll" :repository repository
                :path "/tmp/section-scroll" :branch "section-scroll"
                :dirty-p t))
             (conn (%make-test-conn :rows 7))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux::%set-client-selected-tree-object conn nil)
        (setf (nerimux::client-conn-tree-scroll conn) 0)
        (expect (eq :attention
                    (nerimux::%select-client-tree-section-relative conn 1)))
        (nerimux::%set-client-selected-tree-object conn :attention)
        (setf (nerimux::client-conn-tree-scroll conn) 0)
        (expect (eq :repositories
                    (nerimux::%select-client-tree-section-relative conn 1)))
        (expect (> (nerimux::client-conn-tree-scroll conn) 0))
        (nerimux::%set-client-selected-tree-object conn worktree)
        (setf (nerimux::client-conn-tree-scroll conn) 5)
        (expect (eq :attention
                    (nerimux::%select-client-tree-section-relative conn -1)))
        (expect (= 0 (nerimux::client-conn-tree-scroll conn))))))

  (it "tab-key-expands-and-collapses-a-worktree-rows-inline-detail"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-tab-wt" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-tab-wt" :organization organization
                :specification "github.com/team/repo-tab-wt"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-tab-wt" :repository repository :path "/tmp/tab-wt"
                :branch "tab-wt" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (flet ((entries ()
                 (nerimux/renderer::%workspace-flat-tree-entries
                  (list organization) nerimux::*workspace-collapsed-node-ids*
                  :expanded-node-ids nerimux::*workspace-expanded-node-ids*)))
          (expect (null (find :file (entries) :key #'fourth)))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                           nerimux::*workspace-expanded-node-ids*))
          (let ((file-entry (find :file (entries) :key #'fourth)))
            (expect file-entry)
            (expect (equal (list :file (nerimux/workspace-model:worktree-id worktree)
                                 "src/foo.lisp" " M")
                           (third file-entry))))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (null (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                                 nerimux::*workspace-expanded-node-ids*)))
          (expect (null (find :file (entries) :key #'fourth)))))))

  (it "selection-survives-re-flatten-on-a-file-row"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-file-reflatten" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-file-reflatten" :organization organization
                :specification "github.com/team/repo-file-reflatten"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-file-reflatten" :repository repository
                :path "/tmp/file-reflatten" :branch "file-reflatten" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (file-identity
               (list :file (nerimux/workspace-model:worktree-id worktree)
                     "src/foo.lisp" " M")))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (setf (gethash (list :worktree (nerimux/workspace-model:worktree-id worktree))
                       nerimux::*workspace-expanded-node-ids*)
              t)
        (nerimux::%set-client-selected-tree-object conn (copy-list file-identity))
        (nerimux::%select-client-tree-relative conn 0)
        (expect (equal file-identity
                       (nerimux::client-conn-selected-tree-object conn))))))

  (it "a-file-row-selection-survives-a-catalog-refresh-rebind-by-re-anchoring-on-its-worktree"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-file-rebind" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-file-rebind" :organization organization
                :specification "github.com/team/repo-file-rebind"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-file-rebind" :repository repository
                :path "/tmp/file-rebind" :branch "file-rebind" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux::*last-selected-worktree-token* nil)
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (nerimux::%handle-multi-key-message s conn #(9)) ; Tab: expand the worktree
        (nerimux::%handle-multi-key-message
         s conn #(27 91 66)) ; Down: move onto the :file row
        (let ((selected (nerimux::client-conn-selected-tree-object conn)))
          (expect (consp selected))
          (expect (eq :file (first selected))))
        (nerimux::%rebind-client-selection conn (list organization))
        (expect (eq worktree (nerimux::client-conn-selected-tree-object conn)))
        (expect (eq worktree (nerimux::client-conn-selected-worktree conn))))))

  (it "a-worktree-selection-survives-a-stable-id-catalog-refresh-with-fresh-structs"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-stable-refresh" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-stable-refresh" :organization organization
              :specification "github.com/team/repo-stable-refresh"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-stable-refresh" :repository repository
              :path "/tmp/stable-refresh" :branch "stable-refresh"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* nil))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (setf (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-selected-tree-object conn worktree)
      (let* ((new-worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-stable-refresh" :path "/tmp/stable-refresh"
                :branch "stable-refresh"))
             (new-repository
               (nerimux/workspace-model:make-repository
                :id "repo-stable-refresh"
                :specification "github.com/team/repo-stable-refresh"))
             (new-organization
               (nerimux/workspace-model:make-organization
                :id "org-stable-refresh" :host "github.com" :name "team")))
        (nerimux/workspace-model:organization-add-repository new-organization new-repository)
        (nerimux/workspace-model:repository-add-worktree new-repository new-worktree)
        (expect (not (eq new-worktree worktree)))
        (nerimux::%rebind-client-selection conn (list new-organization))
        (expect (eq new-worktree (nerimux::client-conn-selected-tree-object conn)))
        (expect (eq new-worktree (nerimux::client-conn-selected-worktree conn))))))

  (it "a-file-row-selection-re-anchors-onto-the-new-worktree-across-a-stable-id-refresh"
    (let* ((organization
             (nerimux/workspace-model:make-organization
              :id "org-stable-file-refresh" :host "github.com" :name "team"))
           (repository
             (nerimux/workspace-model:make-repository
              :id "repo-stable-file-refresh" :organization organization
              :specification "github.com/team/repo-stable-file-refresh"))
           (worktree
             (nerimux/workspace-model:make-worktree
              :id "wt-stable-file-refresh" :repository repository
              :path "/tmp/stable-file-refresh" :branch "stable-file-refresh"))
           (conn (%make-test-conn))
           (nerimux::*last-selected-worktree-token* nil)
           (file-object (list :file "wt-stable-file-refresh" "src/foo.lisp" " M")))
      (nerimux/workspace-model:organization-add-repository organization repository)
      (nerimux/workspace-model:repository-add-worktree repository worktree)
      (setf (nerimux::client-conn-view conn) :repolist)
      (nerimux::%set-client-selected-tree-object conn file-object)
      (let* ((new-worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-stable-file-refresh" :path "/tmp/stable-file-refresh"
                :branch "stable-file-refresh"))
             (new-repository
               (nerimux/workspace-model:make-repository
                :id "repo-stable-file-refresh"
                :specification "github.com/team/repo-stable-file-refresh"))
             (new-organization
               (nerimux/workspace-model:make-organization
                :id "org-stable-file-refresh" :host "github.com" :name "team")))
        (nerimux/workspace-model:organization-add-repository new-organization new-repository)
        (nerimux/workspace-model:repository-add-worktree new-repository new-worktree)
        (nerimux::%rebind-client-selection conn (list new-organization))
        (expect (eq new-worktree (nerimux::client-conn-selected-tree-object conn)))
        (expect (eq new-worktree (nerimux::client-conn-selected-worktree conn))))))

  (it "tab-key-on-a-file-row-expands-to-pending-and-dedups-the-fetch-across-collapse-reexpand"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-diff-tab" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-diff-tab" :organization organization
                :specification "github.com/team/repo-diff-tab"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-diff-tab" :repository repository :path "/tmp/diff-tab"
                :branch "diff-tab" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (wt-id (nerimux/workspace-model:worktree-id worktree))
             (file-object (list :file wt-id "src/foo.lisp" " M"))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization))
             (call-count 0))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn file-object)
        (with-stubbed-fdefinition
            ((nerimux/vcs:refresh-worktree-file-diff-async
               (lambda (repository worktree path &key on-complete on-error
                                                        callback-dispatch)
                 (declare (ignore repository worktree path on-complete on-error
                                  callback-dispatch))
                 (incf call-count)
                 nil)))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (gethash (list :file-diff wt-id "src/foo.lisp")
                           nerimux::*workspace-expanded-node-ids*))
          (expect (equal (list :pending 0 nil)
                         (gethash (list wt-id "src/foo.lisp")
                                  nerimux::*workspace-file-diffs*)))
          (expect (= 1 call-count))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (null (gethash (list :file-diff wt-id "src/foo.lisp")
                                 nerimux::*workspace-expanded-node-ids*)))
          (expect (equal (list :pending 0 nil)
                         (gethash (list wt-id "src/foo.lisp")
                                  nerimux::*workspace-file-diffs*)))
          (nerimux::%handle-multi-key-message s conn #(9))
          (expect (gethash (list :file-diff wt-id "src/foo.lisp")
                           nerimux::*workspace-expanded-node-ids*))
          (expect (= 1 call-count))))))

  (it "tab-key-on-a-file-row-shows-cached-diff-lines-without-fetching-and-collapses-on-second-tab"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization
                :id "org-diff-cached" :host "github.com" :name "team"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-diff-cached" :organization organization
                :specification "github.com/team/repo-diff-cached"))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-diff-cached" :repository repository :path "/tmp/diff-cached"
                :branch "diff-cached" :dirty-p t
                :changed-files (list (cons " M" "src/foo.lisp"))))
             (conn (%make-test-conn))
             (wt-id (nerimux/workspace-model:worktree-id worktree))
             (file-object (list :file wt-id "src/foo.lisp" " M"))
             (nerimux::*workspace-collapsed-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-expanded-node-ids* (make-hash-table :test #'equal))
             (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux::client-conn-view conn) :repolist)
        (setf (gethash (list :worktree wt-id) nerimux::*workspace-expanded-node-ids*) t)
        (setf (gethash (list wt-id "src/foo.lisp") nerimux::*workspace-file-diffs*)
              (list :ready 1 (list "+only line")))
        (nerimux::%set-client-selected-tree-object conn file-object)
        (with-stubbed-fdefinition
            ((nerimux/vcs:refresh-worktree-file-diff-async
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error "must not be reached: a :ready cache entry must not refetch"))))
          (flet ((diff-entries ()
                   (remove-if-not
                    (lambda (entry) (eq (fourth entry) :diff-line))
                    (nerimux/renderer::%workspace-flat-tree-entries
                     (list organization) nerimux::*workspace-collapsed-node-ids*
                     :expanded-node-ids nerimux::*workspace-expanded-node-ids*
                     :file-diffs nerimux::*workspace-file-diffs*))))
            (expect (null (diff-entries)))
            (nerimux::%handle-multi-key-message s conn #(9))
            (let ((entries (diff-entries)))
              (expect (= 1 (length entries)))
              (expect (string= "+only line" (second (first entries)))))
            (nerimux::%handle-multi-key-message s conn #(9))
            (expect (null (diff-entries))))))))


  (it "?-then-k-opens-the-help-view-and-swallows-other-keys-until-q-closes-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(63)) ; ?
        (expect (eq :transient (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(107)) ; k
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(110)) ; n
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(113)) ; q
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "?-then-k-also-opens-from-the-repolist-view-and-enter-or-esc-close-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(13)) ; Enter
        (expect (null (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (nerimux::%handle-multi-key-message s conn #(27)) ; Esc
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "the rendered client frame shows the help view's sections while it is up"
    (with-fake-session (s)
      (let ((conn (%make-test-conn :rows 40 :cols 110)))
        (nerimux::%handle-multi-key-message s conn #(63))
        (nerimux::%handle-multi-key-message s conn #(107))
        (multiple-value-bind (type payload)
            (nerimux/protocol::decode-frame (nerimux::%render-client-frame s conn))
          (expect (= nerimux::+msg-frame+ type))
          (let ((visible (strip-sgr (nerimux/protocol::decode-text payload))))
            (expect (search "Navigate" visible))
            (expect (search "Prefix C-q" visible))
            (expect (search "Scrollback" visible))
            (expect (null (search "Modes" visible))))))))

  (it "opening a confirm-view while modal is :help replaces it outright"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn :rows 40 :cols 110))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-modal conn) :help)
        (nerimux::%open-confirm-view conn "WORKTREE DELETE"
                                     '(("worktree" . "feature/x"))
                                     (lambda () nil))
        (expect (eq :confirm (nerimux::client-conn-modal conn)))
        (multiple-value-bind (type payload)
            (nerimux/protocol::decode-frame (nerimux::%render-client-frame s conn))
          (declare (ignore type))
          (let ((visible (strip-sgr (nerimux/protocol::decode-text payload))))
            (expect (search "WORKTREE DELETE" visible))
            (expect (not (search "Prefix C-q" visible)))))
        (nerimux::%handle-multi-key-message s conn #(110)) ; n
        (expect (not (nerimux::client-conn-confirm-view conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "?-reaches-a-focused-pane-directly-in-pane-view-instead-of-opening-the-transient"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux::window-active-pane (nerimux::session-active-window s)))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 9999)
        (setf (nerimux::client-conn-view conn) :pane
              (nerimux::client-conn-focus conn) pane)
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-write
               (lambda (fd payload) (push (list fd payload) writes))))
          (nerimux::%handle-multi-key-message s conn #(63))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (equalp (list (list 9999 #(63))) writes))))))

  (it "an-ordinary-byte-reaches-a-focused-pane-directly-in-pane-view-fr-007"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux::window-active-pane (nerimux::session-active-window s)))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 9999)
        (setf (nerimux::client-conn-view conn) :pane
              (nerimux::client-conn-focus conn) pane)
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-write
               (lambda (fd payload) (push (list fd payload) writes))))
          (nerimux::%handle-multi-key-message s conn #(110)) ; n
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (eq :pane (nerimux::client-conn-view conn)))
          (expect (equalp (list (list 9999 #(110))) writes))))))

  (it "a-modal-owns-the-key-and-the-view-underneath-never-sees-it"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist
              (nerimux::client-conn-modal conn) :help)
        (nerimux::%handle-multi-key-message s conn #(110)) ; n: "next row" in :repolist
        (expect (eq :help (nerimux::client-conn-modal conn)))
        (expect (null (nerimux::client-conn-selected-tree-object conn))))))

  (it "a single repository's status failure marks only that repository stale, not the whole catalog"
    (let* ((healthy-path (%vcs-operations-existing-path))
           (failing-path
             (namestring
              (merge-pathnames "nerimux-bug2-failing-status/"
                               (host-kit:temporary-directory))))
           (healthy-entry
             (vcs-kit:make-ghq-repository-entry
              :specification "bug2-host/team/healthy" :path healthy-path))
           (failing-entry
             (vcs-kit:make-ghq-repository-entry
              :specification "bug2-host/team/failing" :path failing-path))
           (available (fdefinition 'nerimux/vcs:vcs-package-available-p)))
      (ensure-directories-exist failing-path)
      (let ((nerimux::*workspace-catalog-loaded-p* nil)
            (nerimux::*workspace-scan-progress* nil)
            (nerimux::*workspace-refreshing-ids* (make-hash-table :test #'equal))
            (nerimux::*workspace-stale-ids* (make-hash-table :test #'equal))
            (nerimux::*clients* nil)
            (nerimux::*dirty* nil)
            (nerimux/vcs::*workspace-organizations* nil)
            (nerimux::*workspace-file-diffs* (make-hash-table :test #'equal))
            (nerimux::*workspace-file-diffs-order* nil)
            (conn (nerimux::%make-client-conn)))
        (unwind-protect
             (progn
               (setf nerimux::*main-thread-callbacks* nil)
               (setf (fdefinition 'nerimux/vcs:vcs-package-available-p)
                     (lambda () t))
               (with-stubbed-fdefinition
                   ((vcs-kit:ghq-list-repositories
                      (lambda (&key query)
                        (declare (ignore query))
                        (list healthy-entry failing-entry)))
                    (vcs-kit:make-vcs-repository
                      (lambda (directory &rest arguments)
                        (declare (ignore arguments))
                        directory))
                    (vcs-kit:vcs-list-worktrees
                      (lambda (directory)
                        (list (%vcs-operations-fake-worktree
                               directory :branch "main" :head "head"))))
                    (vcs-kit:vcs-status-structured
                      (lambda (directory &rest arguments)
                        (declare (ignore arguments))
                        (if (string= directory failing-path)
                            (error "synthetic status failure for BUG-2")
                            (%vcs-operations-status-snapshot
                             :branch-head "head" :ahead 0 :behind 0)))))
                 (nerimux::%refresh-client-picker conn)
                 (let ((deadline (+ (get-internal-real-time)
                                    (* 2 internal-time-units-per-second))))
                   (loop until (and (plusp (length (nerimux/vcs:workspace-organizations)))
                                    (zerop (hash-table-count
                                            nerimux::*workspace-refreshing-ids*)))
                         while (< (get-internal-real-time) deadline)
                         do (nerimux::%drain-main-thread-callbacks)
                            (sleep 0.01))
                   (nerimux::%drain-main-thread-callbacks))
                 (expect (plusp (length (nerimux/vcs:workspace-organizations))))
                 (expect (zerop (hash-table-count nerimux::*workspace-refreshing-ids*)))
                 (let* ((organizations (nerimux/vcs:workspace-organizations))
                        (repositories
                          (and organizations
                               (nerimux/workspace-model:organization-repositories
                                (first organizations))))
                        (healthy-repository
                          (find healthy-path repositories
                                :key #'nerimux/workspace-model:repository-local-path
                                :test #'string=))
                        (failing-repository
                          (find failing-path repositories
                                :key #'nerimux/workspace-model:repository-local-path
                                :test #'string=)))
                   (expect healthy-repository)
                   (expect failing-repository)
                   (expect (gethash (list :repository
                                          (nerimux/workspace-model:repository-id
                                           failing-repository))
                                    nerimux::*workspace-stale-ids*))
                   (dolist (worktree (nerimux/workspace-model:repository-worktrees
                                      failing-repository))
                     (expect (gethash (list :worktree
                                            (nerimux/workspace-model:worktree-id worktree))
                                      nerimux::*workspace-stale-ids*)))
                   (expect (not (gethash (list :repository
                                               (nerimux/workspace-model:repository-id
                                                healthy-repository))
                                         nerimux::*workspace-stale-ids*)))
                   (dolist (worktree (nerimux/workspace-model:repository-worktrees
                                      healthy-repository))
                     (expect (not (gethash (list :worktree
                                                 (nerimux/workspace-model:worktree-id worktree))
                                           nerimux::*workspace-stale-ids*)))))))
          (setf (fdefinition 'nerimux/vcs:vcs-package-available-p) available)
          (setf nerimux::*main-thread-callbacks* nil)
          (ignore-errors (sb-posix:rmdir failing-path))))))


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
        (expect (eq :confirm (nerimux::client-conn-modal conn))))))

  (it "overview-status-key-opens-the-selected-worktree-status-view"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization :id "org-status"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-status" :organization organization))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-status" :repository repository
                :path "/tmp/wt-status" :branch "main"))
             (conn (%make-test-conn))
             (nerimux/vcs::*workspace-organizations* (list organization)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (nerimux::%set-client-selected-tree-object conn repository)
        (nerimux::%handle-multi-key-message s conn "v")
        (expect (eq :status (nerimux::client-conn-view conn)))
        (expect (eq worktree (nerimux::client-conn-selected-worktree conn))))))

  (it "overview-status-key-reports-when-no-worktree-is-selected"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (message nil))
        (with-stubbed-fdefinition
            ((nerimux::%client-notify
               (lambda (received-conn received-message)
                 (declare (ignore received-conn))
                 (setf message received-message))))
          (nerimux::%handle-multi-key-message s conn "v"))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (expect (string= "select a worktree first" message)))))

  (it "overview-status-key-resolves-repository-fallback-and-pane-worktrees"
    (with-fake-session (s)
      (let* ((organization
               (nerimux/workspace-model:make-organization :id "org-status-fallback"))
             (repository
               (nerimux/workspace-model:make-repository
                :id "repo-status-fallback" :organization organization))
             (worktree
               (nerimux/workspace-model:make-worktree
                :id "wt-status-fallback" :repository repository
                :path "/tmp/wt-status-fallback" :branch "feature/fallback"))
             (pane (make-no-pty-pane 71 0 0 20 5))
             (conn (%make-test-conn)))
        (nerimux/workspace-model:organization-add-repository organization repository)
        (nerimux/workspace-model:repository-add-worktree repository worktree)
        (setf (nerimux/workspace-model:repository-main-worktree repository) nil)
        (nerimux::%set-client-selected-tree-object conn repository)
        (expect (nerimux::%client-show-selected-status conn))
        (expect (eq :status (nerimux::client-conn-view conn)))
        (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (setf (nerimux/pane:pane-worktree pane) worktree)
        (nerimux::%set-client-selected-tree-object conn pane)
        (expect (nerimux::%client-show-selected-status conn))
        (expect (eq worktree (nerimux::client-conn-selected-worktree conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%set-client-selected-tree-object conn worktree)
        (expect (nerimux::%client-show-selected-status conn))
        (expect (eq :status (nerimux::client-conn-view conn)))
        (expect (eq worktree (nerimux::client-conn-selected-worktree conn))))))

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

(describe "worktree-arrow-input-suite"
  (it "worktree-arrows-route-both-views-across-every-payload-split"
    (with-fake-session (s)
      (dolist (view '(:repolist :status))
        (dolist (direction '((65 -1) (66 1)))
          (dolist (cuts '((3) (1 2) (2 1) (1 1 1)))
            (let ((conn (%make-test-conn))
                  (nerimux::*client-meta-pending* (make-hash-table :test #'eq))
                  (calls nil)
                  (payload (vector 27 91 (first direction))))
              (setf (nerimux::client-conn-view conn) view)
              (with-stubbed-fdefinition
                  ((nerimux::%select-client-tree-relative
                     (lambda (received-conn delta)
                       (push (list received-conn delta) calls))))
                (loop with start = 0
                      for size in cuts
                      do (nerimux::%handle-multi-key-message
                          s conn (subseq payload start (+ start size)))
                         (incf start size)))
              (expect (equal (list (list conn (second direction))) calls))
              (expect (null (gethash conn nerimux::*client-meta-pending*)))
              (expect (null (nerimux::client-conn-modal conn)))))))))

  (it "worktree-arrows-preserve-meta-visibility-and-swallow-unknown-tails"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*client-meta-pending* (make-hash-table :test #'eq))
            (calls nil))
        (setf (nerimux::client-conn-view conn) :repolist)
        (with-stubbed-fdefinition
            ((nerimux::%select-client-tree-relative
               (lambda (received-conn delta)
                 (declare (ignore received-conn))
                 (push (list :row delta) calls)))
             (nerimux::%select-client-tree-section-relative
               (lambda (received-conn delta)
                 (declare (ignore received-conn))
                 (push (list :section delta) calls)))
             (nerimux::%client-prune-workspaces
               (lambda (received-conn &key all)
                 (push (list :prune received-conn all) calls)
                 t)))
          (nerimux::%handle-multi-key-message s conn #(27 110))
          (nerimux::%handle-multi-key-message s conn #(27))
          (nerimux::%handle-multi-key-message s conn #(112))
          (expect (equal '((:section -1) (:section 1)) calls))
          (let ((before (nerimux::client-conn-visibility-level conn)))
            (nerimux::%handle-multi-key-message s conn #(27 91 90))
            (expect (= (1+ (mod before 4))
                       (nerimux::client-conn-visibility-level conn))))
          (setf calls nil)
          (dolist (tail '(67 68 80 110 112))
            (nerimux::%handle-multi-key-message s conn #(27))
            (nerimux::%handle-multi-key-message s conn (vector 91 tail))
            (expect (null calls))
            (expect (null (nerimux::client-conn-modal conn)))
            (expect (null (gethash conn nerimux::*client-meta-pending*))))
          (nerimux::%handle-multi-key-message s conn #(112))
          (expect (equal (list (list :prune conn nil)) calls))
          (nerimux::%handle-multi-key-message s conn #(27 91 65))
          (expect (equal (list '(:row -1) (list :prune conn nil)) calls))))))

  (it "worktree-arrow-decoding-leaves-pane-payloads-intact"
    (with-fake-two-pane-session (s)
      (let* ((conn (%make-test-conn))
             (win (first (nerimux/session:session-windows s)))
             (pane (first (nerimux/window:window-panes win)))
             (nerimux::*client-meta-pending* (make-hash-table :test #'eq))
             (calls nil))
        (nerimux::%set-client-focus conn pane)
        (with-stubbed-fdefinition
            ((nerimux/pane:pane-feed
               (lambda (received-pane bytes)
                 (push (list received-pane bytes) calls))))
          (dolist (payload '(#(27 91 66) #(27) #(91) #(65)))
            (nerimux::%handle-multi-key-message s conn payload)))
        (expect (equalp (list (list pane #(65)) (list pane #(91))
                             (list pane #(27)) (list pane #(27 91 66)))
                        calls))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect (null (gethash conn nerimux::*client-meta-pending*)))))))

(describe "transient data and process log suite"
          (it "covers-meta-sequence-and-process-log-boundaries"
              (with-fake-session (s)
                                 (let ((conn (%make-test-conn))
                                       (nerimux::*client-meta-pending*
                                        (make-hash-table :test #'eq)))
                                   (dolist (key '(#\n #\p))
                                     (setf (gethash conn
                                                    nerimux::*client-meta-pending*) :second)
                                     (nerimux::%client-meta-pending-consume conn
                                                                            (string
                                                                             key))
                                     (expect
                                      (null
                                       (gethash conn
                                                nerimux::*client-meta-pending*))))
                                   (setf (gethash conn
                                                  nerimux::*client-meta-pending*) :second)
                                   (nerimux::%client-meta-pending-consume conn
                                                                          "[")
                                   (expect
                                    (eq :csi-third
                                        (gethash conn
                                                 nerimux::*client-meta-pending*)))
                                   (nerimux::%client-meta-pending-consume conn
                                                                          "Z")
                                   (expect
                                    (null
                                     (gethash conn
                                              nerimux::*client-meta-pending*)))
                                   (setf (gethash conn
                                                  nerimux::*client-meta-pending*) :csi-third)
                                   (nerimux::%client-meta-pending-consume conn
                                                                          "A")
                                   (expect
                                    (null
                                     (gethash conn
                                              nerimux::*client-meta-pending*)))
                                   (setf (nerimux::client-conn-process-log conn) '("one"
                                                                                   "two"))
                                   (nerimux::%scroll-client-process-log conn 99)
                                   (expect
                                    (= 1
                                       (nerimux::client-conn-process-log-scroll
                                        conn)))
                                   (nerimux::%scroll-client-process-log conn
                                                                        -99)
                                   (expect
                                    (zerop
                                     (nerimux::client-conn-process-log-scroll
                                      conn))))))
          (it "covers-visibility-and-process-log-state-machines"
              (with-fake-session (s)
                                 (let ((conn (%make-test-conn)))
                                   (expect
                                    (nerimux::%client-set-visibility-level conn
                                                                           0))
                                   (expect
                                    (= 2
                                       (nerimux::client-conn-visibility-level
                                        conn)))
                                   (dolist (expected '(3 4 1 2))
                                     (nerimux::%client-cycle-visibility conn)
                                     (expect
                                      (= expected
                                         (nerimux::client-conn-visibility-level
                                          conn))))
                                   (nerimux::%client-cycle-visibility conn)
                                   (expect
                                    (= 3
                                       (nerimux::client-conn-visibility-level
                                        conn)))
                                   (setf (nerimux::client-conn-process-log conn) (list
                                                                                  "first"
                                                                                  "second"
                                                                                  "third"))
                                   (nerimux::%handle-process-log-key conn "n")
                                   (expect
                                    (= 1
                                       (nerimux::client-conn-process-log-scroll
                                        conn)))
                                   (nerimux::%handle-process-log-key conn "p")
                                   (expect
                                    (= 0
                                       (nerimux::client-conn-process-log-scroll
                                        conn)))
                                   (setf (nerimux::client-conn-modal conn) :process-log)
                                   (nerimux::%handle-process-log-key conn #(27))
                                   (expect
                                    (null (nerimux::client-conn-modal conn)))
                                   (expect
                                    (nerimux::%client-esc-swallow-consume conn))
                                   (expect
                                    (nerimux::%client-esc-swallow-consume conn))
                                   (expect
                                    (null
                                     (nerimux::%client-esc-swallow-consume conn)))
                                   (setf (nerimux::client-conn-modal conn) :process-log)
                                   (nerimux::%handle-multi-key-message s
                                                                       conn
                                                                       "q")
                                   (expect
                                    (null (nerimux::client-conn-modal conn)))
                                   (setf (nerimux::client-conn-view conn) :status)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (eq :repolist
                                        (nerimux::client-conn-view conn))))))
          (it "steps-back-through-transient-filter-and-live-focus-boundaries"
              (with-fake-session (s)
                                 (let* ((conn (%make-test-conn))
                                        (pane (first (nerimux::all-panes s))))
                                   (setf (nerimux::client-conn-modal conn) :transient
                                         (nerimux::client-conn-transient-view
                                          conn) :transient-data)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (null (nerimux::client-conn-modal conn)))
                                   (expect
                                    (null
                                     (nerimux::client-conn-transient-view conn)))
                                   (setf (nerimux::client-conn-tree-filter conn) "feature"
                                         (nerimux::client-conn-view conn) :status)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (null
                                     (nerimux::client-conn-tree-filter conn)))
                                   (expect
                                    (eq :status
                                        (nerimux::client-conn-view conn)))
                                   (setf (nerimux::client-conn-focus conn) pane)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (eq :pane (nerimux::client-conn-view conn)))
                                   (setf (nerimux::client-conn-view conn) :repolist
                                         (nerimux::client-conn-focus conn) nil)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (eq :repolist
                                        (nerimux::client-conn-view conn)))
                                   (setf (nerimux::client-conn-focus conn) pane)
                                   (nerimux::%client-step-back s conn)
                                   (expect
                                    (eq :pane (nerimux::client-conn-view conn))))))
          (it "transient-command-data-and-process-log-share-stable-contracts"
              (with-fake-session (s)
                                 (let ((conn (%make-test-conn)))
                                   (dolist 
                                       (definition
                                        nerimux::+transient-definitions+)
                                     (let ((menu (cdr definition)))
                                       (expect (characterp (car definition)))
                                       (expect (stringp (first menu)))
                                       (expect (listp (second menu)))
                                       (dolist (action (third menu))
                                         (expect (characterp (first action)))
                                         (expect (stringp (second action)))
                                         (expect
                                          (member (first (third action))
                                                  '(:git :call
                                                         :open-transient
                                                         :help
                                                         :stub))))))
                                   (expect
                                    (string= "git push --force"
                                             (nerimux::%transient-command-text
                                              :push
                                              '("--force"))))
                                   (expect
                                    (null (nerimux::%transient-branch conn)))
                                   (expect
                                    (null
                                     (nerimux::%transient-subtitle #\P conn)))
                                   (expect
                                    (string= "on ?"
                                             (nerimux::%transient-action-display-description
                                              conn
                                              "on ~A")))
                                   (expect
                                    (equal '((#\f "--force" "--force" nil #\P))
                                           (nerimux::%transient-render-arguments
                                            #\P
                                            conn
                                            '((#\f . "--force")))))
                                   (nerimux::%client-transient-toggle-flag conn
                                                                           #\P
                                                                           "--force")
                                   (expect
                                    (equal '("--force")
                                           (nerimux::%client-transient-active-flags
                                            conn
                                            #\P)))
                                   (nerimux::%client-transient-toggle-flag conn
                                                                           #\P
                                                                           "--force")
                                   (expect
                                    (null
                                     (nerimux::%client-transient-active-flags
                                      conn
                                      #\P)))
                                   (dotimes 
                                       (index
                                        (1+ nerimux::+max-process-log-entries+))
                                     (nerimux::%client-log-process conn
                                                                   (format nil
                                                                           "git ~D"
                                                                           index)
                                                                   t
                                                                   nil))
                                   (expect
                                    (= nerimux::+max-process-log-entries+
                                       (length
                                        (nerimux::client-conn-process-log conn))))
                                   (expect
                                    (equal '("git 20" "0" "")
                                           (first
                                            (nerimux::client-conn-process-log
                                             conn)))))))
          (it "transient-rendering-and-dismissal-cover-the-modal-contract"
              (with-fake-session (s)
                                 (let ((conn (%make-test-conn)))
                                   (expect
                                    (null
                                     (nerimux::%open-client-transient conn #\~)))
                                   (expect
                                    (nerimux::%open-client-transient conn #\P))
                                   (let ((view
                                          (nerimux::client-conn-transient-view
                                           conn)))
                                     (expect
                                      (eq :transient
                                          (nerimux::client-conn-modal conn)))
                                     (expect
                                      (string= "Push"
                                               (nerimux/renderer:transient-view-title
                                                view)))
                                     (expect
                                      (equal '(#\p #\e)
                                             (mapcar #'first
                                                     (nerimux/renderer:transient-view-actions
                                                      view)))))
                                   (nerimux::%handle-client-transient-key-payload
                                    s
                                    conn
                                    #(102))
                                   (expect
                                    (equal '("--force-with-lease")
                                           (nerimux::%client-transient-active-flags
                                            conn
                                            #\P)))
                                   (nerimux::%run-transient-action s
                                                                   conn
                                                                   (list
                                                                    :open-transient
                                                                    #\P))
                                   (expect
                                    (eq :transient
                                        (nerimux::client-conn-modal conn)))
                                   (nerimux::%run-transient-action s
                                                                   conn
                                                                   (list :git
                                                                         #\P
                                                                         :push
                                                                         nil
                                                                         nil
                                                                         nil))
                                   (expect
                                    (null (nerimux::client-conn-modal conn)))
                                   (nerimux::%handle-client-transient-key-payload
                                    s
                                    conn
                                    #(122))
                                   (nerimux::%handle-client-transient-key-payload
                                    s
                                    conn
                                    #(113))
                                   (expect
                                    (null (nerimux::client-conn-modal conn)))
                                   (nerimux::%open-client-transient conn #\P)
                                   (nerimux::%handle-client-transient-key-payload
                                    s
                                    conn
                                    #(27))
                                   (expect
                                    (null
                                     (nerimux::client-conn-transient-view conn))))))
          (it
           "transient-actions-cover-preconditions-confirmation-and-direct-execution"
           (with-fake-session (s)
                              (let ((conn (%make-test-conn))
                                    (nerimux::*clients* nil))
                                (setf nerimux::*clients* (list conn))
                                (nerimux::%run-transient-git-action conn
                                                                    #\P
                                                                    :push
                                                                    nil
                                                                    nil
                                                                    nil)
                                (expect
                                 (equal "no repository selected"
                                        (first
                                         (nerimux::client-conn-message-log conn))))
                                (let* ((organization
                                        (nerimux/workspace-model:make-organization
                                         :id
                                         "org-transient"
                                         :host
                                         "github.com"
                                         :name
                                         "team"))
                                       (repository
                                        (nerimux/workspace-model:make-repository
                                         :id
                                         "repo-transient"
                                         :organization
                                         organization
                                         :specification
                                         "github.com/team/repo-transient"))
                                       (calls nil))
                                  (nerimux/workspace-model:organization-add-repository
                                   organization
                                   repository)
                                  (nerimux::%set-client-selected-tree-object
                                   conn
                                   repository)
                                  (with-stubbed-fdefinition
                                   ((nerimux/vcs:vcs-package-available-p
                                     (lambda ()
                                       nil)))
                                   (nerimux::%run-transient-git-action conn
                                                                       #\P
                                                                       :push
                                                                       nil
                                                                       nil
                                                                       nil)
                                   (expect
                                    (equal "VCS adapter unavailable"
                                           (first
                                            (nerimux::client-conn-message-log
                                             conn)))))
                                  (with-stubbed-fdefinition
                                   ((nerimux/vcs:vcs-package-available-p
                                     (lambda ()
                                       t))
                                    (nerimux::%refresh-client-picker
                                     (lambda (ignored-connection)
                                       (declare (ignore ignored-connection))))
                                    (nerimux/vcs:git-write-operation-async
                                     (lambda 
                                         (received operation
                                                   args
                                                   &key
                                                   on-complete
                                                   on-error
                                                   callback-dispatch)
                                       (declare (ignore callback-dispatch
                                                        on-error))
                                       (push (list received operation args)
                                             calls)
                                       (funcall on-complete t "done")
                                       t)))
                                   (nerimux::%run-transient-git-action conn
                                                                       #\P
                                                                       :push
                                                                       '("--force")
                                                                       t
                                                                       nil)
                                   (expect
                                    (eq :confirm
                                        (nerimux::client-conn-modal conn)))
                                   (funcall
                                    (nerimux::client-conn-confirm-action conn))
                                   (expect
                                    (equal
                                     (list (list repository :push '("--force")))
                                     calls))
                                   (nerimux::%run-transient-git-action conn
                                                                       #\P
                                                                       :push
                                                                       nil
                                                                       nil
                                                                       nil)
                                   (expect (= 2 (length calls)))
                                   (nerimux::%client-transient-toggle-flag conn
                                                                           #\P
                                                                           "--force")
                                   (nerimux::%run-transient-git-action conn
                                                                       #\P
                                                                       :push
                                                                       nil
                                                                       nil
                                                                       '("--force"))
                                   (expect
                                    (eq :confirm
                                        (nerimux::client-conn-modal conn)))
                                   (funcall
                                    (nerimux::client-conn-confirm-action conn))
                                   (expect (= 3 (length calls)))
                                   (nerimux::%client-transient-toggle-flag conn
                                                                           #\P
                                                                           "--force")))
                                (with-stubbed-fdefinition
                                    ((nerimux/vcs:vcs-package-available-p (lambda () t))
                                     (nerimux/vcs:git-write-operation-async
                                      (lambda (received operation args &key on-complete
                                                       on-error callback-dispatch)
                                        (declare (ignore received operation args on-error
                                                                callback-dispatch))
                                        (funcall on-complete nil "failed"))))
                                  (nerimux::%run-transient-git-action conn #\P :push nil nil nil)
                                  (expect (string= "git push: failed"
                                                   (first (nerimux::client-conn-message-log conn)))))
                                (multiple-value-bind (repository worktree
                                                                 ignored-conn) 
                                    (%make-worktree-operation-fixture)
                                  (declare (ignore repository ignored-conn))
                                  (nerimux::%set-client-selected-tree-object
                                   conn
                                   worktree)
                                  (expect
                                   (string=
                                    "feature/errors -> origin/feature/errors"
                                    (nerimux::%transient-subtitle #\P conn)))
                                (expect
                                 (string= "on feature/errors"
                                          (nerimux::%transient-subtitle #\x
                                                                        conn)))))))
          (it "records transient write failures through the shared process log"
              (with-fake-session (s)
                (let ((conn (%make-test-conn))
                      (nerimux::*clients* nil))
                  (setf nerimux::*clients* (list conn))
                  (multiple-value-bind (repository ignored-worktree ignored-conn)
                      (%make-worktree-operation-fixture)
                    (declare (ignore ignored-worktree ignored-conn))
                    (nerimux::%set-client-selected-tree-object conn repository)
                    (with-stubbed-fdefinition
                        ((nerimux/vcs:vcs-package-available-p (lambda () t))
                         (nerimux/vcs:git-write-operation-async
                           (lambda (received operation args &key on-complete on-error
                                            callback-dispatch)
                             (declare (ignore received operation args on-complete
                                                     callback-dispatch))
                             (funcall on-error (make-condition 'simple-error
                                                               :format-control "boom")))))
                      (nerimux::%run-transient-git-action conn #\P :push nil nil nil)
                      (expect (equal '("git push" "1" "boom")
                                     (first (nerimux::client-conn-process-log conn))))
                      (expect (string= "git push: failed: boom"
                                       (first (nerimux::client-conn-message-log conn))))))))))

(describe "client frame dispatch contract suite"
          (it "renders every modal and base view through one frame boundary"
              (with-fake-session (s)
                                 (let ((conn
                                        (%make-test-conn :rows 40 :cols 110)))
                                   (dolist (modal '(:help :process-log :picker))
                                     (setf (nerimux::client-conn-modal conn) modal)
                                     (when (eq modal :process-log)
                                       (setf (nerimux::client-conn-process-log
                                              conn) '(("git status" 0 ""))))
                                     (expect
                                      (nerimux::%render-client-frame s conn)
                                      :to-be-truthy))
                                   (nerimux::%open-client-transient conn #\P)
                                   (expect
                                    (nerimux::%render-client-frame s conn)
                                    :to-be-truthy)
                                   (setf (nerimux::client-conn-view conn) :status)
                                   (expect
                                    (nerimux::%render-client-frame s conn)
                                    :to-be-truthy)
                                   (setf (nerimux::client-conn-modal conn) nil)
                                   (dolist (view '(:repolist :status :pane))
                                     (setf (nerimux::client-conn-view conn) view)
                                     (expect
                                      (nerimux::%render-client-frame s conn)
                                      :to-be-truthy))))))

          (describe "ui command dispatch contract"
            (it "ui-command-dispatches-argument-fallbacks-and-picker-actions"
              (with-fake-session (s)
                (let ((conn (%make-test-conn))
                      (calls nil))
                  (with-stubbed-fdefinition
                      ((nerimux::%client-attach-target
                         (lambda (client args)
                           (declare (ignore client))
                           (push (list :attach args) calls)))
                       (nerimux::%client-refresh-workspace
                         (lambda (client)
                           (declare (ignore client))
                           (push :refresh calls)))
                       (nerimux::%select-client-tree-worktree
                         (lambda (client selector)
                           (declare (ignore client))
                           (push (list :select selector) calls)))
                       (nerimux::%open-client-picker
                         (lambda (client)
                           (declare (ignore client))
                           (push :open calls)))
                       (nerimux::%close-client-picker
                         (lambda (client)
                           (declare (ignore client))
                           (push :close calls)))
                       (nerimux::%transition-client-ui-mode
                       (lambda (client mode)
                           (declare (ignore client))
                           (push (list :mode mode) calls)))
                       (nerimux::%client-rebind-prefix
                         (lambda (client prefix)
                           (declare (ignore client))
                           (push (list :prefix prefix) calls)))
                       (nerimux::%select-client-tree-relative
                         (lambda (client delta)
                           (declare (ignore client))
                           (push (list :tree delta) calls)))
                       (nerimux::%move-client-picker-index
                         (lambda (client delta)
                           (declare (ignore client))
                           (push (list :picker delta) calls)))
                       (nerimux::%mark-dirty
                         (lambda ()
                           (push :dirty calls))))
                    (dolist (command '((:attach-target nil ("team/repo"))
                                       (:workspace-refresh nil nil)
                                       (:workspace-prefix nil ("C-x"))
                                       (:tree-select nil ("team/repo"))
                                       (:tree-next nil ("2"))
                                       (:picker-open nil nil)
                                       (:picker-close nil nil)
                                       (:mode nil ("input"))
                                       (:picker-next nil ("2"))))
                      (destructuring-bind (name target args) command
                        (expect (nerimux::%handle-client-ui-command
                                 s conn name target args))))
                    (expect (equal '((:picker 2) :dirty (:mode :input) :close :open
                                     (:tree 2) (:select "team/repo") (:prefix "C-x")
                                     :refresh (:attach ("team/repo")))
                                   calls)))))))
