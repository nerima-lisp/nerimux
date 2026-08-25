(in-package #:nerimux)

(defun %client-single-byte (payload)
  (cond
    ((and (stringp payload) (= (length payload) 1))
     (char-code (char payload 0)))
    ((and (arrayp payload) (= (length payload) 1))
     (aref payload 0))))

(defun %client-byte-p (payload byte)
  (eql (%client-single-byte payload) byte))

(defun %client-key-p (payload character)
  (%client-byte-p payload (char-code character)))

(defun %client-payload-text (payload)
  (cond
    ((stringp payload) payload)
    ((vectorp payload)
     (handler-case
         (cl-codec-kit:octets-to-string payload :encoding :utf-8)
       (cl-codec-kit:decode-error () nil)))))

(defun %client-enter-input-mode (conn)
  (%transition-client-ui-mode conn :enter-input)
  (%mark-dirty)
  t)

(defun %client-enter-command-mode (conn &optional (initial-buffer ""))
  (setf (client-conn-command-return-view conn)
        (client-conn-view conn))
  (%transition-client-ui-mode conn :enter-command)
  (setf (client-conn-command-buffer conn)
        (if (stringp initial-buffer) initial-buffer ""))
  (%mark-dirty)
  t)

(defun %client-restore-command-view (conn)
  (let ((view (client-conn-command-return-view conn)))
    (when (member view '(:overview :detail) :test #'eq)
      (setf (client-conn-view conn) view))
    (setf (client-conn-command-return-view conn) nil)))

(defun %client-select-pane-direction (session conn direction)
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (window (and pane (nerimux/model:pane-window pane))))
    ;; R5.6: a zoomed window has no neighbours (pane-neighbor returns NIL by
    ;; design), so un-zoom before looking one up rather than reporting "no
    ;; pane <direction>" for a move that would otherwise have succeeded.
    (%workspace-prefix-unzoom window)
    (let ((neighbor (and window (pane-neighbor window pane direction))))
      (if neighbor
          (progn
            (%set-client-focus conn neighbor)
            (%mark-dirty)
            t)
          (progn
            (%client-notify conn (format nil "no pane ~A" direction))
            t)))))

(defun %client-start-worktree-create (conn)
  (if (%client-selected-repository conn)
      (%client-enter-command-mode conn "wt-create --branch ")
      (%client-notify conn "select a repository to create a worktree"))
  t)

(defun %client-start-worktree-delete (conn)
  (if (%client-operation-worktree conn)
      (%client-enter-command-mode conn "wt-delete --confirm")
      (%client-notify conn "select a worktree to delete"))
  t)

(defun %client-start-worktree-lock (conn)
  (if (%client-operation-worktree conn)
      (%client-enter-command-mode conn "wt-lock --confirm")
      (%client-notify conn "select a worktree to lock"))
  t)

(defun %client-start-worktree-unlock (conn)
  (if (%client-operation-worktree conn)
      (%client-enter-command-mode conn "wt-unlock --confirm")
      (%client-notify conn "select a worktree to unlock"))
  t)

