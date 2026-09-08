(in-package #:nerimux)

(defun %copy-mode-half-page-delta (pane)
  "Rows for C-u/C-d (contract SS2): half PANE's screen height, at least one
   line so a one-row pane still moves. copy-mode-scroll's sign convention
   (positive = older/up) makes C-u this value and C-d its negation."
  (let ((screen (and pane (pane-screen pane))))
    (max 1
         (floor
          (if screen
              (screen-height screen)
              24)
          2))))

(define-key-rules %copy-key-dispatch (session conn payload)
  (:let ((pane (%resolve-client-focus-pane session nil conn))
         (screen (and pane (pane-screen pane)))))
  ((null screen)
   (%client-notify conn "no focused pane")
   (%set-client-modal conn nil))
  (#\k (copy-mode-move-cursor screen :up))
  (#\j (copy-mode-move-cursor screen :down))
  (21 (copy-mode-scroll screen (%copy-mode-half-page-delta pane)))
  (4 (copy-mode-scroll screen (- (%copy-mode-half-page-delta pane))))
  (#\g (copy-mode-scroll screen most-positive-fixnum))
  (#\G (copy-mode-scroll screen (- most-positive-fixnum)))
  (#\Space (copy-mode-begin-selection screen))
  (#\y (copy-mode-yank screen) (%set-client-modal conn nil))
  (#\n (copy-mode-search-next screen))
  (#\N (copy-mode-search-prev screen))
  (#\/ (%client-enter-command-mode conn "search-forward "))
  (#\? (%client-enter-command-mode conn "search-backward "))
  (#\q
   (when (screen-copy-mode-p screen) (copy-mode-exit screen))
   (%set-client-modal conn nil)))

(defun %handle-client-copy-key-payload (session conn payload)
  "Scrollback (contract SS2/FR-008) exit is bound to q, which clears MODAL
   directly -- there is no %client-exit-copy-mode transition to call anymore,
   just a modal to drop, so a caller cannot land back in an unreachable
   (view, modal) pair. ESC is a plain, unbound byte here (it never doubled as
   an exit key -- see R4.2), and h/l horizontal cursor movement is dropped:
   SS2's scrollback table has no horizontal keys, and grep across src/ for
   COPY-MODE-MOVE-CURSOR turns up only the :up/:down call sites left above --
   no :left/:right caller survives removing these two clauses."
  (%copy-key-dispatch session conn payload)
  (%mark-dirty)
  t)

(defun %client-command-buffer-delete-character (conn)
  (let ((buffer (client-conn-command-buffer conn)))
    (when (plusp (length buffer))
      (setf (client-conn-command-buffer conn) (subseq buffer
                                                      0
                                                      (1- (length buffer))))
      (%mark-dirty)
      t)))

(defun %client-command-buffer-append (conn payload)
  (let ((text (%client-payload-text payload)))
    (when 
        (and text
             (every
              (lambda (character)
                (>= (char-code character) 32))
              text))
      (setf (client-conn-command-buffer conn) (concatenate 'string
                                                           (client-conn-command-buffer
                                                            conn)
                                                           text))
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
  (string-trim '(#\Space #\Tab) (format nil "~{~A~^ ~}" args)))

(defun %submit-client-search (session conn direction args)
  (let* ((pane (%resolve-client-focus-pane session nil conn))
         (screen (and pane (pane-screen pane)))
         (term (%client-search-term args)))
    (cond
      ((null screen) (%client-notify conn "no focused pane"))
      ((zerop (length term)) (%client-notify conn "search term is empty"))
      ((eq direction :forward) (copy-mode-search-forward screen term))
      ((eq direction :backward) (copy-mode-search-backward screen term)))
    (%client-restore-command-view conn)
    (%set-client-modal conn
                       (if (and screen (screen-copy-mode-p screen))
                           :scrollback
                           nil))
    (%mark-dirty)))

(defun %submit-client-command (session conn)
  (let ((input (string-trim '(#\Space #\Tab)
                            (client-conn-command-buffer conn))))
    (setf (client-conn-command-buffer conn) "")
    (if (zerop (length input))
        (progn
          (%client-restore-command-view conn)
          (%set-client-modal conn nil)
          (%mark-dirty))
        (handler-case
            (let* ((tokens (tokenize-command-string input))
                   (name (first tokens))
                   (cmd (and name
                             (or (find-symbol (string-upcase name) :keyword)
                                 name)))
                   (search-direction (%client-search-direction name)))
              (progn
                (if search-direction
                    (multiple-value-bind (target args)
                        (%client-command-target-and-args (rest tokens))
                      (declare (ignore target))
                      (%submit-client-search session conn search-direction args))
                    (if (and (keywordp cmd)
                             (not (member cmd +client-command-allow-list+
                                          :test #'eq)))
                        (progn
                          (%client-notify
                           conn
                           (format nil
                                   "command is not available from the : prompt: ~A"
                                   name))
                          (%client-restore-command-view conn)
                          (%set-client-modal conn nil))
                        (let ((handled-p nil))
                          (if cmd
                              (multiple-value-bind (target args)
                                  (if (member cmd
                                              '(:workspace-complete :wt-complete))
                                      (values nil (rest tokens))
                                      (%client-command-target-and-args (rest tokens)))
                                (setf handled-p
                                      (%handle-client-ui-command
                                       session conn cmd target args))
                                (unless handled-p
                                  (%client-notify
                                   conn
                                   (format nil "unknown command: ~(~A~)" cmd)))))
                          (unless handled-p
                            (%client-restore-command-view conn))
                          (when (eq (client-conn-modal conn) :command)
                            (%set-client-modal conn nil)))))
                (%mark-dirty)))
          (error (condition)
            (%client-notify
             conn
             (format nil "command failed: ~A" condition))
            (%client-restore-command-view conn)
            (%set-client-modal conn nil)
            (%mark-dirty)))))
  t)

(define-key-rules %handle-client-command-key-payload (session conn payload)
  (27
   (%client-esc-swallow-start conn)
   (setf (client-conn-command-buffer conn) "")
   (%client-restore-command-view conn)
   (%set-client-modal conn nil)
   (%mark-dirty)
   t)
  ((or (%client-byte-p payload 13) (%client-byte-p payload 10))
   (%submit-client-command session conn))
  ((or (%client-byte-p payload 8) (%client-byte-p payload 127))
   (%client-command-buffer-delete-character conn)
   t)
  (t
   (%client-command-buffer-append conn payload)
   t))

(defun %client-write-pane-payload (conn pane payload)
  (cond
    ((null pane) nil)
    ((pane-live-p pane)
     (handler-case (nerimux/pty:pty-write (pane-fd pane) payload)
       (peer-io-failure (condition)
         (%client-notify conn (format nil "input failed: ~A" condition))))
     t)
    ((pane-screen pane)
     (pane-feed pane payload)
     t)
    (t nil)))

(defun %client-paste-modal-p (modal)
  (member modal '(:command :filter :picker :text-prompt) :test #'eq))

(defun %client-paste-candidate-reset (conn)
  (setf (client-conn-paste-candidate-modal conn) nil
        (client-conn-paste-candidate-view conn) nil
        (client-conn-paste-candidate-command-return-view conn) nil
        (client-conn-paste-candidate-text conn) nil
        (client-conn-paste-candidate-text-prompt-kind conn) nil
        (client-conn-paste-candidate-text-prompt-title conn) nil
        (client-conn-paste-candidate-text-prompt-widget conn) nil
        (client-conn-paste-candidate-text-prompt-repository conn) nil
        (client-conn-paste-candidate-text-prompt-operation conn) nil
        (client-conn-paste-candidate-text-prompt-static-args conn) nil))

(defun %client-paste-candidate-restore (conn)
  (let ((modal (client-conn-paste-candidate-modal conn)))
    (when modal
      (setf (client-conn-modal conn) modal
            (client-conn-view conn) (client-conn-paste-candidate-view conn)
            (client-conn-command-return-view conn)
            (client-conn-paste-candidate-command-return-view conn))
      (case modal
        (:command
         (setf (client-conn-command-buffer conn)
               (client-conn-paste-candidate-text conn)))
        (:filter
         (setf (client-conn-tree-filter conn)
               (client-conn-paste-candidate-text conn)))
        (:picker
         (setf (client-conn-picker-query conn)
               (client-conn-paste-candidate-text conn)))
        (:text-prompt
         (setf (client-conn-text-prompt-kind conn)
               (client-conn-paste-candidate-text-prompt-kind conn)
               (client-conn-text-prompt-title conn)
               (client-conn-paste-candidate-text-prompt-title conn)
               (client-conn-text-prompt-widget conn)
               (client-conn-paste-candidate-text-prompt-widget conn)
               (client-conn-text-prompt-repository conn)
               (client-conn-paste-candidate-text-prompt-repository conn)
               (client-conn-text-prompt-operation conn)
               (client-conn-paste-candidate-text-prompt-operation conn)
               (client-conn-text-prompt-static-args conn)
               (client-conn-paste-candidate-text-prompt-static-args conn))))
      (%client-paste-candidate-reset conn)
      modal)))

(defun %client-paste-candidate-abort (session conn payload)
  (remhash conn *client-esc-swallow-counts*)
  (%client-paste-candidate-reset conn)
  (when session
    (let ((*client-meta-replaying* t))
      (%handle-multi-key-message session conn payload))))

(defun %client-paste-reset (conn)
  (setf (client-conn-paste-active-p conn) nil
        (client-conn-paste-pane conn) nil
        (client-conn-paste-modal conn) nil
        (client-conn-paste-wrapped-p conn) nil
        (client-conn-paste-bytes conn) nil)
  (%client-paste-candidate-reset conn))

(defun %client-paste-begin (session conn)
  (let* ((candidate-modal (client-conn-paste-candidate-modal conn))
         (modal (or candidate-modal
                    (client-conn-modal conn)))
         (pane (and (not (%client-paste-modal-p modal))
                    (%resolve-client-focus-pane session nil conn))))
    (when candidate-modal
      (%client-paste-candidate-restore conn)
      (remhash conn *client-esc-swallow-counts*))
    (setf (client-conn-paste-active-p conn) t
          (client-conn-paste-pane conn) pane
          (client-conn-paste-modal conn)
          (and (%client-paste-modal-p modal) modal)
          (client-conn-paste-wrapped-p conn)
          (and pane
               (pane-screen pane)
               (screen-bracketed-paste (pane-screen pane)))
          (client-conn-paste-bytes conn) nil)
    (when (client-conn-paste-wrapped-p conn)
      (%client-write-pane-payload conn pane (format nil "~C[200~~" #\Escape)))
    t))

(defun %client-paste-modal-text (conn)
  (let ((bytes (coerce (nreverse (client-conn-paste-bytes conn))
                       '(simple-array (unsigned-byte 8) (*)))))
    (let ((text (%client-payload-text bytes)))
      (and text
           (if (eq (client-conn-paste-modal conn) :text-prompt)
               text
               (coerce (remove-if (lambda (character)
                                    (member character '(#\Newline #\Return)))
                                  text)
                       'string))))))

(defun %client-paste-insert-modal (conn)
  (let ((text (%client-paste-modal-text conn)))
    (when text
      (case (client-conn-paste-modal conn)
        (:command (%client-command-buffer-append conn text))
        (:filter
         (map nil (lambda (character)
                    (%client-tree-filter-buffer-append conn (string character)))
              text))
        (:picker (%append-client-picker-query-octets conn text))
        (:text-prompt (%client-text-prompt-handle-text conn text))))))

(defun %client-paste-end (conn)
  (if (client-conn-paste-modal conn)
      (%client-paste-insert-modal conn)
      (when (client-conn-paste-wrapped-p conn)
        (%client-write-pane-payload
         conn
         (client-conn-paste-pane conn)
         (format nil "~C[201~~" #\Escape))))
  (%client-paste-reset conn)
  t)

(defun %client-paste-consume-byte (conn payload)
  (let ((byte (%client-single-byte payload)))
    (when (integerp byte)
      (if (client-conn-paste-modal conn)
          (push byte (client-conn-paste-bytes conn))
          (%client-write-pane-payload
           conn
           (client-conn-paste-pane conn)
           (make-array 1
                       :element-type '(unsigned-byte 8)
                       :initial-element byte)))))
  t)

(defun %client-paste-consume-span (conn payload start end)
  (when (< start end)
    (if (client-conn-paste-modal conn)
        (loop for index from start below end
              for value = (aref payload index)
              do (push (if (characterp value) (char-code value) value)
                       (client-conn-paste-bytes conn)))
        (%client-write-pane-payload
         conn
         (client-conn-paste-pane conn)
         (subseq payload start end))))
  t)

(defun %client-paste-span-ready-p (conn)
  (and (client-conn-paste-active-p conn)
       (null (gethash conn *client-meta-pending*))))

(defun %client-paste-end-candidate-replay (conn prefix payload)
  (dolist (byte prefix)
    (%client-paste-consume-byte conn (vector byte)))
  (if (%client-byte-p payload 27)
      (setf (gethash conn *client-meta-pending*) :paste-second)
      (%client-paste-consume-byte conn payload)))

(defun %client-paste-end-candidate-consume (conn payload)
  (let ((state (gethash conn *client-meta-pending*)))
    (remhash conn *client-meta-pending*)
    (case state
      (:paste-second
       (if (%client-byte-p payload 91)
           (setf (gethash conn *client-meta-pending*) :paste-csi-third)
           (%client-paste-end-candidate-replay conn '(27) payload)))
      (:paste-csi-third
       (if (%client-byte-p payload 50)
           (setf (gethash conn *client-meta-pending*) :paste-csi-2)
           (%client-paste-end-candidate-replay conn '(27 91) payload)))
      (:paste-csi-2
       (if (%client-byte-p payload 48)
           (setf (gethash conn *client-meta-pending*) :paste-csi-20)
           (%client-paste-end-candidate-replay conn '(27 91 50) payload)))
      (:paste-csi-20
       (if (%client-byte-p payload 49)
           (setf (gethash conn *client-meta-pending*) :paste-csi-201)
           (%client-paste-end-candidate-replay conn '(27 91 50 48) payload)))
      (:paste-csi-201
       (if (= (%client-single-byte payload) 126)
           (%client-paste-end conn)
           (%client-paste-end-candidate-replay conn '(27 91 50 48 49) payload)))))
  t)

(defun %client-meta-replay-bytes (session conn bytes)
  (let ((*client-meta-replaying* t))
    (dolist (byte bytes)
      (%handle-multi-key-message
       session
       conn
       (make-array 1
                   :element-type '(unsigned-byte 8)
                   :initial-element byte)))))

(defun %client-meta-replay-with-current (session conn prefix payload)
  (%client-meta-replay-bytes
   session
   conn
   (append prefix (list (%client-single-byte payload)))))

(defun %client-focus-event-report (conn pane focused-p)
  (let* ((screen (and pane (pane-screen pane)))
         (report (and screen
                      (nerimux/terminal/actions:focus-event-report
                       screen
                       focused-p))))
    (when report
      (%client-write-pane-payload conn pane report))))

(defun %client-host-focus-event (session conn focused-p)
  (setf (client-conn-host-focused-p conn) focused-p)
  (when session
    (%client-focus-event-report
     conn
     (%resolve-client-focus-pane session nil conn)
     focused-p))
  t)

(defun %client-meta-pending-consume (conn payload &optional session)
  "Resolve UI escape sequences without replaying their tails as ordinary keys."
  (let ((state (gethash conn *client-meta-pending*)))
    (remhash conn *client-meta-pending*)
    (case state
      (:second
       (cond
         ((%client-byte-p payload 91)
          (setf (gethash conn *client-meta-pending*) :csi-third))
         ((and (client-conn-paste-candidate-modal conn)
               (%client-esc-swallow-consume conn))
          (%client-paste-candidate-reset conn))
         ((and (%client-ui-keys-p conn) (%client-key-p payload #\n))
          (%select-client-tree-section-relative conn 1))
         ((and (%client-ui-keys-p conn) (%client-key-p payload #\p))
          (%select-client-tree-section-relative conn -1))
         ((and session (not (%client-ui-keys-p conn)))
          (%client-meta-replay-with-current session conn '(27) payload))))
     (:csi-third
      (let ((byte (%client-single-byte payload)))
        (cond
          ((= byte 73)
           (%client-paste-candidate-restore conn)
           (%client-host-focus-event session conn t)
           (remhash conn *client-esc-swallow-counts*))
          ((= byte 79)
           (%client-paste-candidate-restore conn)
           (%client-host-focus-event session conn nil)
           (remhash conn *client-esc-swallow-counts*))
          ((= byte 50)
           (setf (gethash conn *client-meta-pending*) :csi-2))
          ((client-conn-paste-candidate-modal conn)
           (%client-esc-swallow-consume conn)
           (%client-esc-swallow-consume conn)
           (%client-paste-candidate-reset conn))
          ((and session
                (null (client-conn-modal conn))
                (eq (client-conn-view conn) :pane)
                (member byte '(65 66 67 68))
                (let* ((pane (or (client-conn-stdin-target conn)
                                 (%resolve-client-focus-pane session nil conn)))
                       (screen (and pane (pane-screen pane))))
                  (and screen (screen-app-cursor-keys screen))))
           (%handle-client-input-key-payload
            session
            conn
            (format nil "~CO~C" #\Escape (code-char byte))))
          ((and (%client-ui-keys-p conn) (= byte 65))
           (%select-client-tree-relative conn -1))
          ((and (%client-ui-keys-p conn) (= byte 66))
           (%select-client-tree-relative conn 1))
          ((and (%client-ui-keys-p conn) (= byte 90))
           (%client-cycle-visibility conn))
          ((and session (not (%client-ui-keys-p conn)))
           (%client-meta-replay-with-current session conn '(27 91) payload)))))
     (:csi-2
      (if (= (%client-single-byte payload) 48)
          (setf (gethash conn *client-meta-pending*) :csi-20)
          (if (client-conn-paste-candidate-modal conn)
              (%client-paste-candidate-abort session conn payload)
              (when (and session (not (%client-ui-keys-p conn)))
                (%client-meta-replay-with-current session conn '(27 91 50) payload)))))
     (:csi-20
      (cond
        ((= (%client-single-byte payload) 48)
         (setf (gethash conn *client-meta-pending*) :csi-200))
        ((= (%client-single-byte payload) 49)
         (setf (gethash conn *client-meta-pending*) :csi-201))
        ((client-conn-paste-candidate-modal conn)
         (%client-paste-candidate-abort session conn payload))
        ((and session (not (%client-ui-keys-p conn)))
         (%client-meta-replay-with-current session conn '(27 91 50 48) payload))))
     (:csi-200
      (if (= (%client-single-byte payload) 126)
          (%client-paste-begin session conn)
          (if (client-conn-paste-candidate-modal conn)
              (%client-paste-candidate-abort session conn payload)
              (when (and session (not (%client-ui-keys-p conn)))
                (%client-meta-replay-with-current session conn '(27 91 50 48 48) payload)))))
     (:csi-201
      (if (= (%client-single-byte payload) 126)
          (%client-paste-end conn)
          (if (client-conn-paste-candidate-modal conn)
              (%client-paste-candidate-abort session conn payload)
              (when (and session (not (%client-ui-keys-p conn)))
                (%client-meta-replay-with-current session conn '(27 91 50 48 49) payload))))))
   t))

(defun %client-meta-handle-byte (session conn payload)
  (cond
    ((and (client-conn-paste-active-p conn)
          (gethash conn *client-meta-pending*))
     (%client-paste-end-candidate-consume conn payload)
     t)
    ((client-conn-paste-active-p conn)
     (if (%client-byte-p payload 27)
         (setf (gethash conn *client-meta-pending*) :paste-second)
         (%client-paste-consume-byte conn payload))
     t)
    ((gethash conn *client-meta-pending*)
     (%client-meta-pending-consume conn payload session)
     t)
    ((%client-byte-p payload 27)
     (let ((modal (client-conn-modal conn)))
       (cond
         ((%client-paste-modal-p modal)
          (setf (client-conn-paste-candidate-modal conn) modal
                (client-conn-paste-candidate-view conn)
                (client-conn-view conn)
                (client-conn-paste-candidate-command-return-view conn)
                (client-conn-command-return-view conn)
                (client-conn-paste-candidate-text conn)
                (case modal
                  (:command (client-conn-command-buffer conn))
                  (:filter (client-conn-tree-filter conn))
                  (:picker (client-conn-picker-query conn))
                  (:text-prompt nil)))
          (when (eq modal :text-prompt)
            (setf (client-conn-paste-candidate-text-prompt-kind conn)
                  (client-conn-text-prompt-kind conn)
                  (client-conn-paste-candidate-text-prompt-title conn)
                  (client-conn-text-prompt-title conn)
                  (client-conn-paste-candidate-text-prompt-widget conn)
                  (client-conn-text-prompt-widget conn)
                  (client-conn-paste-candidate-text-prompt-repository conn)
                  (client-conn-text-prompt-repository conn)
                  (client-conn-paste-candidate-text-prompt-operation conn)
                  (client-conn-text-prompt-operation conn)
                  (client-conn-paste-candidate-text-prompt-static-args conn)
                  (client-conn-text-prompt-static-args conn)))
          (let ((*client-meta-replaying* t))
            (%handle-multi-key-message session conn payload))
          (setf (gethash conn *client-meta-pending*) :second))
         ((%client-ui-keys-p conn)
          (setf (gethash conn *client-meta-pending*) :second))
         ((member modal +keyboard-owning-modals+ :test #'eq)
          (let ((*client-meta-replaying* t))
            (%handle-multi-key-message session conn payload)))
         (t
          (setf (gethash conn *client-meta-pending*) :second))))
     t)
    (t nil)))

(defun %client-set-visibility-level (conn level)
  "`1`-`4` (contract SS2): set CONN's global section-visibility preset.
   Out-of-range LEVEL is a no-op rather than storing an unrenderable value --
   defensive only, since every caller here already passes a literal 1-4 or a
   value %CLIENT-CYCLE-VISIBILITY has already reduced into that range."
  (when (<= 1 level 4)
    (setf (client-conn-visibility-level conn) level)
    (%mark-dirty))
  t)

(defun %client-cycle-visibility (conn)
  "S-TAB: advance CONN's visibility level 1->2->3->4->1."
  (%client-set-visibility-level conn
                                (1+ (mod (client-conn-visibility-level conn) 4))))

(defun %client-focused-live-pane (session conn)
  "CONN's own remembered focus, still live in SESSION -- deliberately NOT
   %RESOLVE-CLIENT-FOCUS-PANE's window-active-pane fallback, which always
   finds SOME pane once a window exists and would make %CLIENT-STEP-BACK's
   'if there is one' vacuously true, sending `q` into a pane the user never
   actually left."
  (and (client-conn-focus conn)
       (find (client-conn-focus conn) (all-panes session) :test #'eq)))

(defun %client-step-back (session conn)
  "FR-006: `q` retreats exactly one level, first match wins, so a transient
   sitting over a filtered status view backs out only the transient -- the
   filter and the pane behind it are left exactly where the user put them.
   The transient rung only fires when something else on this connection
   calls this directly with MODAL already :TRANSIENT (contract SS3's
   %HANDLE-CLIENT-TRANSIENT-KEY-PAYLOAD may delegate its own `q` here for
   this reason): %HANDLE-MULTI-KEY-MESSAGE routes a :TRANSIENT modal to that
   handler before this function is ever reached, so `q` on the UI keymap
   itself always has MODAL NIL by the time it gets here."
  (cond
    ((eq (client-conn-modal conn) :transient)
      (setf (client-conn-transient-view conn) nil)
      (%set-client-modal conn nil))
    ((client-conn-tree-filter conn)
      (setf (client-conn-tree-filter conn) nil)
      (%mark-dirty))
    ((eq (client-conn-view conn) :status)
     (if (%client-focused-live-pane session conn)
         (%set-client-view conn :pane)
         (%set-client-view conn :repolist)))
    ((eq (client-conn-view conn) :repolist)
     (when (%client-focused-live-pane session conn)
       (%set-client-view conn :pane))))
  t)

(defun %client-open-selected-worktree-command (session conn command &key agent-kind)
  "Open a new pane for the selected worktree running COMMAND.
   A NIL command deliberately starts the user's ordinary shell."
  (let ((worktree (client-conn-selected-worktree conn)))
    (unless worktree
      (%select-client-tree-worktree conn nil)
      (setf worktree (client-conn-selected-worktree conn)))
    (if worktree
        (%open-client-worktree-pane session conn worktree
                                    :default-command command
                                    :agent-kind agent-kind)
        (%client-notify conn "no worktree selected"))))
