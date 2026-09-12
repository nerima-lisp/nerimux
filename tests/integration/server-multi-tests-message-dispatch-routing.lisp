(in-package #:nerimux/test)

(describe "server-multi-suite"

  (it "multi-resize-updates-geometry-and-reapplies-smallest-size"
    (with-fake-session (s)
      (let* ((a (%make-test-conn :rows 24 :cols 80))
             (b (%make-test-conn :rows 30 :cols 100))
             (nerimux::*clients* (list a b))
             (payload (nerimux/protocol::u16-octets-pair 50 150)))
        (nerimux::%handle-multi-client-message nerimux::+msg-resize+ payload s b)
        (expect (= 50 (nerimux::client-conn-rows b)))
        (expect (= 150 (nerimux::client-conn-cols b)))
        (multiple-value-bind (rows cols) (nerimux::%effective-client-size)
          (check-table (list (list rows 24 "effective rows = smallest attached client (a), not the resized one")
                             (list cols 80 "effective cols = smallest attached client (a), not the resized one")))))))

  (it "multi-handle-key-detach-drops-client"
    (with-fake-session (s)
      (let* ((conn   (%make-test-conn))
             (prefix (make-array 1 :element-type '(unsigned-byte 8)
                                    :initial-contents
                                    (list (nerimux::client-conn-workspace-prefix-code conn))))
             (d-key  (make-array 1 :element-type '(unsigned-byte 8)
                                    :initial-contents (list (char-code #\d)))))
        (expect (null (nerimux::%handle-multi-client-message
                       nerimux::+msg-key+ prefix s conn)))
        (expect (nerimux::client-conn-ui-prefix-p conn))
        (expect (eq :drop (nerimux::%handle-multi-client-message
                           nerimux::+msg-key+ d-key s conn)))
        (expect nerimux::*running* :to-be-truthy))))

  (it "multi-handle-unbound-normal-key-is-noop"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (before-modal (nerimux::client-conn-modal conn))
             (before-view (nerimux::client-conn-view conn))
             (key (make-array 1 :element-type '(unsigned-byte 8)
                                 :initial-contents (list (char-code #\o))))
             (writes nil))
        (flet ((rec (fd bytes) (declare (ignore fd)) (push bytes writes)))
          (let ((orig (fdefinition 'nerimux::pty-write)))
            (unwind-protect
                 (progn
                   (setf (fdefinition 'nerimux::pty-write) #'rec)
                   (expect (null (nerimux::%handle-multi-client-message
                                  nerimux::+msg-key+ key s conn))))
              (setf (fdefinition 'nerimux::pty-write) orig))))
        (expect (null writes))
        (expect (eq before-modal (nerimux::client-conn-modal conn)))
        (expect (eq before-view (nerimux::client-conn-view conn)))
        (expect nerimux::*running* :to-be-truthy))))

  (it "multi-handle-detach-message-drops-client"
    (with-fake-session (s)
      (expect (eq :drop (nerimux::%handle-multi-client-message
                         nerimux::+msg-detach+ #() s (%make-test-conn))))))

  (it "multi-handle-nil-and-unknown-type-drop"
    (with-fake-session (s)
      (expect (eq :drop (nerimux::%handle-multi-client-message nil #() s (%make-test-conn))))
      (expect (eq :drop (nerimux::%handle-multi-client-message 99 #() s (%make-test-conn))))))

  (it "workspace-prefix-dispatch-has-total-input-contract"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-modal conn) :command)
        (expect (null (nerimux::%workspace-prefix-dispatch s conn :not-a-byte)))
        (expect (null (nerimux::%workspace-prefix-dispatch s conn 255)))
        (expect (eq :command (nerimux::client-conn-modal conn)))
        (expect (null
                 (nerimux::%workspace-prefix-dispatch
                  s conn (nerimux::client-conn-workspace-prefix-code conn))))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (eq :drop
                    (nerimux::%workspace-prefix-dispatch
                     s conn (char-code #\d)))))))

  (it "multi-client-ui-keymaps-drive-pane-scrollback-search-and-command"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux::window-active-pane
                    (nerimux::session-active-window s)))
             (screen (nerimux/pane:pane-screen pane))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-focus conn) pane)
        (nerimux/pane:pane-feed
         pane
         (cl-codec-kit:string-to-octets "needle" :encoding :utf-8))
        (nerimux::%set-client-view conn :pane)
        (nerimux::%handle-multi-key-message s conn #(105))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (nerimux::%handle-multi-key-message s conn #(27))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(91))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen))
        (nerimux::%handle-multi-key-message s conn #(47))
        (expect (eq :command (nerimux::client-conn-modal conn)))
        (expect (string= "search-forward "
                         (nerimux::client-conn-command-buffer conn)))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "needle" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (eq :scrollback (nerimux::client-conn-modal conn)))
        (nerimux::%handle-multi-key-message s conn #(113))
        (expect (null (nerimux::client-conn-modal conn)))
        (expect (nerimux/terminal:screen-copy-mode-p screen) :to-be-falsy)
        (nerimux::%handle-multi-key-message s conn #(17))
        (nerimux::%handle-multi-key-message s conn #(119))
        (expect (eq :repolist (nerimux::client-conn-view conn)))
        (nerimux::%handle-multi-key-message s conn #(58))
        (nerimux::%handle-multi-key-message
         s conn (cl-codec-kit:string-to-octets "detail" :encoding :utf-8))
        (nerimux::%handle-multi-key-message s conn #(13))
        (expect (eq :pane (nerimux::client-conn-view conn)))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "colon-command-line-allows-user-commands-and-rejects-internal-commands"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (flet ((submit (command)
                 (nerimux::%handle-multi-key-message s conn #(58))
                 (nerimux::%handle-multi-key-message
                  s conn
                  (cl-codec-kit:string-to-octets command :encoding :utf-8))
                 (nerimux::%handle-multi-key-message s conn #(13))))
          (submit "tree-up")
          (expect (search "not available from the : prompt: tree-up"
                          (first (nerimux::client-conn-message-log conn))))
          (expect (eq :repolist (nerimux::client-conn-view conn)))
          (setf (nerimux::client-conn-message-log conn) nil)
          (submit "overview")
          (expect (string= "view: overview"
                           (first (nerimux::client-conn-message-log conn))))
          (expect (eq :repolist (nerimux::client-conn-view conn)))))))

  (it "colon-help-opens-the-help-view-and-colon-q-steps-back"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (flet ((submit (command)
                 (nerimux::%handle-multi-key-message s conn #(58))
                 (nerimux::%handle-multi-key-message
                  s conn
                  (cl-codec-kit:string-to-octets command :encoding :utf-8))
                 (nerimux::%handle-multi-key-message s conn #(13))))
          (submit "help")
          (expect (eq :help (nerimux::client-conn-modal conn)))
          (expect (null (nerimux::client-conn-message-log conn)))
          (nerimux::%set-client-modal conn nil)
          (setf (nerimux::client-conn-tree-filter conn) "feat")
          (submit "q")
          (expect (null (nerimux::client-conn-tree-filter conn)))
          (expect (null (nerimux::client-conn-modal conn)))
          (expect (null (nerimux::client-conn-message-log conn)))
          (setf (nerimux::client-conn-tree-filter conn) "feat")
          (submit "quit")
          (expect (null (nerimux::client-conn-tree-filter conn)))
          (expect (null (nerimux::client-conn-message-log conn)))))))

  (it "tab-completes-the-command-name-and-cycles-on-repeat"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (nerimux::*clients* (list conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (flet ((tab ()
                 (nerimux::%handle-multi-key-message s conn #(9)))
               (type-text (text)
                 (nerimux::%handle-multi-key-message
                  s conn
                  (cl-codec-kit:string-to-octets text :encoding :utf-8))))
          (nerimux::%handle-multi-key-message s conn #(58))
          (type-text "wt-p")
          (tab)
          (expect (string= "wt-prune"
                           (nerimux::client-conn-command-buffer conn)))
          (tab)
          (expect (string= "wt-prune-confirm"
                           (nerimux::client-conn-command-buffer conn)))
          (tab)
          (expect (string= "wt-prune"
                           (nerimux::client-conn-command-buffer conn)))
          (setf (nerimux::client-conn-command-buffer conn) "")
          (type-text "ref")
          (tab)
          (expect (string= "refresh"
                           (nerimux::client-conn-command-buffer conn)))))))

  (it "workspace-command-completions-match-the-client-allow-list"
    (expect
     (equal
      (mapcar (lambda (command)
                (string-downcase (symbol-name command)))
              nerimux::+client-command-allow-list+)
      nerimux/renderer::+workspace-command-names+)))

  (it "command-submit-contract-covers-empty-unknown-and-failure"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (nerimux::*clients* nil)
            (original (fdefinition 'nerimux::%handle-client-ui-command)))
        (unwind-protect
             (progn
               (setf nerimux::*clients* (list conn))
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (nerimux::%client-ui-keys-p conn))
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn (cl-codec-kit:string-to-octets "not-a-command"
                                                       :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (string= "unknown command: not-a-command"
                                (first (nerimux::client-conn-message-log conn))))
               (setf (fdefinition 'nerimux::%handle-client-ui-command)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (error "expected command failure")))
               (nerimux::%handle-multi-key-message s conn #(58))
               (nerimux::%handle-multi-key-message
                s conn (cl-codec-kit:string-to-octets "overview" :encoding :utf-8))
               (nerimux::%handle-multi-key-message s conn #(13))
               (expect (search "command failed: expected command failure"
                               (first (nerimux::client-conn-message-log conn))))
               (expect (nerimux::%client-ui-keys-p conn)))
          (setf (fdefinition 'nerimux::%handle-client-ui-command) original)))))

  (it "fr-101-bracketed-paste-wraps-only-when-the-pane-requested-it"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s)))
             (screen (nerimux/pane:pane-screen pane))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 41
              (nerimux::client-conn-focus conn) pane
              (nerimux::client-conn-view conn) :pane
              (nerimux/terminal/types:screen-bracketed-paste screen) t)
        (labels ((send-text (text)
                   (dolist (byte (coerce (cl-codec-kit:string-to-octets
                                          text
                                          :encoding :utf-8)
                                         'list))
                     (nerimux::%handle-multi-client-message
                      nerimux::+msg-key+ (vector byte) s conn)))
                 (writes-text ()
                   (with-output-to-string (stream)
                     (dolist (call (nreverse writes))
                       (write-string
                        (if (stringp (second call))
                            (second call)
                            (cl-codec-kit:octets-to-string
                             (second call)
                             :encoding :utf-8))
                        stream)))))
          (with-stubbed-fdefinition
              ((nerimux/pty:pty-write
                (lambda (fd bytes) (push (list fd bytes) writes))))
            (send-text (concatenate 'string
                                    (string #\Escape)
                                    "[200~abc"
                                    (string #\Escape)
                                    "[201~"))
            (expect
             (string= (concatenate 'string
                                   (string #\Escape)
                                   "[200~abc"
                                   (string #\Escape)
                                   "[201~")
                      (writes-text)))
            (setf writes nil
                  (nerimux/terminal/types:screen-bracketed-paste screen) nil)
            (send-text (concatenate 'string
                                    (string #\Escape)
                                    "[200~abc"
                                    (string #\Escape)
                                    "[201~"))
            (expect (string= "abc" (writes-text))))))))

  (it "fr-101-paste-in-command-modal-is-inserted-as-one-edit"
    (with-fake-session (s)
      (let ((conn (%make-test-conn))
            (writes nil)
            (dispatches 0)
            (original (fdefinition 'nerimux::%handle-client-command-key-payload)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%client-enter-command-mode conn)
        (setf (nerimux::client-conn-command-buffer conn) "before")
        (labels ((send-text (text)
                   (dolist (byte (coerce (cl-codec-kit:string-to-octets
                                          text
                                          :encoding :utf-8)
                                         'list))
                     (nerimux::%handle-multi-client-message
                      nerimux::+msg-key+ (vector byte) s conn))))
          (with-stubbed-fdefinition
              ((nerimux/pty:pty-write
                (lambda (fd bytes) (push (list fd bytes) writes)))
               (nerimux::%handle-client-command-key-payload
                (lambda (session conn payload)
                  (unless (eql (nerimux::%client-single-byte payload) 27)
                    (incf dispatches))
                  (funcall original session conn payload))))
            (send-text (concatenate 'string
                                    (string #\Escape)
                                    "[200~one"
                                    (string #\Newline)
                                    "two"
                                    (string #\Escape)
                                    "[201~"))
            (expect (string= "beforeonetwo"
                             (nerimux::client-conn-command-buffer conn)))
            (expect (eq :command (nerimux::client-conn-modal conn)))
            (expect (= 0 dispatches))
            (expect (null writes)))))))

  (it "fr-101-paste-in-filter-and-picker-appends-without-newlines"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (labels ((send-text (text)
                   (dolist (byte (coerce (cl-codec-kit:string-to-octets
                                          text
                                          :encoding :utf-8)
                                         'list))
                     (nerimux::%handle-multi-client-message
                      nerimux::+msg-key+ (vector byte) s conn)))
                 (paste-text ()
                   (concatenate 'string
                                (string #\Escape)
                                "[200~new"
                                (string #\Newline)
                                "text"
                                (string #\Escape)
                                "[201~")))
          (setf (nerimux::client-conn-view conn) :repolist
                (nerimux::client-conn-modal conn) :filter
                (nerimux::client-conn-tree-filter conn) "old")
          (send-text (paste-text))
          (expect (string= "oldnewtext"
                           (nerimux::client-conn-tree-filter conn)))
          (setf (nerimux::client-conn-modal conn) :picker
                (nerimux::client-conn-picker-query conn) "old")
          (send-text (paste-text))
          (expect (string= "oldnewtext"
                           (nerimux::client-conn-picker-query conn)))))))

  (it "nfr-1-single-frame-paste-writes-the-body-in-one-batch"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s)))
             (screen (nerimux/pane:pane-screen pane))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 41
              (nerimux::client-conn-focus conn) pane
              (nerimux::client-conn-view conn) :pane
              (nerimux/terminal/types:screen-bracketed-paste screen) nil)
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-write
               (lambda (fd bytes)
                 (declare (ignore fd))
                 (push (copy-seq bytes) writes))))
          (expect
           (null
            (nerimux::%handle-multi-client-message
             nerimux::+msg-key+
             #(27 91 50 48 48 126 97 98 99 27 91 50 48 49 126)
             s
             conn))))
        (expect (= 1 (length writes)))
        (expect (equalp #(97 98 99) (first writes)))
        (expect (null (nerimux::client-conn-paste-active-p conn)))
        (expect (null (gethash conn nerimux::*client-meta-pending*))))))

  (it "nfr-1-paste-delimiters-can-span-frames"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s)))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 41
              (nerimux::client-conn-focus conn) pane
              (nerimux::client-conn-view conn) :pane)
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-write
               (lambda (fd bytes)
                 (declare (ignore fd))
                 (push (copy-seq bytes) writes))))
          (nerimux::%handle-multi-client-message
           nerimux::+msg-key+ #(27 91 50) s conn)
          (expect (eq :csi-2
                      (gethash conn nerimux::*client-meta-pending*)))
          (nerimux::%handle-multi-client-message
           nerimux::+msg-key+ #(48 48 126 97 98) s conn)
          (expect (nerimux::client-conn-paste-active-p conn))
          (nerimux::%handle-multi-client-message
           nerimux::+msg-key+ #(99 27 91) s conn)
          (expect (eq :paste-csi-third
                      (gethash conn nerimux::*client-meta-pending*)))
          (nerimux::%handle-multi-client-message
           nerimux::+msg-key+ #(50 48 49 126) s conn))
        (expect (equalp '(#(97 98) #(99)) (nreverse writes)))
        (expect (null (nerimux::client-conn-paste-active-p conn)))
        (expect (null (gethash conn nerimux::*client-meta-pending*))))))

  (it "nfr-1-paste-mismatch-replays-and-end-tail-returns-to-bytewise-input"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s)))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 41
              (nerimux::client-conn-focus conn) pane
              (nerimux::client-conn-view conn) :pane)
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-write
               (lambda (fd bytes)
                 (declare (ignore fd))
                 (check-type bytes (simple-array (unsigned-byte 8) (*)))
                 (push (copy-seq bytes) writes))))
          (nerimux::%handle-multi-client-message
           nerimux::+msg-key+
           (coerce '(27 91 50 48 48 126 97 98 27 91 50 88 99 100
                     27 27 91 50 48 49 126 122 27 91 65)
                   '(simple-array (unsigned-byte 8) (*)))
           s
           conn))
        (expect
         (equal '(97 98 27 91 50 88 99 100 27 122 27 91 65)
                 (mapcan (lambda (bytes) (coerce bytes 'list))
                         (nreverse writes))))
        (expect (null (nerimux::client-conn-paste-active-p conn)))
        (expect (null (gethash conn nerimux::*client-meta-pending*))))))

  (it "nfr-1-modal-paste-batch-keeps-byte-order"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (nerimux::%client-enter-command-mode conn)
        (setf (nerimux::client-conn-command-buffer conn) "before")
        (nerimux::%handle-multi-client-message
         nerimux::+msg-key+
         #(27 91 50 48 48 126 111 110 101 10 116 119 111
           27 91 50 48 49 126)
         s
         conn)
        (expect (string= "beforeonetwo"
                         (nerimux::client-conn-command-buffer conn)))
        (expect (eq :command (nerimux::client-conn-modal conn))))))

  (it "nfr-1-key-burst-stops-at-drop-disposition"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (prefix (nerimux::client-conn-workspace-prefix-code conn)))
        (expect
         (eq :drop
             (nerimux::%handle-multi-client-message
              nerimux::+msg-key+
              (vector prefix (char-code #\d) prefix)
              s
              conn)))
        (expect (null (nerimux::client-conn-ui-prefix-p conn))))))

  (it "fr-102-focus-reports-follow-focus-order-and-skip-disabled-screens"
    (with-fake-session (s :nwindows 1 :npanes 2)
      (let* ((conn (%make-test-conn))
             (window (nerimux/session:session-active-window s))
             (panes (nerimux/window:window-panes window))
             (old-pane (first panes))
             (new-pane (second panes))
             (writes nil)
             (focus-in (concatenate 'string (string #\Escape) "[I"))
             (focus-out (concatenate 'string (string #\Escape) "[O")))
        (nerimux/window:window-relayout window 5 20)
        (setf (nerimux/pane:pane-fd old-pane) 11
              (nerimux/pane:pane-fd new-pane) 12
              (nerimux/terminal/types:screen-focus-events
               (nerimux/pane:pane-screen old-pane)) t
              (nerimux/terminal/types:screen-focus-events
               (nerimux/pane:pane-screen new-pane)) t
              (nerimux::client-conn-focus conn) old-pane
              (nerimux::client-conn-view conn) :repolist)
        (labels ((send-byte (byte)
                   (nerimux::%handle-multi-client-message
                    nerimux::+msg-key+ (vector byte) s conn)))
          (with-stubbed-fdefinition
              ((nerimux/pty:pty-write
                (lambda (fd bytes) (push (list fd bytes) writes))))
            (send-byte (nerimux::client-conn-workspace-prefix-code conn))
            (send-byte (char-code #\l))
            (expect (eq new-pane (nerimux::client-conn-focus conn)))
            (expect (equal (list (list 11 focus-out) (list 12 focus-in))
                           (nreverse writes)))
            (setf writes nil
                  (nerimux/terminal/types:screen-focus-events
                   (nerimux/pane:pane-screen new-pane)) nil)
            (send-byte (nerimux::client-conn-workspace-prefix-code conn))
            (send-byte (char-code #\h))
            (expect (eq old-pane (nerimux::client-conn-focus conn)))
            (expect (equal (list (list 11 focus-in)) (nreverse writes)))
            (setf writes nil)
            (send-byte 27)
            (send-byte 91)
            (send-byte (char-code #\O))
            (send-byte 27)
            (send-byte 91)
            (send-byte (char-code #\I))
            (expect (equal (list (list 11 focus-out) (list 11 focus-in))
                           (nreverse writes)))))))))

(describe "fr-107-server-input-suite"

  (it "fr-107-translates-arrow-keys-for-a-pane-with-decckm"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s)))
             (screen (nerimux/pane:pane-screen pane))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 41
              (nerimux::client-conn-focus conn) pane
              (nerimux::client-conn-view conn) :pane
              (nerimux/terminal/types:screen-app-cursor-keys screen) t)
        (labels ((send-arrow (final-byte)
                   (dolist (byte (list 27 91 final-byte))
                     (nerimux::%handle-multi-client-message
                      nerimux::+msg-key+ (vector byte) s conn)))
                 (recorded-bytes (payload)
                   (if (stringp payload)
                       (cl-codec-kit:string-to-octets payload :encoding :utf-8)
                       (copy-seq payload))))
          (with-stubbed-fdefinition
              ((nerimux/pty:pty-write
                (lambda (fd bytes)
                  (declare (ignore fd))
                  (push (recorded-bytes bytes) writes))))
            (dolist (final-byte '(65 66 67 68))
              (send-arrow final-byte))
            (expect
             (equalp
              (coerce
               (mapcan (lambda (final-byte) (list 27 79 final-byte))
                       '(65 66 67 68))
               '(simple-array (unsigned-byte 8) (*)))
              (coerce (mapcan (lambda (bytes) (coerce bytes 'list))
                              (nreverse writes))
                      '(simple-array (unsigned-byte 8) (*)))))
            (setf writes nil
                  (nerimux/terminal/types:screen-app-cursor-keys screen) nil)
            (dolist (final-byte '(65 66 67 68))
              (send-arrow final-byte))
            (expect
             (equalp
              (coerce
               (mapcan (lambda (final-byte) (list 27 91 final-byte))
                       '(65 66 67 68))
               '(simple-array (unsigned-byte 8) (*)))
              (coerce (mapcan (lambda (bytes) (coerce bytes 'list))
                              (nreverse writes))
                      '(simple-array (unsigned-byte 8) (*))))))))))

  (it "fr-107-does-not-send-modal-arrow-input-to-a-pane"
    (with-fake-session (s)
      (let* ((conn (%make-test-conn))
             (pane (nerimux/window:window-active-pane
                    (nerimux/session:session-active-window s)))
             (screen (nerimux/pane:pane-screen pane))
             (writes nil))
        (setf (nerimux/pane:pane-fd pane) 41
              (nerimux::client-conn-focus conn) pane
              (nerimux::client-conn-view conn) :repolist
              (nerimux::client-conn-modal conn) :command
              (nerimux/terminal/types:screen-app-cursor-keys screen) t)
        (with-stubbed-fdefinition
            ((nerimux/pty:pty-write
              (lambda (fd bytes)
                (declare (ignore fd))
                (push bytes writes))))
          (dolist (byte '(27 91 65))
            (nerimux::%handle-multi-client-message
             nerimux::+msg-key+ (vector byte) s conn)))
        (expect (null writes)))))

  (it "rl-13-an-escape-that-cancels-a-modal-does-not-eat-the-next-key"
    (with-fake-session (s)
      (dolist (opening (list #(47 122) #(58) #()))
        (let ((conn (%make-test-conn)))
          (setf (nerimux::client-conn-view conn) :repolist)
          (when (plusp (length opening))
            (nerimux::%handle-multi-client-message
             nerimux::+msg-key+ opening s conn))
          (nerimux::%handle-multi-client-message
           nerimux::+msg-key+ #(27) s conn)
          (nerimux::%handle-multi-client-message
           nerimux::+msg-key+ #(36) s conn)
          (expect (eq :process-log (nerimux::client-conn-modal conn)))))))

  (it "an-escape-introducer-still-resolves-arrow-and-ss3-sequences"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :repolist)
        (dolist (byte (list 27 91 66))
          (nerimux::%handle-multi-client-message
           nerimux::+msg-key+ (vector byte) s conn))
        (expect (null (nerimux::client-conn-modal conn)))
        (dolist (byte (list 27 79 66))
          (nerimux::%handle-multi-client-message
           nerimux::+msg-key+ (vector byte) s conn))
        (expect (null (nerimux::client-conn-modal conn))))))

  (it "v-in-the-status-view-steps-back-to-the-repolist"
    (with-fake-session (s)
      (let ((conn (%make-test-conn)))
        (setf (nerimux::client-conn-view conn) :status)
        (nerimux::%handle-multi-key-message s conn #(118))
        (expect (eq :repolist (nerimux::client-conn-view conn))))))
  )