(defun %focus-selected-client-worktree (session conn)
  "Enter on the selected tree row (R6.3).

   What Enter means depends on the level, and the two upper levels mean
   something the tree had no way to express before: organization and repository
   rows toggle open and closed, so a workspace of a thousand repositories opens
   showing organizations rather than everything at once. Enter on those used to
   start a worktree-create prompt — which made the create flow reachable but
   left expansion with no key at all."
  (let ((object (%client-tree-object conn)))
    (cond
      ((typep object 'nerimux/model:organization)
       (%toggle-workspace-node-expanded
        :organization (nerimux/model:organization-id object))
       (%mark-dirty)
       t)
      ((typep object 'nerimux/model:repository)
       (%toggle-workspace-node-expanded
        :repository (nerimux/model:repository-id object))
       (%mark-dirty)
       t)
      ((typep object 'nerimux/model:pane)
       (%set-client-focus conn object)
       (%set-client-view conn :detail)
       (%mark-dirty)
       t)
      ((typep object 'nerimux/model:window)
       (let ((pane (nerimux/model:window-active-pane object)))
         (when pane
           (%set-client-focus conn pane)
           (%set-client-view conn :detail)))
       (%mark-dirty)
       t)
      (t
       (unless (client-conn-selected-worktree conn)
         (%select-client-tree-worktree conn nil))
       (let* ((worktree (client-conn-selected-worktree conn))
              ;; The pane last focused in this worktree, so Enter returns to
              ;; where the user was rather than to whichever pane happens to be
              ;; first (R6.3).
              (pane (or (%worktree-remembered-pane worktree)
                        (%client-worktree-pane session worktree))))
         (cond
           ((and pane (nerimux/model:pane-live-p pane))
            (%set-client-focus conn pane)
            (%remember-worktree-pane worktree pane)
            (%mark-dirty)
            t)
           (worktree
            (or (%open-client-worktree-pane session conn worktree) t))
           (t
            (%client-notify conn "no worktree selected")
            t)))))))

(defun %handle-client-normal-key-payload (session conn payload)
  (let ((view (client-conn-view conn)))
    (cond
      ((%client-key-p payload #\k)
       (case view
         (:overview (%select-client-tree-relative conn -1) t)
         (:detail (%client-select-pane-direction session conn :up))
         (otherwise nil)))
      ((%client-key-p payload #\j)
       (case view
         (:overview (%select-client-tree-relative conn 1) t)
         (:detail (%client-select-pane-direction session conn :down))
         (otherwise nil)))
      ((%client-key-p payload #\l)
       (if (eq view :detail)
           (%client-select-pane-direction session conn :right)
           nil))
      ((%client-key-p payload #\h)
       (if (eq view :detail)
           (%client-select-pane-direction session conn :left)
           nil))
      ((or (%client-byte-p payload 13) (%client-byte-p payload 10))
       (cond
         ((eq view :overview)
          (%focus-selected-client-worktree session conn))
         (t t)))
      ((and (eq view :overview) (%client-key-p payload #\n))
       (%client-start-worktree-create conn))
      ((and (eq view :overview) (%client-key-p payload #\X))
       (%client-start-worktree-delete conn))
      ((and (eq view :overview) (%client-key-p payload #\L))
       (%client-start-worktree-lock conn))
      ((and (eq view :overview) (%client-key-p payload #\U))
       (%client-start-worktree-unlock conn))
      ((%client-key-p payload #\d)
       (%set-client-view conn :detail)
       t)
      ((%client-key-p payload #\o)
       (%set-client-view conn :overview)
       t)
      ((%client-key-p payload #\r)
       (%client-refresh-workspace conn)
       t)
      ((%client-key-p payload #\i)
       (%client-enter-input-mode conn))
      ((%client-key-p payload #\c)
       (%client-enter-copy-mode session conn)
       t)
      ((%client-key-p payload #\:)
       (%client-enter-command-mode conn))
      (t nil))))

(defun %handle-client-input-key-payload (session conn payload)
  "Every byte, ESC included, is forwarded to the focused pane: :input mode has
   no keyboard exit of its own (that returns with the C-q prefix, R4.4)."
  (let ((pane (or (client-conn-stdin-target conn)
                  (%resolve-client-focus-pane session nil conn))))
    (cond
      ((null pane)
       (%client-notify conn "no focused pane"))
      ((pane-live-p pane)
       (handler-case
           (nerimux/pty:pty-write (pane-fd pane) payload)
         (error (condition)
           (%client-notify
            conn
            (format nil "input failed: ~A" condition)))))
      ((pane-screen pane)
       (pane-feed pane payload))
      (t
       (%client-notify conn "focused pane is unavailable")))
    (%mark-dirty)
    t))

(defun %handle-client-copy-key-payload (session conn payload)
  "Copy-mode exit is bound to q only; ESC is a plain, unbound byte here (it no
   longer doubles as an exit key -- see R4.2)."
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (screen (and pane (pane-screen pane))))
    (cond
      ((null screen)
       (%client-notify conn "no focused pane")
       (%transition-client-ui-mode conn :enter-normal))
      ((%client-key-p payload #\k)
       (copy-mode-move-cursor screen :up))
      ((%client-key-p payload #\j)
       (copy-mode-move-cursor screen :down))
      ((%client-key-p payload #\h)
       (copy-mode-move-cursor screen :left))
      ((%client-key-p payload #\l)
       (copy-mode-move-cursor screen :right))
      ((%client-key-p payload #\g)
       (copy-mode-scroll screen most-positive-fixnum))
      ((%client-key-p payload #\G)
       (copy-mode-scroll screen (- most-positive-fixnum)))
      ((%client-key-p payload #\Space)
       (copy-mode-begin-selection screen))
      ((%client-key-p payload #\y)
       (copy-mode-yank screen))
      ((%client-key-p payload #\n)
       (copy-mode-search-next screen))
      ((%client-key-p payload #\N)
       (copy-mode-search-prev screen))
      ((%client-key-p payload #\/)
       (%client-enter-command-mode conn "search-forward "))
      ((%client-key-p payload #\?)
       (%client-enter-command-mode conn "search-backward "))
      ((%client-key-p payload #\q)
       (%client-exit-copy-mode session conn)))
    (%mark-dirty)
    t))

(defun %client-command-buffer-delete-character (conn)
  (let ((buffer (client-conn-command-buffer conn)))
    (when (plusp (length buffer))
      (setf (client-conn-command-buffer conn)
            (subseq buffer 0 (1- (length buffer))))
      (%mark-dirty)
      t)))

(defun %client-command-buffer-append (conn payload)
  (let ((text (%client-payload-text payload)))
    (when (and text
               (every (lambda (character)
                        (>= (char-code character) 32))
                      text))
      (setf (client-conn-command-buffer conn)
            (concatenate 'string (client-conn-command-buffer conn) text))
      (%mark-dirty)
      t)))

(defun %client-command-target-and-args (args)
  (if (and (stringp (first args))
           (member (first args) '("-t" "--target") :test #'string=))
      (values (second args) (cddr args))
      (values nil args)))

(defun %client-search-direction (name)
  (cond
    ((member name '("search-forward" "/") :test #'string-equal) :forward)
    ((member name '("search-backward" "?") :test #'string-equal) :backward)))

(defun %client-search-term (args)
  (string-trim '(#\Space #\Tab)
               (format nil "~{~A~^ ~}" args)))

(defun %submit-client-search (session conn direction args)
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (screen (and pane (pane-screen pane)))
         (term (%client-search-term args)))
    (cond
      ((null screen)
       (%client-notify conn "no focused pane"))
      ((zerop (length term))
       (%client-notify conn "search term is empty"))
      ((eq direction :forward)
       (copy-mode-search-forward screen term))
      ((eq direction :backward)
       (copy-mode-search-backward screen term)))
    (%client-restore-command-view conn)
    (%transition-client-ui-mode
     conn
     (if (and screen (screen-copy-mode-p screen))
         :enter-copy
         :enter-normal))
    (%mark-dirty)))

(defun %submit-client-command (session conn)
  (let ((input (string-trim '(#\Space #\Tab)
                            (client-conn-command-buffer conn))))
    (setf (client-conn-command-buffer conn) "")
    (if (zerop (length input))
        (progn
          (%client-restore-command-view conn)
          (%transition-client-ui-mode conn :enter-normal)
          (%mark-dirty))
        (handler-case
            (let* ((tokens (tokenize-command-string input))
                   (name (first tokens))
                   (cmd (and name (intern (string-upcase name) :keyword)))
                   (search-direction (%client-search-direction name)))
              (if search-direction
                  (multiple-value-bind (target args)
                      (%client-command-target-and-args (rest tokens))
                    (declare (ignore target))
                    (%submit-client-search session conn search-direction args))
                  (progn
                    (let ((handled-p nil))
                      (if cmd
                          (multiple-value-bind (target args)
                              (%client-command-target-and-args (rest tokens))
                            (setf handled-p
                                  (%handle-client-ui-command
                                   session conn cmd target args))
                            (unless handled-p
                              (%client-notify
                               conn
                               (format nil "unknown command: ~(~A~)" cmd))))
                          (%client-notify conn "empty command"))
                      (unless handled-p
                        (%client-restore-command-view conn)))
                    (%transition-client-ui-mode conn :enter-normal)
                    (%mark-dirty))))
          (error (condition)
            (%client-notify
             conn
             (format nil "command failed: ~A" condition))
            (%client-restore-command-view conn)
            (%transition-client-ui-mode conn :enter-normal)
            (%mark-dirty)))))
  t)

(defun %handle-client-command-key-payload (session conn payload)
  (cond
    ((%client-byte-p payload 27)
     ;; R4.3: see the matching comment in %handle-client-picker-key-payload.
     (%client-esc-swallow-start conn)
     (setf (client-conn-command-buffer conn) "")
     (%client-restore-command-view conn)
     (%transition-client-ui-mode conn :enter-normal)
     (%mark-dirty)
     t)
    ((or (%client-byte-p payload 13) (%client-byte-p payload 10))
     (%submit-client-command session conn))
    ((or (%client-byte-p payload 8) (%client-byte-p payload 127))
     (%client-command-buffer-delete-character conn)
     t)
    (t
     (%client-command-buffer-append conn payload)
     t)))
