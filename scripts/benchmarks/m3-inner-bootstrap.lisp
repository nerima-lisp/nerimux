(progn
  (defvar *m3-inner-original-read-frame* nil)
  (defvar *m3-inner-original-dispatch* nil)
  (defvar *m3-inner-original-flat-entries* nil)
  (defvar *m3-inner-original-render* nil)
  (defvar *m3-inner-original-send* nil)
  (defvar *m3-inner-render-conn* nil)
  (defvar *m3-inner-render-entries* nil)
  (defvar *m3-inner-render-records* (make-hash-table :test #'eq))
  (defvar *m3-inner-pending* nil)
  (defvar *m3-inner-root-summary* nil)

  (defun m3-inner-directory-summary ()
    (let* ((root (uiop:getenv "GHQ_ROOT"))
           (present (and root (plusp (length root))))
           (directory-p (and present (uiop:directory-exists-p root)))
           (entry-count
             (if directory-p
                 (length (uiop:subdirectories
                          (uiop:ensure-directory-pathname root)))
                 0)))
      (list :present-p (not (null present))
            :directory-p (not (null directory-p))
            :entry-count entry-count)))

  (defun m3-inner-visible-entries (entries rows scroll)
    (let* ((tree-rows
             (max 1 (nerimux/renderer:workspace-tree-view-rows rows)))
           (tree-count (length entries))
           (max-scroll (max 0 (- tree-count tree-rows)))
           (start (min (max 0 (min scroll max-scroll)) tree-count))
           (end (min (+ start tree-rows) tree-count)))
      (subseq entries start end)))

  (defun m3-inner-selected-state (record)
    (let* ((entries (getf record :entries))
           (visible
             (m3-inner-visible-entries
              entries (getf record :rows) (getf record :tree-scroll)))
           (selected (getf record :selected-object))
           (selected-index
             (position-if
              (lambda (entry)
                (and (eq (third entry) selected)
                     (member (fourth entry)
                             '(:organization :repository :worktree)
                             :test #'eq)))
              entries))
           (visible-index
             (position-if
              (lambda (entry)
                (and (eq (third entry) selected)
                     (member (fourth entry)
                             '(:organization :repository :worktree)
                             :test #'eq)))
              visible))
           (selected-entry (and visible-index (nth visible-index visible)))
           (visible-selectable-count
             (count-if
              (lambda (entry)
                (member (fourth entry)
                        '(:organization :repository :worktree)
                        :test #'eq))
              visible)))
      (list :selected-visible-p (not (null visible-index))
            :selected-index (and selected-index (1+ selected-index))
            :selected-visible-ordinal (and visible-index (1+ visible-index))
            :selected-kind (and selected-entry (fourth selected-entry))
            :tree-entry-count (length entries)
            :visible-tree-entry-count (length visible)
            :visible-selectable-row-count visible-selectable-count)))

  (defun m3-inner-flat-entries (&rest arguments)
    (let ((values
            (multiple-value-list
             (apply *m3-inner-original-flat-entries* arguments))))
      (when *m3-inner-render-conn*
        (setf *m3-inner-render-entries* (first values)))
      (values-list values)))

  (defun m3-inner-render-client-frame (session conn)
    (let ((*m3-inner-render-conn* conn)
          (*m3-inner-render-entries* nil))
      (let* ((frame (funcall *m3-inner-original-render* session conn))
             (record
               (list :frame frame
                     :candidate
                     (nerimux::client-conn-row-frame-candidate conn)
                     :entries *m3-inner-render-entries*
                     :selected-object (nerimux::%client-tree-object conn)
                     :rows (nerimux::client-conn-rows conn)
                     :tree-scroll (nerimux::client-conn-tree-scroll conn)
                     :view (nerimux::client-conn-view conn)
                     :modal (nerimux::client-conn-modal conn))))
        (setf (gethash conn *m3-inner-render-records*)
              (append record (m3-inner-selected-state record)))
        frame)))

  (defun m3-inner-key-n-p (type payload)
    (and (eql type nerimux::+msg-key+)
         (vectorp payload)
         (= (length payload) 1)
         (eql (aref payload 0) 110)))

  (defun m3-inner-target-key-p (type payload conn)
    (and (m3-inner-key-n-p type payload)
         (eq (nerimux::client-conn-view conn) :repolist)
         (null (nerimux::client-conn-modal conn))))

  (defun m3-inner-armed-connection-p (conn record root)
    (let ((sent (nerimux::client-conn-sent-row-frame conn)))
      (and record
           (getf record :selected-visible-p)
           (eq (getf record :view) :repolist)
           (null (getf record :modal))
           (getf record :candidate)
           sent
           (eq (getf record :frame) (first sent))
           (eq (getf record :frame) (first (getf record :candidate)))
           (getf root :present-p)
           (getf root :directory-p)
           (plusp (getf root :entry-count)))))

  (defun m3-inner-read-frame (stream)
    (let* ((values
             (multiple-value-list
              (funcall *m3-inner-original-read-frame* stream)))
           (type (first values))
           (payload (second values)))
      (when (and (null *m3-inner-pending*)
                 (m3-inner-key-n-p type payload))
        (let ((conn
                (find stream nerimux::*clients*
                      :key #'nerimux::client-conn-stream
                      :test #'eq)))
          (when (and conn (m3-inner-target-key-p type payload conn))
            (let ((received-tick (get-internal-real-time))
                  (received-wall (get-universal-time)))
              (let* ((record (gethash conn *m3-inner-render-records*))
                     (root *m3-inner-root-summary*))
                (when (m3-inner-armed-connection-p conn record root)
                  (setf *m3-inner-pending*
                        (list :conn conn
                              :payload payload
                              :received-tick received-tick
                              :received-wall received-wall
                              :before-record record
                              :before-snapshot
                              (third (nerimux::client-conn-sent-row-frame conn))
                              :dispatch-seen-p nil
                              :dispatch-returned-p nil))))))))
      (values-list values)))

  (defun m3-inner-handle-client-message (type payload session conn)
    (let ((pending *m3-inner-pending*))
      (when (and pending
                 (eq conn (getf pending :conn))
                 (eq payload (getf pending :payload))
                 (m3-inner-target-key-p type payload conn))
        (setf (getf pending :dispatch-seen-p) t
              (getf pending :dispatch-tick) (get-internal-real-time)
              (getf pending :dispatch-wall) (get-universal-time)))
      (let ((values
              (multiple-value-list
               (funcall *m3-inner-original-dispatch*
                        type payload session conn))))
        (when (and pending
                   (eq pending *m3-inner-pending*)
                   (eq conn (getf pending :conn))
                   (getf pending :dispatch-seen-p))
          (setf (getf pending :dispatch-returned-p) t
                (getf pending :dispatch-return-tick)
                (get-internal-real-time)
                (getf pending :dispatch-return-wall)
                (get-universal-time)))
        (values-list values))))

  (defun m3-inner-kind-name (kind)
    (case kind
      (:organization "organization")
      (:repository "repository")
      (:worktree "worktree")
      (t "none")))

  (defun m3-inner-finish (conn frame record pending sent-tick sent-wall)
    (let* ((sent (nerimux::client-conn-sent-row-frame conn))
           (candidate (getf record :candidate))
           (after-snapshot (and sent (third sent)))
           (before-record (getf pending :before-record))
           (root *m3-inner-root-summary*)
           (same-connection-p (eq conn (getf pending :conn)))
           (frame-sent-p (and sent (eq frame (first sent))))
           (frame-changed-p
             (and frame-sent-p
                  (not (equal (getf pending :before-snapshot)
                              after-snapshot))))
           (selection-changed-p
             (not (eq (getf before-record :selected-object)
                      (getf record :selected-object))))
           (visible-row-p (getf record :selected-visible-p))
           (valid
             (and same-connection-p
                  (getf pending :dispatch-seen-p)
                  (getf pending :dispatch-returned-p)
                  frame-sent-p
                  candidate
                  (eq frame (first candidate))
                  frame-changed-p
                  selection-changed-p
                  visible-row-p
                  (plusp (getf (m3-inner-selected-state before-record)
                               :visible-selectable-row-count))
                  (plusp (getf record :visible-selectable-row-count))
                  (getf root :present-p)
                  (getf root :directory-p)
                  (plusp (getf root :entry-count))
                  (let* ((before-index (getf before-record :selected-index))
                         (after-index (getf record :selected-index))
                         (expected-entry
                           (and before-index
                                (nth before-index (getf before-record :entries))))
                         (expected-object
                           (and expected-entry (third expected-entry)))
                         (next-row-index (and before-index (1+ before-index)))
                         (target-row-selected-p
                           (and before-index
                                after-index
                                next-row-index
                                (= after-index next-row-index)
                                expected-object
                                (eq expected-object
                                    (getf record :selected-object)))))
                    target-row-selected-p))))
      (when valid
        (let* ((receive-seconds
                 (/ (- sent-tick (getf pending :received-tick))
                    (float internal-time-units-per-second)))
               (dispatch-seconds
                 (/ (- sent-tick (getf pending :dispatch-tick))
                    (float internal-time-units-per-second)))
               (dispatch-internal-seconds
                 (/ (- (getf pending :dispatch-return-tick)
                       (getf pending :dispatch-tick))
                    (float internal-time-units-per-second)))
               (receive-to-dispatch-seconds
                 (/ (- (getf pending :dispatch-tick)
                       (getf pending :received-tick))
                    (float internal-time-units-per-second)))
               (before-record-state
                 (m3-inner-selected-state before-record)))
          (with-open-file (stream (uiop:getenv "M3_INNER_DONE")
                                  :direction :output
                                  :if-exists :error)
            (format stream
                    "role=server~%spawned_by=attach~%lane=~A~%pid=~D~%protocol_path=decoded_msg_key_to_same_connection_frame_send~%msg_key_type=~D~%payload_is_single_n=1~%view_repolist=1~%modal_nil=1~%dispatch_seen=1~%dispatch_returned=1~%same_connection=1~%frame_send_completed=1~%frame_snapshot_changed=1~%selection_changed=1~%selected_tree_row_visible=1~%ghq_root_present=~D~%ghq_root_is_directory=~D~%ghq_root_entry_count=~D~%tree_entry_count_before=~D~%tree_entry_count_after=~D~%visible_tree_entry_count_before=~D~%visible_tree_entry_count_after=~D~%visible_selectable_row_count_before=~D~%visible_selectable_row_count_after=~D~%selected_row_ordinal_before=~D~%selected_row_ordinal_after=~D~%selected_kind_before=~A~%selected_kind_after=~A~%received_universal_time=~D~%dispatch_universal_time=~D~%dispatch_return_universal_time=~D~%frame_sent_universal_time=~D~%receive_to_send_sbcl_internal_real_time_elapsed_seconds=~,6F~%dispatch_to_send_sbcl_internal_real_time_elapsed_seconds=~,6F~%receive_to_dispatch_sbcl_internal_real_time_elapsed_seconds=~,6F~%dispatch_internal_sbcl_internal_real_time_elapsed_seconds=~,6F~%"
                    (uiop:getenv "M3_INNER_LANE")
                    (sb-posix:getpid)
                    nerimux::+msg-key+
                    (if (getf root :present-p) 1 0)
                    (if (getf root :directory-p) 1 0)
                    (getf root :entry-count)
                    (getf before-record-state :tree-entry-count)
                    (getf record :tree-entry-count)
                    (getf before-record-state :visible-tree-entry-count)
                    (getf record :visible-tree-entry-count)
                    (getf before-record-state :visible-selectable-row-count)
                    (getf record :visible-selectable-row-count)
                    (getf before-record-state :selected-visible-ordinal)
                    (getf record :selected-visible-ordinal)
                    (m3-inner-kind-name (getf before-record-state :selected-kind))
                    (m3-inner-kind-name (getf record :selected-kind))
                    (getf pending :received-wall)
                    (getf pending :dispatch-wall)
                    (getf pending :dispatch-return-wall)
                    sent-wall receive-seconds dispatch-seconds
                    receive-to-dispatch-seconds dispatch-internal-seconds)
            (progn
              (format stream "selected_index_before=~D~%selected_index_after=~D~%selection_advanced_by_one=1~%next_row_identity_matches=1~%"
                      (getf before-record :selected-index)
                      (getf record :selected-index))
              (format stream "elapsed_clock=sbcl_internal_real_time~%")
              (format stream "source_sha=~A~%" (uiop:getenv "M1_SOURCE_SHA"))
              (finish-output stream)))
          (setf *m3-inner-pending* nil)
          t))))

  (defun m3-inner-send-client-frame (conn frame)
    (multiple-value-prog1
        (funcall *m3-inner-original-send* conn frame)
      (let* ((sent-tick (get-internal-real-time))
             (sent-wall (get-universal-time))
             (record (gethash conn *m3-inner-render-records*))
             (sent (nerimux::client-conn-sent-row-frame conn)))
        (when (and record sent (eq frame (first sent)))
          (setf (getf record :sent-p) t
                (getf record :sent-snapshot) (third sent)))
        (when (and *m3-inner-pending*
                   (eq conn (getf *m3-inner-pending* :conn))
                   (getf *m3-inner-pending* :dispatch-returned-p)
                   record
                   (eq frame (getf record :frame)))
          (m3-inner-finish conn frame record *m3-inner-pending*
                           sent-tick sent-wall)))))

  (let* ((role (uiop:getenv "M3_INNER_ROLE"))
         (command (uiop:getenv "M3_INNER_COMMAND"))
         (parent-command (uiop:getenv "M3_INNER_PARENT_COMMAND"))
         (session (uiop:getenv "M3_INNER_SESSION"))
         (lane (uiop:getenv "M3_INNER_LANE"))
         (launcher (uiop:getenv "M3_INNER_LAUNCHER")))
    (unless (and role command parent-command lane launcher)
      (error "M3 inner timer environment is incomplete"))
    (when (and (string= role "client") (string= command "attach"))
      (let ((symbol (find-symbol "%SERVER-RESPAWN-COMMAND" "NERIMUX")))
        (unless (and symbol (fboundp symbol))
          (error "M3 respawn hook is unavailable"))
        (setf (symbol-function symbol)
              (lambda (session-name)
                (values launcher (list "server" session-name))))))
    (setf sb-ext:*posix-argv*
          (cond
            ((string= role "server")
             (unless (and session (string= parent-command "attach"))
               (error "M3 server role was not spawned by attach"))
             (list "nerimux" "server" session))
            ((and (string= role "client") (string= command "kill"))
             (list "nerimux" "kill" "--force"))
            ((and (string= role "client") (string= command "attach"))
             (list "nerimux" "attach"))
            (t (error "M3 application role/command is unsupported"))))
    (when (string= role "server")
      (require :sb-posix)
      (let* ((root (m3-inner-directory-summary))
             (read-symbol (find-symbol "READ-FRAME" "NERIMUX/TRANSPORT"))
             (dispatch-symbol
               (find-symbol "%HANDLE-MULTI-CLIENT-MESSAGE" "NERIMUX"))
             (flat-symbol
               (find-symbol "WORKSPACE-FLAT-TREE-ENTRIES" "NERIMUX/RENDERER"))
             (render-symbol (find-symbol "%RENDER-CLIENT-FRAME" "NERIMUX"))
             (send-symbol (find-symbol "%SEND-CLIENT-FRAME" "NERIMUX")))
        (unless (and read-symbol (fboundp read-symbol)
                     dispatch-symbol (fboundp dispatch-symbol)
                     flat-symbol (fboundp flat-symbol)
                     render-symbol (fboundp render-symbol)
                     send-symbol (fboundp send-symbol))
          (error "M3 timing hooks are unavailable"))
        (setf *m3-inner-root-summary* root
              *m3-inner-original-read-frame* (symbol-function read-symbol)
              *m3-inner-original-dispatch* (symbol-function dispatch-symbol)
              *m3-inner-original-flat-entries* (symbol-function flat-symbol)
              *m3-inner-original-render* (symbol-function render-symbol)
              *m3-inner-original-send* (symbol-function send-symbol)
              (symbol-function read-symbol) #'m3-inner-read-frame
              (symbol-function dispatch-symbol)
              #'m3-inner-handle-client-message
              (symbol-function flat-symbol) #'m3-inner-flat-entries
              (symbol-function render-symbol) #'m3-inner-render-client-frame
              (symbol-function send-symbol) #'m3-inner-send-client-frame)
        (with-open-file (stream (uiop:getenv "M3_INNER_ARMED")
                                :direction :output
                                :if-exists :error)
          (format stream
                  "role=server~%spawned_by=attach~%lane=~A~%pid=~D~%protocol_path=read_frame_then_msg_key_dispatch_then_send_client_frame~%ghq_root_present=~D~%ghq_root_is_directory=~D~%ghq_root_entry_count=~D~%start_universal_time=~D~%"
                  lane (sb-posix:getpid)
                  (if (getf root :present-p) 1 0)
                  (if (getf root :directory-p) 1 0)
                  (getf root :entry-count)
                  (get-universal-time))
          (progn (format stream "source_sha=~A~%" (uiop:getenv "M1_SOURCE_SHA")) (finish-output stream)))))
    (funcall (symbol-function (find-symbol "MAIN" "NERIMUX")))))
